#!/usr/bin/env bash
# Shared helpers for the tmux version of tai. Source this file; it only defines functions and settings.
# Needs bash 4+, tmux 3.0+ and jq.

TAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAI_CONF="${TAI_CONF:-$HOME/.config/tai}"
PROJECTS="$TAI_CONF/projects.json"
STATE_DIR="$TAI_CONF/state"
USAGE_FILE="$TAI_CONF/usage.json"
SESSION="${TAI_SESSION:-tai}"

MIN_COLS=55          # a pane must stay at least this wide ...
MIN_ROWS=24          # ... and this tall after a split
MAX_PANES=9
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
edit_projects() {
    local tmp filter="$1"
    shift
    tmp="$(mktemp)" && jq "$@" "$JQ_DEFS $filter" "$PROJECTS" > "$tmp" && mv "$tmp" "$PROJECTS"
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
    spec="$(next_split)" || return 1
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
