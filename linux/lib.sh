#!/usr/bin/env bash
# Shared helpers for the tmux version of tai. Source this file; it only defines functions and settings.
# Needs bash 4+, tmux 3.0+ and jq.

TAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAI_CONF="${TAI_CONF:-$HOME/.config/tai}"
PROJECTS="$TAI_CONF/projects.json"
STATE_DIR="$TAI_CONF/state"
USAGE_FILE="$TAI_CONF/usage.json"
SESSION="${TAI_SESSION:-tai}"

# Tunable for big screens (e.g. 4K): TAI_MAX_PANES (default 9, up to 16), TAI_MIN_COLS (55), TAI_MIN_ROWS (24).
env_int() {   # name default min max -> the variable's value when it is an integer in range, else the default
    local v="${!1:-}"
    if [[ "$v" =~ ^[0-9]+$ ]] && ((v >= $3 && v <= $4)); then echo "$v"; else echo "$2"; fi
}
MIN_COLS="$(env_int TAI_MIN_COLS 55 20 400)"    # a pane must stay at least this wide ...
MIN_ROWS="$(env_int TAI_MIN_ROWS 24 8 200)"     # ... and this tall after a split
MAX_PANES="$(env_int TAI_MAX_PANES 9 1 16)"
DASH_COLS=38         # width of the dashboard pane
REGISTRY="$TAI_DIR/../agents.json"   # per-CLI facts shared with windows/ (exe, args, resume/fresh args, env)
AGENTS=(claude codex agy opencode cursor copilot qwen)
if [[ -f "$REGISTRY" ]] && command -v jq >/dev/null 2>&1; then
    mapfile -t AGENTS < <(jq -r 'keys_unsorted[]' "$REGISTRY")
fi
INSTALLED=()

agent_exe() {   # agent name -> executable (Cursor's CLI is called "agent")
    local e=""
    [[ -f "$REGISTRY" ]] && e="$(jq -r --arg a "$1" '.[$a].exe // empty' "$REGISTRY" 2>/dev/null)"
    echo "${e:-$1}"
}

# Fills ARGV with the arguments for launching an agent: the registry's always-on args plus the 'resume' or 'fresh' extras.
agent_args() {   # agent mode(resume|fresh) project-name
    ARGV=()
    [[ -f "$REGISTRY" ]] || return 0
    mapfile -t ARGV < <(jq -r --arg a "$1" --arg m "$2" --arg n "$3" \
        '.[$a] // {} | ((.args // []) + (.[$m] // []))[] | gsub("\\{name\\}"; $n)' "$REGISTRY")
}

# Tells an agent about `tai delegate` through its own launch flag (registry field "delegateHint": flag, file, value, suffix,
# resumeArgs). Fills HINT with extra launch arguments (empty when the CLI has no field or there is no target to hand work to).
# The text is written to generated/delegate-hint-<agent>.md on every launch, because the target list follows what is installed.
delegate_hint_args() {   # agent mode(resume|fresh)
    HINT=()
    [[ -f "$REGISTRY" ]] || return 0
    local flag file value suffix a text targets=() dir f
    flag="$(jq -r --arg a "$1" '.[$a].delegateHint.flag // empty' "$REGISTRY")"
    [[ -n "$flag" ]] || return 0
    file="$(jq -r --arg a "$1" '.[$a].delegateHint.file // false' "$REGISTRY")"
    value="$(jq -r --arg a "$1" '.[$a].delegateHint.value // empty' "$REGISTRY")"
    suffix="$(jq -r --arg a "$1" '.[$a].delegateHint.suffix // empty' "$REGISTRY")"
    for a in "${AGENTS[@]}"; do
        [[ "$a" != "$1" ]] && [[ "$(jq -r --arg a "$a" '.[$a].headless | type' "$REGISTRY")" == object ]] \
            && command -v "$(agent_exe "$a")" >/dev/null 2>&1 && targets+=("$a")
    done
    ((${#targets[@]})) || return 0
    local labels=() bf
    for a in "${targets[@]}"; do
        bf="$(jq -r --arg a "$a" '.[$a].bestFor // empty' "$REGISTRY")"
        if [[ -n "$bf" ]]; then labels+=("$a (best for: $bf)"); else labels+=("$a"); fi
    done
    text='tai delegate: when the user asks you to hand work to another agent CLI (for example "delegate to codex", "ask agy to review X", "summarise this chat and send file F to codex"), run in the project folder: '"\"$TAI_DIR/delegate.sh\""' <name> "<task>" [--summary "<condensed chat context, max 3000 chars>"] [--files path1,path2] [--edit] [--worktree]. It blocks until the target finishes and prints its reply, which you relay to the user. Targets: '"$(printf '%s; ' "${labels[@]}" | sed 's/; $//')"'. Read-only unless --edit is given (the target may then change files). If it reports blocked, tell the user and offer --allow <rule> for that command. Delegate only when asked; a delegate cannot delegate further. Auto-delegation: if the user asks you to delegate automatically or in parallel, split the job into steps, send each step to the target whose "best for" fits it, and start steps that do not depend on each other at the same time (separate background shell jobs or concurrent calls), then combine the replies. Only one delegation per target can run in a project at once, and two steps that edit files must not touch the same files; give edit steps to different targets or wait for the first to finish. Better: add --worktree to a step; it then runs in its own new git worktree and branch (made from the last commit, so uncommitted changes are not in it), which lets several delegations, even to the same target, run in parallel. The reply names the worktree and branch; review and merge them yourself. Quota: if a delegation ends with status quota (exit code 3), that target is out of quota and is skipped automatically until its reset; send that step to the next best target instead, tell the user which one was out, and never run it on your own quota unless the user agrees. For any other failure, report it rather than guessing.'
    [[ -n "$suffix" ]] && text+=" $suffix"
    dir="$TAI_DIR/generated"
    mkdir -p "$dir" 2>/dev/null
    f="$dir/delegate-hint-$1.md"   # one file per agent: panes launching together must not read each other's target list
    if ! printf '%s\n' "$text" | write_atomic "$f"; then [[ "$file" == true ]] && return 0; fi
    if [[ "$file" == true ]]; then HINT=("$flag" "$f"); else HINT=("$flag" "${value//\{text\}/$text}"); fi
    if [[ "$2" == resume ]]; then
        while IFS= read -r a; do [[ -n "$a" ]] && HINT+=("$a"); done < <(jq -r --arg a "$1" '.[$a].delegateHint.resumeArgs // [] | .[]' "$REGISTRY")
    fi
}

# Exports the agent's registry env vars (e.g. OPENCODE_DISABLE_TERMINAL_TITLE) and unsets the other agents'.
agent_env() {
    [[ -f "$REGISTRY" ]] || return 0
    local k v
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] && unset "$k"
    done < <(jq -r '.[] | (.env // {}) | to_entries[] | [.key, .value] | @tsv' "$REGISTRY")
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] && export "$k=$v"
    done < <(jq -r --arg a "$1" '.[$a].env // {} | to_entries[] | [.key, .value] | @tsv' "$REGISTRY")
}

ensure_projects() {
    mkdir -p "$TAI_CONF" "$STATE_DIR"
    [[ -f "$PROJECTS" ]] || echo '[]' > "$PROJECTS"
}

# Known CLIs that are on PATH (falls back to all known ones if none are).
update_installed() {
    INSTALLED=()
    local a
    for a in "${AGENTS[@]}"; do command -v "$(agent_exe "$a")" >/dev/null 2>&1 && INSTALLED+=("$a"); done
    ((${#INSTALLED[@]})) || INSTALLED=("${AGENTS[@]}")
}

# A project's path is a plain string, or {"windows": "...", "linux": "..."} so one projects.json serves both OSes.
# lp = the Linux path ("" when none). A plain string is only visible here when it starts with "/";
# entries for the other OS stay in the file untouched (point both OSes at one file with TAI_CONF).
JQ_DEFS='def lp: (.path | if type == "object" then (.linux // "") elif type == "string" then . else "" end);
def vis: ((lp | startswith("/")));'

# Prints one "name<TAB>path<TAB>agent" line per project; agent is "-" when none is saved.
list_projects() {
    jq -r "$JQ_DEFS"' .[] | select(vis) | [.name, lp, (.agent // "-")] | @tsv' "$PROJECTS"
}

# Replaces the projects file with the output of a jq filter (args after the filter are passed to jq).
edit_projects() {   # serialized with a lock so two quick edits cannot lose one another
    mkdir -p "$STATE_DIR"
    with_lock _edit_projects "$@"
}

_edit_projects() {
    local tmp filter="$1"
    shift
    tmp="$(mktemp)" || return 1
    if jq "$@" "$JQ_DEFS $filter" "$PROJECTS" > "$tmp"; then mv "$tmp" "$PROJECTS"; else rm -f "$tmp"; return 1; fi
}

add_project() {   # path [name]; sets MSG and returns 1 when the name or folder is already listed
    local p="$1" n="${2:-$(basename "$1")}" dup
    dup="$(jq -r --arg n "$n" '.[] | select(.name == $n) | .name' "$PROJECTS" | head -n1)"
    if [[ -n "$dup" ]]; then MSG="A project named '$n' already exists"; return 1; fi
    dup="$(jq -r --arg p "$p" "$JQ_DEFS"' .[] | select(lp == $p) | .name' "$PROJECTS" | head -n1)"
    if [[ -n "$dup" ]]; then MSG="That folder is already listed as '$dup'"; return 1; fi
    edit_projects '. + [{name: $n, path: $p}]' --arg p "$p" --arg n "$n"
}

swap_projects() {   # path path: swaps two entries in place, so entries for the other OS keep their positions
    edit_projects '(map(lp) | index($a)) as $i | (map(lp) | index($b)) as $j
                   | if $i == null or $j == null then . else .[$i] as $x | .[$j] as $y | .[$i] = $y | .[$j] = $x end' \
        --arg a "$1" --arg b "$2"
}

# Desktop notification: notify-send (Linux), osascript (macOS), else a tmux message.
send_toast() {   # title text
    if command -v notify-send >/dev/null 2>&1; then notify-send -a tai "$1" "$2" 2>/dev/null
    elif command -v osascript >/dev/null 2>&1; then osascript -e 'on run a' -e 'display notification (item 2 of a) with title (item 1 of a)' -e 'end run' "$1" "$2" 2>/dev/null
    else tmux display-message "$1: $2" 2>/dev/null; fi
}

remove_project() { edit_projects 'map(select(lp != $p))' --arg p "$1"; }
set_agent()      { edit_projects 'map(if lp == $p then .agent = $a else . end)' --arg p "$1" --arg a "$2"; }

# --- accounts ---------------------------------------------------------------------------------
# accounts.json (repo root, git-ignored; see accounts.example.json) lists named accounts per CLI as config folders:
#   { "claude": { "personal": "~/.claude", "work": "~/.claude-work" } }
# The first is the default. agents.json's "configEnv" names the variable that moves a CLI's login (CLAUDE_CONFIG_DIR,
# CODEX_HOME), so a pane on another account just gets another folder.
ACCOUNTS="$TAI_DIR/../accounts.json"

agent_accounts() {   # agent -> account names, one per line (nothing when the agent has none or no configEnv)
    [[ -f "$ACCOUNTS" && -f "$REGISTRY" ]] || return 0
    [[ -n "$(jq -r --arg a "$1" '.[$a].configEnv // empty' "$REGISTRY" 2>/dev/null)" ]] || return 0
    jq -r --arg a "$1" '.[$a] // {} | keys_unsorted[]' "$ACCOUNTS" 2>/dev/null
}

project_account() {   # path agent -> the project's saved account if it still exists, else the first account
    local names saved
    names="$(agent_accounts "$2")"
    [[ -n "$names" ]] || return 0
    saved="$(jq -r --arg p "$1" --arg a "$2" "$JQ_DEFS"' .[] | select(lp == $p) | .accounts[$a] // empty' "$PROJECTS" 2>/dev/null | head -n1)"
    if [[ -n "$saved" ]] && grep -qxF -- "$saved" <<< "$names"; then echo "$saved"; else head -n1 <<< "$names"; fi
}

account_dir() {   # agent account -> folder with ~ expanded
    local d
    d="$(jq -r --arg a "$1" --arg n "$2" '.[$a][$n] // empty' "$ACCOUNTS" 2>/dev/null)"
    [[ -n "$d" ]] && echo "${d/#\~/$HOME}"
}

# Points the agent's config variable at the account's folder (created on first use; Codex also gets the hooks and
# config copied in once). Other agents' variables are unset first. The CLI's own default folder leaves it unset.
set_agent_account_env() {   # agent account
    [[ -f "$REGISTRY" ]] || return 0
    local v var dir def
    while IFS= read -r v; do [[ -n "$v" ]] && unset "$v"; done < <(jq -r '.[] | .configEnv // empty' "$REGISTRY")
    [[ -n "$2" ]] || return 0
    var="$(jq -r --arg a "$1" '.[$a].configEnv // empty' "$REGISTRY")"
    dir="$(account_dir "$1" "$2")"
    [[ -n "$var" && -n "$dir" ]] || return 0
    def="$(jq -r --arg a "$1" '.[$a].defaultDir // empty' "$REGISTRY")"
    def="${def/#\~/$HOME}"
    [[ -n "$def" && "${dir%/}" == "${def%/}" ]] && return 0
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        if [[ "$1" == codex ]]; then
            local f
            for f in hooks.json config.toml; do [[ -f "$HOME/.codex/$f" ]] && cp "$HOME/.codex/$f" "$dir/"; done
        fi
    fi
    export "$var=$dir"
}

set_project_account() {   # path agent account
    edit_projects 'map(if lp == $p then .accounts = ((.accounts // {}) + {($a): $acc}) else . end)' \
        --arg p "$1" --arg a "$2" --arg acc "$3"
}

is_default_account_dir() {   # agent dir -> true when it is the CLI's own default folder
    local def
    def="$(jq -r --arg a "$1" '.[$a].defaultDir // empty' "$REGISTRY" 2>/dev/null)"
    def="${def/#\~/$HOME}"
    [[ -n "$def" && "${2%/}" == "${def%/}" ]]
}

usage_name_for_dir() {   # Claude config dir -> usage file name, one per account (usage.json for the default)
    local leaf
    leaf="$(basename "${1%/}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g')"
    echo "usage-$leaf.json"
}

# Who an account is logged in as: "email (plan)", "not logged in" or "checking..." while a lookup runs. Codex is read
# from auth.json (only the email and plan claims of the id token); Claude through `claude auth status` in the
# background, cached for 10 minutes in the state folder.
account_identity() {   # agent account
    local dir tok p cache age=999999 mt out
    dir="$(account_dir "$1" "$2")"
    [[ -n "$dir" ]] || return 0
    case "$1" in
        codex)
            [[ -f "$dir/auth.json" ]] || { echo "not logged in"; return; }
            tok="$(jq -r '.tokens.id_token // empty' "$dir/auth.json" 2>/dev/null | cut -d. -f2)"
            [[ -n "$tok" ]] || { echo "not logged in"; return; }
            p="${tok//-/+}"; p="${p//_//}"
            while ((${#p} % 4)); do p+="="; done
            out="$(printf '%s' "$p" | base64 -d 2>/dev/null | jq -r 'if .email then "\(.email) (\(.["https://api.openai.com/auth"].chatgpt_plan_type // "?"))" else "not logged in" end' 2>/dev/null)"
            echo "${out:-not logged in}" ;;
        claude)
            mkdir -p "$STATE_DIR"
            cache="$STATE_DIR/ident_$(printf '%s' "$dir" | cksum | cut -d' ' -f1).txt"
            if [[ -f "$cache" ]]; then
                mt="$(file_mtime "$cache")"
                [[ -n "$mt" ]] && age=$(($(date +%s) - mt))
            fi
            if ((age >= 600)) && [[ ! -e "$cache.run" || -n "$(find "$cache.run" -mmin +2 2>/dev/null)" ]]; then
                : > "$cache.run"
                (
                    if is_default_account_dir claude "$dir"; then out="$(claude auth status 2>/dev/null)"
                    else out="$(CLAUDE_CONFIG_DIR="$dir" claude auth status 2>/dev/null)"; fi
                    jq -r 'if .loggedIn and .email then .email + (if .subscriptionType then " (\(.subscriptionType))" else "" end) else "not logged in" end' <<< "$out" > "$cache.tmp" 2>/dev/null \
                        || echo "login unknown (claude auth status failed)" > "$cache.tmp"
                    mv -f "$cache.tmp" "$cache"; rm -f "$cache.run"
                ) >/dev/null 2>&1 &
            fi
            if [[ -f "$cache" ]]; then cat "$cache"; else echo "checking..."; fi ;;
    esac
}

# --- opt-in install of tai's status hooks into each CLI's own config (dashboard key H) ------------
# init_generated_configs fills this checkout's folder into every *.example.json hook template and writes the result to
# generated/ (git-ignored; existing files are left alone). install_agent_hooks then asks per CLI, backs the user's file up
# to *.tai-backup-<stamp> only when it changes, and merges our entries in (or owns the file, for Copilot).
# Schemas for qwen/cursor/copilot come from docs and are unconfirmed. Claude and agy are not covered.
GENERATED="$TAI_DIR/generated"
HOOKS_ANSWERS="$STATE_DIR/hooks-install.json"
HOOK_SCRIPT="$TAI_DIR/hook.sh"
HOOK_AGENTS=(codex qwen cursor copilot)

init_generated_configs() {
    local f out repo
    repo="$(cd "$TAI_DIR/.." && pwd)"
    mkdir -p "$GENERATED"
    for f in "$TAI_DIR"/*.example.json; do
        [[ -e "$f" ]] || continue
        case "${f##*/}" in projects.example.json|claude-settings.example.json) continue ;; esac
        out="$GENERATED/$(basename "$f" .example.json).json"
        [[ -e "$out" ]] && continue
        sed "s|/path/to/terminal_ai|$repo|g" "$f" > "$out"
    done
}

hook_target() {   # agent -> "file|source in generated/|merge or own|note"
    case "$1" in
        codex)   echo "$HOME/.codex/hooks.json|codex-hooks.json|merge|Codex also needs [features] hooks = true in ~/.codex/config.toml and trusting the hooks on first run." ;;
        qwen)    echo "$HOME/.qwen/settings.json|qwen-settings.json|merge|" ;;
        cursor)  echo "$HOME/.cursor/hooks.json|cursor-hooks.json|merge|" ;;
        copilot) echo "$HOME/.copilot/hooks/tai.json|copilot-hooks.json|own|" ;;
        *) return 1 ;;
    esac
}

set_hook_answer() {   # agent answer
    local tmp="$HOOKS_ANSWERS.$$.tmp"
    mkdir -p "$STATE_DIR"
    [[ -f "$HOOKS_ANSWERS" ]] || echo '{}' > "$HOOKS_ANSWERS"
    jq --arg n "$1" --arg v "$2" '.[$n] = $v' "$HOOKS_ANSWERS" > "$tmp" && mv -f "$tmp" "$HOOKS_ANSWERS"
}

hooks_pending() {   # installed CLIs with a hook target that have not been answered yet, one per line
    local a
    for a in "${HOOK_AGENTS[@]}"; do
        command -v "$(agent_exe "$a")" >/dev/null 2>&1 || continue
        [[ -f "$HOOKS_ANSWERS" ]] && jq -e --arg a "$a" 'has($a)' "$HOOKS_ANSWERS" >/dev/null 2>&1 && continue
        echo "$a"
    done
}

# Asks, then installs, for each CLI named. Sets MSG to a one-line summary.
install_agent_hooks() {
    local n spec file src mode note gen what ans stamp tmp pause=0
    local ok=() skipped=() failed=()
    init_generated_configs
    for n in "$@"; do
        spec="$(hook_target "$n")" || continue
        IFS='|' read -r file src mode note <<< "$spec"
        gen="$GENERATED/$src"
        if [[ -e "$file" ]]; then
            if [[ "$mode" == own ]]; then what="replace $file (backup kept)"; else what="merge into $file (backup kept)"; fi
        else what="create $file"; fi
        printf '\n\e[36m%s: %s\e[0m\n' "$n" "$what"
        printf 'Install tai status hooks (y/N) '; read -r ans
        if [[ "$ans" != [yY]* ]]; then set_hook_answer "$n" declined; skipped+=("$n"); continue; fi
        if ! jq -e . "$gen" >/dev/null 2>&1; then
            printf '\e[31m%s: not installed - %s is missing or invalid\e[0m\n' "$n" "$gen"; failed+=("$n"); pause=1; continue
        fi
        mkdir -p "$(dirname "$file")"
        stamp="$(date +%Y%m%d-%H%M%S)"
        tmp="$file.$$.tmp"
        if [[ "$mode" == own || ! -e "$file" ]]; then
            if [[ -e "$file" ]] && cmp -s "$gen" "$file"; then :   # already identical
            else
                [[ -e "$file" ]] && cp "$file" "$file.tai-backup-$stamp"
                cp "$gen" "$tmp" && mv -f "$tmp" "$file"
            fi
        else
            if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
                printf '\e[31m%s: not installed - %s is not a JSON object\e[0m\n' "$n" "$file"; failed+=("$n"); pause=1; continue
            fi
            # An event that already runs our hook script is left alone, so running this twice changes nothing.
            if ! jq -s --arg m "$HOOK_SCRIPT" '.[0] as $c | .[1] as $g
                    | reduce ($g.hooks | keys_unsorted[]) as $ev ($c;
                        if ((.hooks[$ev] // []) | tojson | contains($m)) then .
                        else .hooks[$ev] = ((.hooks[$ev] // []) + $g.hooks[$ev]) end)
                    | reduce ($g | keys_unsorted[]) as $k (.; if $k != "hooks" and (has($k) | not) then .[$k] = $g[$k] else . end)' \
                    "$file" "$gen" > "$tmp" 2>/dev/null; then
                rm -f "$tmp"; printf '\e[31m%s: not installed - could not merge into %s\e[0m\n' "$n" "$file"; failed+=("$n"); pause=1; continue
            fi
            if [[ "$(jq -cS . "$file")" == "$(jq -cS . "$tmp")" ]]; then rm -f "$tmp"
            else cp "$file" "$file.tai-backup-$stamp"; mv -f "$tmp" "$file"; fi
        fi
        set_hook_answer "$n" installed; ok+=("$n")
        if [[ -n "$note" ]]; then printf '\e[33m%s\e[0m\n' "$note"; pause=1; fi
    done
    if ((pause)); then printf 'Press Enter to continue '; read -r ans; fi
    MSG=""
    ((${#ok[@]})) && MSG+="installed: ${ok[*]}; "
    ((${#skipped[@]})) && MSG+="skipped: ${skipped[*]}; "
    ((${#failed[@]})) && MSG+="failed: ${failed[*]}; "
    if [[ -n "$MSG" ]]; then MSG="Hooks ${MSG%; }"; else MSG="Hooks: nothing to do"; fi
}

# --- state files (written by hook.sh / statusline.sh / agy-statusline.sh, read by the dashboard) -----
# Key per project folder: readable prefix plus a hash, so /a-b and /a_b get different files.

hash8() {
    if command -v md5sum >/dev/null 2>&1; then md5sum | cut -c1-8; else md5 -q | cut -c1-8; fi
}

state_key() {   # folder -> file-name key
    local n="${1%/}"
    n="${n,,}"
    printf '%s_%s' "${n//[^a-z0-9]/_}" "$(printf '%s' "$n" | hash8)"
}

# Runs the rest of its arguments while holding a lock (flock when available, otherwise unlocked).
with_lock() {
    if command -v flock >/dev/null 2>&1; then
        ( flock -w 3 9; "$@" ) 9>"$STATE_DIR/.lock"
    else
        "$@"
    fi
}

# Writes stdin to a file atomically, so the dashboard never reads a half-written file.
write_atomic() {
    local tmp="$1.tmp.$$"
    cat > "$tmp" && mv -f "$tmp" "$1"
}

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# --- tmux helpers -----------------------------------------------------------------------------
# Every project pane carries the pane options @tai_path, @tai_name, @tai_agent and @tai_since (epoch seconds);
# the dashboard pane has @tai_role=dashboard.

# "pane_id<TAB>width<TAB>height<TAB>path" for each project pane.
project_panes() {
    tmux list-panes -s -t "$SESSION" -F '#{pane_id}'$'\t''#{pane_width}'$'\t''#{pane_height}'$'\t''#{@tai_path}' |
        awk -F'\t' '$4 != ""'
}

pane_for_path() {   # path -> pane id or nothing
    project_panes | awk -F'\t' -v p="$1" '$4 == p { print $1; exit }'
}

dashboard_pane() {
    tmux list-panes -s -t "$SESSION" -F '#{pane_id}'$'\t''#{pane_width}'$'\t''#{pane_height}'$'\t''#{@tai_role}' |
        awk -F'\t' '$4 == "dashboard" { print $1 "\t" $2 "\t" $3; exit }'
}

# Picks where the next pane goes and how. Fixed steps keep the familiar shapes: the first pane sits beside the
# dashboard, the second pane stacks the right-hand one, later panes halve the biggest pane along its longer side
# (a cell is about twice as tall as wide) while both halves stay >= MIN_COLS x MIN_ROWS.
# Prints "base_pane_id<TAB>-h|-v<TAB>size_of_new_pane"; returns 1 (and sets MSG) when nothing fits.
next_split() {
    local panes id w h p count best="" bw=0 bh=0
    panes="$(project_panes)"
    count=$(grep -c . <<< "$panes" || true)
    if ((count >= MAX_PANES)); then MSG="At most $MAX_PANES panes"; return 1; fi
    if ((count == 0)); then
        local d dw dh
        d="$(dashboard_pane)"; IFS=$'\t' read -r id dw dh <<< "$d"
        if ((dw - DASH_COLS - 1 < MIN_COLS || dh < MIN_ROWS)); then MSG="Window too small for a pane"; return 1; fi
        printf '%s\t-h\t%s\n' "$id" "$((dw - DASH_COLS - 1))"
        return 0
    fi
    if ((count == 2)); then
        # Two panes side by side: stack the right one. Two stacked panes: split the lower one side by side.
        local l t r_id r_w r_h r_left=-1 b_id b_w b_h b_top=-1 same_top=1 first_top=""
        while IFS=$'\t' read -r id w h l t; do
            [[ -z "$first_top" ]] && first_top="$t"
            [[ "$t" != "$first_top" ]] && same_top=0
            if ((l > r_left)); then r_left=$l; r_id=$id; r_w=$w; r_h=$h; fi
            if ((t > b_top)); then b_top=$t; b_id=$id; b_w=$w; b_h=$h; fi
        done < <(tmux list-panes -s -t "$SESSION" -F '#{pane_id}'$'\t''#{pane_width}'$'\t''#{pane_height}'$'\t''#{pane_left}'$'\t''#{pane_top}'$'\t''#{@tai_path}' |
                 awk -F'\t' '$6 != "" { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }')
        if ((same_top)); then
            if ((r_h < 2 * MIN_ROWS + 1)); then MSG="Window fits only $count panes"; return 1; fi
            printf '%s\t-v\t%s\n' "$r_id" "$(((r_h - 1) / 2))"
        else
            if (((b_w - 1) / 2 < MIN_COLS)); then MSG="Window fits only $count panes"; return 1; fi
            printf '%s\t-h\t%s\n' "$b_id" "$(((b_w - 1) / 2))"
        fi
        return 0
    fi
    while IFS=$'\t' read -r id w h p; do
        if ((w * h > bw * bh)); then best="$id"; bw=$w; bh=$h; fi
    done <<< "$panes"
    if ((bw >= 2 * bh)); then
        if (((bw - 1) / 2 < MIN_COLS || bh < MIN_ROWS)); then MSG="Window fits only $count panes"; return 1; fi
        printf '%s\t-h\t%s\n' "$best" "$(((bw - 1) / 2))"
    else
        if ((bw < MIN_COLS || (bh - 1) / 2 < MIN_ROWS)); then MSG="Window fits only $count panes"; return 1; fi
        printf '%s\t-v\t%s\n' "$best" "$(((bh - 1) / 2))"
    fi
}

# Opens a project in a new pane, or focuses the pane it already has. Sets MSG.
open_project() {   # name path agent [nofocus]
    local name="$1" path="$2" agent="$3" id spec base dir size
    id="$(pane_for_path "$path")"
    if [[ -n "$id" ]]; then
        [[ -n "${4:-}" ]] || tmux select-pane -t "$id"
        MSG="Focused $name"; return 0
    fi
    [[ -d "$path" ]] || { MSG="Folder not found: $path"; return 1; }
    # Not "$(next_split)": a subshell would lose the MSG it sets when nothing fits.
    local sf; sf="$(mktemp)"
    next_split >"$sf" || { rm -f "$sf"; return 1; }
    spec="$(<"$sf")"; rm -f "$sf"
    IFS=$'\t' read -r base dir size <<< "$spec"
    id="$(tmux split-window "$dir" -l "$size" -t "$base" -c "$path" -P -F '#{pane_id}' \
            "$TAI_DIR/slot.sh" "$name" "$path" "$agent")" || { MSG="tmux could not split"; return 1; }
    tmux set-option -p -t "$id" @tai_path "$path"
    tmux set-option -p -t "$id" @tai_name "$name"
    tmux set-option -p -t "$id" @tai_agent "${agent/#-/claude}"
    tmux set-option -p -t "$id" @tai_since "$(date +%s)"
    [[ -n "${4:-}" ]] || tmux select-pane -t "$id"
    MSG="Opened $name"
}

close_project() {   # name path
    local id
    id="$(pane_for_path "$2")"
    if [[ -z "$id" ]]; then MSG="$1 is not open"; return 1; fi
    tmux kill-pane -t "$id"
    MSG="Closed $1"
}

# Swaps a project's pane with its neighbour in a direction (left|right|up|down); never with the dashboard.
move_project() {   # path direction
    local id nb
    id="$(pane_for_path "$1")"
    if [[ -z "$id" ]]; then MSG="Open it first"; return 1; fi
    tmux select-pane -t "$id"
    nb="$(tmux display-message -p -t "{$2-of}" '#{pane_id} #{@tai_role}' 2>/dev/null)" || nb=""
    if [[ -z "$nb" || "${nb%% *}" == "$id" || "$nb" == *dashboard ]]; then MSG="Nothing to swap with on the $2"; return 1; fi
    tmux swap-pane -t "{$2-of}"
    MSG="Moved pane $2"
}
