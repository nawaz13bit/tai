#!/usr/bin/env bash
# tai delegate: one agent hands a task to another CLI, which runs headless (one-shot) in the same project folder.
# The task goes in <project>/.tai/task-<target>.md, the answer comes back in <project>/.tai/reply-<target>.md (and on stdout).
# Usage (from an agent's shell, or by hand):
#   delegate.sh <target> "<task>" [--project <dir>] [--summary "<what has been done>"] [--files a.txt,b.txt]
#                                 [--allow "<rule>"]... [--allow-wide] [--edit] [--worktree] [--ignore-quota] [--timeout 600]
#   delegate.sh --history [--project <dir>]       list past delegations of the project
# (target gemini is accepted as an alias of agy.) Read-only by default; --edit lets the target change files
# (use a worktree if the caller is editing too). --allow adds a command the target may run without asking, in the
# target's own rule syntax (claude: "Bash(git status)", agy: "command(git status)"). A rule that allows (almost)
# everything is refused unless --allow-wide is given.
# --worktree runs the target in a new git worktree (own branch, own .tai), so several delegations, even to the same
# target, can run in parallel. Exit code: 0 done, 1 failed or refused, 2 timed out, 3 target out of quota (remembered
# until its reset; send the step elsewhere, or --ignore-quota to try anyway).
. "$(dirname "$(readlink -f "$0")")/lib.sh"

MAX_TASK=4000 MAX_SUMMARY=3000 MAX_REPLY=20000 MAX_CHANGED=30 KEEP_RUNS=50 KEEP_DAYS=30

stop() { echo "tai delegate: $1" >&2; exit "${2:-1}"; }

limit_text() {   # text max
    if ((${#1} <= $2)); then printf '%s' "$1"; else printf '%s\n[cut at %d characters]' "${1:0:$2}" "$2"; fi
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

target="" task="" project="" summary="" files=() allow=() allow_wide=0 edit=0 timeout_sec=600 history=0 worktree=0 ignore_quota=0
pos=0
while (($#)); do
    case "$1" in
        --project)    project="${2:-}"; shift ;;
        --summary)    summary="${2:-}"; shift ;;
        --files)      files+=("${2:-}"); shift ;;
        --allow)      allow+=("${2:-}"); shift ;;
        --allow-wide) allow_wide=1 ;;
        --edit)       edit=1 ;;
        --worktree)   worktree=1 ;;
        --ignore-quota) ignore_quota=1 ;;
        --timeout)    timeout_sec="${2:-600}"; shift ;;
        --history)    history=1 ;;
        *)            if ((pos == 0)); then target="$1"; elif ((pos == 1)); then task="$1"; fi; pos=$((pos + 1)) ;;
    esac
    shift
done
[[ "$timeout_sec" =~ ^[0-9]+$ ]] || stop "--timeout needs a number of seconds"

dir="${project:-${TAI_PROJECT_DIR:-$PWD}}"
[[ -d "$dir" ]] || stop "folder not found: $dir"
dir="$(cd "$dir" && pwd)"

# ---- Quota memory: a target that ran out is skipped until its reset (machine-wide, so every project benefits) ----
quota_dir="$TAI_DIR/generated"
quota_hold() {   # target -> prints the reset epoch when the target is still held
    local f="$quota_dir/quota-$1.json" until
    [[ -f "$f" ]] || return 1
    until="$(jq -r '.until // empty' "$f" 2>/dev/null)"
    if [[ "$until" =~ ^[0-9]+$ ]] && ((until > $(date +%s))); then echo "$until"; return 0; fi
    rm -f "$f"; return 1
}
# Error text of the CLIs when the plan is used up (taken from user reports, not official docs; widen as new wordings show up).
quota_rx='hit your (session|usage) limit|usage limit reached|usage_limit_reached|quota reached|RESOURCE_EXHAUSTED|Resource has been exhausted|rate limit(ed| reached| exceeded)|(HTTP|code|status)[ :]+429'
# When the message says when it resets ("Try again at Apr 30th, 2026 11:21 AM", "Resets in 1h00m00s"), use that; otherwise 60 minutes.
quota_reset() {   # text -> epoch
    local text="$1" now mins=0 d h m s
    now="$(date +%s)"
    if [[ "$text" =~ Resets?\ in[[:space:]]+(([0-9]+)d)?[[:space:]]*(([0-9]+)h)?[[:space:]]*(([0-9]+)m)? ]]; then
        d="${BASH_REMATCH[2]:-0}"; h="${BASH_REMATCH[4]:-0}"; m="${BASH_REMATCH[6]:-0}"
        mins=$((1440 * d + 60 * h + m))
        ((mins > 0)) && { echo $((now + (mins + 1) * 60)); return; }
    fi
    if [[ "$text" =~ Try\ again\ at[[:space:]]+([A-Za-z]{3,9}[[:space:]]+[0-9]{1,2})(st|nd|rd|th)?,?[[:space:]]*([0-9]{4})?,?[[:space:]]*([0-9]{1,2}:[0-9]{2}[[:space:]]*[AaPp][Mm])? ]]; then
        s="$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]}" +%s 2>/dev/null)"
        if [[ "$s" =~ ^[0-9]+$ ]] && ((s > now && s < now + 864000)); then echo "$s"; return; fi
    fi
    echo $((now + 3600))
}
fmt_epoch() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'; }
if ((!history)) && [[ -n "$target" && -n "$task" ]]; then
    q="${target,,}"; [[ "$q" == gemini ]] && q=agy
    if ((!ignore_quota)) && hold="$(quota_hold "$q")"; then
        echo "tai delegate: quota - $q ran out earlier; skipped until $(fmt_epoch "$hold"). Send this step to another target, or add --ignore-quota to try anyway." >&2
        echo "Delegation quota. $q is out of quota until about $(fmt_epoch "$hold"). Send this step to another target."
        exit 3
    fi
fi

# ---- Worktree: run in a new git worktree of the project (own branch, own .tai, therefore own lock) ----------------
orig_dir="$dir" wt_note=""
if ((worktree && !history)) && [[ -n "$target" && -n "$task" ]]; then
    tg="${target,,}"; [[ "$tg" == gemini ]] && tg=agy
    # Same checks as below, done first so a refused delegation leaves no worktree behind.
    command -v jq >/dev/null 2>&1 || stop "needs jq"
    [[ "$(jq -r --arg a "$tg" '.[$a].headless // empty | type' "$REGISTRY" 2>/dev/null)" == object ]] \
        && command -v "$(agent_exe "$tg")" >/dev/null 2>&1 && [[ -z "${TAI_DELEGATE_DEPTH:-}" || "${TAI_DELEGATE_DEPTH}" == 0 ]] \
        || stop "'$tg' cannot be delegated to here (not headless, not installed, or depth limit)"
    git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 || stop "--worktree needs a git project"
    branch="tai-$tg-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    wt_dir="$(dirname "$dir")/$(basename "$dir")-$branch"
    wt_out="$(git -C "$dir" worktree add -b "$branch" "$wt_dir" 2>&1)" || stop "could not create worktree: $wt_out"
    dir="$(cd "$wt_dir" && pwd)"
    wt_note="Worktree: $dir (branch $branch) - review it, then merge the branch or remove it with: git worktree remove \"$dir\""
fi
tai="$dir/.tai"; hist_dir="$tai/history"; hist_log="$hist_dir/delegations.jsonl"

# ---- History listing --------------------------------------------------------------------------------------------
if ((history)); then
    [[ -f "$hist_log" ]] || { echo "No delegations yet."; exit 0; }
    tail -n 20 "$hist_log" | jq -r '[(.time | sub("T"; " ") | .[0:16]), "\(.from)->\(.target)", .status, "\(.seconds)s",
        ((.task | split("\n")[0]) | if length > 70 then .[0:69] + "~" else . end), "[\(.reply)]"] | join("  ")' 2>/dev/null
    exit 0
fi

# A rule that allows (almost) everything is as bad as skipping permissions, so it needs --allow-wide.
# Wide: a bare tool name (Bash), a lone wildcard, a regex that matches anything, or a shell/interpreter that can run anything.
is_wide_rule() {
    local r inner re_any re_shell
    r="$(trim "$1")"
    [[ -z "$r" ]] && return 1
    re_any='^(regex:)?(\.\*|\*+|\^?\.\*\$?|:\*)?$'
    re_shell='^(regex:)?\^?(sh|bash|zsh|cmd|powershell|pwsh|python3?|node|ruby|perl|env|sudo|npx)(\.exe)?([[:space:]]|:|\\|\.|\*|\$|$)'
    if [[ "$r" =~ ^[^\(]+\((.*)\)$ ]]; then inner="$(trim "${BASH_REMATCH[1]}")"; else return 0; fi   # no argument part: the whole tool
    [[ "$inner" =~ $re_any ]] && return 0
    [[ "$inner" =~ $re_shell ]] && return 0
    return 1
}
wide=()
for r in "${allow[@]}"; do [[ -n "$r" ]] && is_wide_rule "$r" && wide+=("$r"); done
if ((${#wide[@]} && !allow_wide)); then
    stop "--allow rule too wide: $(IFS=,; echo "${wide[*]}"). It would let the target run almost anything. Give the exact command (for example 'Bash(npm test)'), or add --allow-wide if you really mean it."
fi

# ---- Checks -----------------------------------------------------------------------------------------------------
[[ -n "$target" && -n "$task" ]] || stop 'usage: delegate.sh <target> "<task>" [--project dir] [--summary text] [--files a,b] [--allow rule] [--edit] [--timeout n]  |  --history'
command -v jq >/dev/null 2>&1 || stop "needs jq"
target="${target,,}"
[[ "$target" == gemini ]] && target=agy   # gemini and agy are the same CLI
[[ -f "$REGISTRY" ]] || stop "agents.json not found"
if [[ "$(jq -r --arg a "$target" '.[$a].headless // empty | type' "$REGISTRY")" != object ]]; then
    ok="$(jq -r '[to_entries[] | select(.value.headless) | .key] | join(", ")' "$REGISTRY")"
    stop "'$target' cannot run headless here. Targets: $ok"
fi
exe_name="$(agent_exe "$target")"
exe="$(command -v "$exe_name")" || stop "'$target' is not installed (not on PATH)"
depth="${TAI_DELEGATE_DEPTH:-0}"; [[ "$depth" =~ ^[0-9]+$ ]] || depth=0
((depth >= 1)) && stop "a delegated agent cannot delegate again (depth limit 1)"

hcfg() { jq -r --arg a "$target" "$1" "$REGISTRY"; }   # one value from the target's headless block
harr() { mapfile -t "$1" < <(jq -r --arg a "$target" ".[\$a].headless.$2 // [] | .[]" "$REGISTRY"); }

mkdir -p "$hist_dir"
# A git project: keep .tai out of status locally without touching the project's .gitignore.
if [[ -d "$orig_dir/.git" ]]; then   # the exclude file is shared with the project's worktrees
    mkdir -p "$orig_dir/.git/info"
    grep -qxF '.tai/' "$orig_dir/.git/info/exclude" 2>/dev/null || echo '.tai/' >> "$orig_dir/.git/info/exclude"
fi

# One delegation per target at a time: a second one would overwrite the first one's files.
lock="$tai/running-$target.lock"
if [[ -f "$lock" ]]; then
    old_pid="$(jq -r '.pid // empty' "$lock" 2>/dev/null)"
    mt="$(file_mtime "$lock")"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null && ((  $(date +%s) - ${mt:-0} < timeout_sec + 120 )); then
        stop "a delegation to $target is already running in this project"
    fi
    rm -f "$lock"
fi
jq -nc --argjson pid "$$" --argjson since "$(date +%s)" '{pid: $pid, since: $since}' | write_atomic "$lock"

from="${TAI_AGENT:-user}"
mode=read-only; ((edit)) && mode=edit
task_file="$tai/task-$target.md"; reply_file="$tai/reply-$target.md"; set_file="$tai/run-$target.settings.json"
out_file="$tai/run-$target.out"; err_file="$tai/run-$target.err"; stamp_file="$tai/run-$target.stamp"
t0="$(date +%s)"; t0_iso="$(date +%Y-%m-%dT%H:%M:%S)"
status=failed reason="" body="" changed=()
pid=""

cleanup() {
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && { pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; }
    rm -f "$out_file" "$err_file" "$stamp_file" "$set_file" "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---- Task file --------------------------------------------------------------------------------------------------
{
    echo "# Task for $target"
    echo "From: $from | Mode: $mode | ${t0_iso:0:16}"
    echo
    echo "## Task"
    limit_text "$task" "$MAX_TASK"; echo
    if [[ -n "$summary" ]]; then
        echo; echo "## Context from the agent that asked"
        limit_text "$summary" "$MAX_SUMMARY"; echo
    fi
} > "$task_file.tmp.$$"
file_list=()
for f in "${files[@]}"; do
    IFS=',' read -ra parts <<< "$f"
    for x in "${parts[@]}"; do x="$(trim "$x")"; [[ -n "$x" ]] && file_list+=("$x"); done
done
file_list=("${file_list[@]:0:$MAX_CHANGED}")
{
    if ((${#file_list[@]})); then echo; echo "## Files to look at"; for f in "${file_list[@]}"; do echo "- $f"; done; fi
    echo; echo "## How to answer"
    echo "Your final message goes straight back to the agent that asked, so make it a self-contained answer (findings, decisions, file names). Keep it short."
    if ((edit)); then echo "You may change files in this folder if the task needs it; list every file you changed."
    else echo "Read-only: do not create, change or delete files."; fi
} >> "$task_file.tmp.$$"
mv -f "$task_file.tmp.$$" "$task_file"
rm -f "$reply_file"   # a leftover reply must never pass for the new one

# ---- Launch -----------------------------------------------------------------------------------------------------
prompt="Read .tai/task-$target.md in the current folder and carry out the task described there. Your final message is returned to the agent that asked."
allow_flag="$(hcfg '.[$a].headless.allowFlag // empty')"
settings_flag="$(hcfg '.[$a].headless.settingsFlag // empty')"
harr h_args args; harr h_mode "$( ((edit)) && echo edit || echo readonly )"; harr h_prompt prompt
harr h_defallow defaultAllow; harr h_deny readonlyDeny
rules=()
for r in "${h_defallow[@]}" "${allow[@]}"; do [[ -n "$r" ]] && rules+=("$r"); done   # defaultAllow: harmless read-only commands
if [[ -n "$settings_flag" ]]; then
    # agy only understands an exact command or "regex:..."; a glob like command(git status*) never matches, so turn globs into regex.
    conv=()
    for r in "${rules[@]}"; do
        if [[ "$r" == *'('*')' ]]; then
            tool="${r%%\(*}"; inner="${r#*\(}"; inner="${inner%\)}"
            if [[ "$inner" != regex:* && "$inner" == *'*'* ]]; then
                inner="${inner/%:\*/ *}"
                inner="$(printf '%s' "$inner" | sed -e 's/[][\\.^$|?+(){}]/\\&/g' -e 's/\*/.*/g')"
                r="$tool(regex:$inner)"
            fi
        fi
        conv+=("$r")
    done
    rules=("${conv[@]}")
fi
extra=()
if [[ -n "$allow_flag" ]] && ((${#rules[@]})); then extra+=("$allow_flag" "$(IFS=,; echo "${rules[*]}")"); fi
if [[ -n "$settings_flag" ]]; then
    deny=(); ((edit)) || deny=("${h_deny[@]}")
    if ((${#rules[@]} || ${#deny[@]})); then
        jq -n --argjson a "$(printf '%s\n' "${rules[@]}" | jq -R . | jq -s .)" \
              --argjson d "$(printf '%s\n' "${deny[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
              '{permissions: {allow: ($a | map(select(. != ""))), deny: $d}}' > "$set_file"
        extra+=("$settings_flag" "$set_file")
    fi
fi
argv=("${h_args[@]}" "${h_mode[@]}" "${extra[@]}" "${h_prompt[@]}" "$prompt")

touch "$stamp_file"
(
    agent_env "$target"
    set_agent_account_env "$target" "$(project_account "$orig_dir" "$target")"
    export TAI_DELEGATE_DEPTH=$((depth + 1)) TAI_PROJECT_DIR="$dir" TAI_AGENT="$target"
    cd "$dir" && exec "$exe" "${argv[@]}"
) < /dev/null > "$out_file" 2> "$err_file" &   # empty stdin: a headless CLI must never wait for typing
pid=$!
deadline=$((t0 + timeout_sec))
while kill -0 "$pid" 2>/dev/null && (($(date +%s) < deadline)); do sleep 0.5; done
if kill -0 "$pid" 2>/dev/null; then
    status="timed out"; reason="no answer within $timeout_sec s"
    pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; sleep 1
    pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
else
    wait "$pid"; code=$?
    body="$(trim "$(cat "$out_file" 2>/dev/null)")"
    err_all="$(trim "$(cat "$err_file" 2>/dev/null)")"
    # Out of quota: the CLI failed, or answered with only a short limit message (a long real answer may merely mention quotas).
    if { ((code != 0)) && [[ "$body"$'\n'"$err_all" =~ $quota_rx ]]; } || { ((${#body} < 400)) && [[ "$body" =~ $quota_rx ]]; } \
        || { [[ -z "$body" ]] && [[ "$err_all" =~ $quota_rx ]]; }; then
        status=quota
        until_ep="$(quota_reset "$body $err_all")"
        mkdir -p "$quota_dir" 2>/dev/null
        jq -nc --argjson u "$until_ep" '{until: $u}' | write_atomic "$quota_dir/quota-$target.json"
        reason="$target is out of quota (skipped until about $(fmt_epoch "$until_ep")). Send this step to another target. Target said: $(limit_text "$(trim "$body $err_all")" 300)"
        body=""
    elif ((code == 0)) && [[ "$body" == *"matches a user-configured deny rule"* ]]; then
        status=blocked
        reason="$target was refused by a deny rule (read-only mode blocks file writes). Re-run with --edit if the task needs to change files."
    elif ((code == 0)) && [[ -n "$body" ]]; then
        status=done
    else
        status=failed
        err="$(trim "$(cat "$err_file" 2>/dev/null)")"
        ((${#err} > 300)) && err="${err:0:300}..."
        if [[ "$err" == *"cannot prompt for"* ]]; then
            status=blocked
            reason="$target needed a permission that headless mode cannot ask for (a shell command, or a file write in read-only mode). Re-run with --allow <rule> for that command, or hand the task to another agent."
            [[ -n "$err" ]] && reason+=" Target said: $err"
        else
            reason="exit code $code"
            [[ -z "$body" ]] && reason+=", no answer"
            [[ -n "$err" ]] && reason+=": $err"
        fi
    fi
fi
pid=""

# ---- Changed files (edit mode only) -----------------------------------------------------------------------------
if ((edit)); then
    mapfile -t changed < <(find "$dir" \( -name node_modules -o -name .git -o -name .tai -o -name bin -o -name obj -o -name dist \
        -o -name build -o -name __pycache__ -o -name .venv -o -name venv -o -name target \) -prune -o -type f -newer "$stamp_file" -print 2>/dev/null | head -n $((MAX_CHANGED + 1)))
fi

seconds=$(($(date +%s) - t0))
changed_names=()
for f in "${changed[@]:0:$MAX_CHANGED}"; do changed_names+=("${f#"$dir"/}"); done
more=""; ((${#changed[@]} > MAX_CHANGED)) && more=" (+ more)"
changed_line="Files changed: $(IFS=,; echo "${changed_names[*]}" | sed 's/,/, /g')$more"

# ---- Reply file, history ----------------------------------------------------------------------------------------
{
    echo "<!-- tai delegate: from=$from target=$target status=$status seconds=$seconds -->"
    if [[ "$status" == done ]]; then limit_text "$body" "$MAX_REPLY"; echo
    else
        echo "Delegation $status. $reason"
        [[ -n "$body" ]] && { echo; limit_text "$body" "$MAX_REPLY"; echo; }
    fi
    ((${#changed_names[@]})) && { echo; echo "$changed_line"; }
} | write_atomic "$reply_file"

stamp="$(date -d "@$t0" +%Y%m%d-%H%M%S 2>/dev/null || date -r "$t0" +%Y%m%d-%H%M%S)"
saved="$hist_dir/$stamp-$target.md"
if cp -f "$reply_file" "$saved" 2>/dev/null; then
    jq -nc --arg time "$t0_iso" --argjson epoch "$t0" --arg from "$from" --arg target "$target" --arg mode "$mode" --arg status "$status" \
        --argjson seconds "$seconds" --argjson allow "$(printf '%s\n' "${allow[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
        --argjson wide "$( ((${#wide[@]})) && echo true || echo false )" --arg task "$(limit_text "$task" 500)" \
        --argjson changed "$(printf '%s\n' "${changed_names[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" --arg reply "history/$stamp-$target.md" \
        '{time: $time, epoch: $epoch, from: $from, target: $target, mode: $mode, status: $status, seconds: $seconds, allow: $allow, wide: $wide, task: $task, changed: $changed, reply: $reply}' >> "$hist_log"
    # Keep the newest runs and drop anything older than the age limit.
    cut=$(($(date +%s) - KEEP_DAYS * 86400))
    kept="$(jq -c --argjson cut "$cut" 'select((.epoch // 0) >= $cut)' "$hist_log" 2>/dev/null | tail -n "$KEEP_RUNS")"
    printf '%s\n' "$kept" | write_atomic "$hist_log"
    keep_names="$(printf '%s\n' "$kept" | jq -r '.reply | split("/") | last' 2>/dev/null)"
    for f in "$hist_dir"/*.md; do
        [[ -e "$f" ]] || continue
        grep -qxF -- "$(basename "$f")" <<< "$keep_names" || rm -f "$f"
    done
fi

# ---- Back to the caller -----------------------------------------------------------------------------------------
if [[ "$status" == done ]]; then limit_text "$body" "$MAX_REPLY"; echo; else echo "Delegation $status. $reason"; fi
((${#changed_names[@]})) && echo "$changed_line"
[[ -n "$wt_note" ]] && echo "$wt_note"
echo "[tai delegate: $target $status in ${seconds}s - reply saved to .tai/reply-$target.md]"
case "$status" in done) exit 0 ;; "timed out") exit 2 ;; quota) exit 3 ;; *) exit 1 ;; esac
