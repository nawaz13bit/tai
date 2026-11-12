#!/usr/bin/env zsh
# tai delegate: one agent hands a task to another CLI, which runs headless (one-shot) in the same project folder.
# The task goes in <project>/.tai/task-<target>.md, the answer comes back in <project>/.tai/reply-<target>.md (and on stdout).
# Usage (from an agent's shell, or by hand):
#   delegate.zsh <target> "<task>" [--project <dir>] [--summary "<what has been done>"] [--files a.txt,b.txt]
#                                  [--allow "<rule>"]... [--allow-wide] [--edit] [--timeout 600]
#   delegate.zsh --history [--project <dir>]       list past delegations of the project
# (target gemini is accepted as an alias of agy.) Read-only by default; --edit lets the target change files
# (use a worktree if the caller is editing too). --allow adds a command the target may run without asking, in the
# target's own rule syntax (claude: "Bash(git status)", agy: "command(git status)"). A rule that allows (almost)
# everything is refused unless --allow-wide is given.
# Exit code: 0 done, 1 failed or refused, 2 timed out.
# (zsh has special variables named status, path, argv and history, so this script avoids those names.)
. "${0:A:h}/lib.zsh"
setopt extended_glob

MAX_TASK=4000 MAX_SUMMARY=3000 MAX_REPLY=20000 MAX_CHANGED=30 KEEP_RUNS=50 KEEP_DAYS=30

stop() { print -r -- "tai delegate: $1" >&2; exit "${2:-1}"; }

limit_text() {   # text max
    if (( ${#1} <= $2 )); then print -rn -- "$1"; else print -rn -- "${1[1,$2]}"; print -r -- ""; print -rn -- "[cut at $2 characters]"; fi
}

trim() { local s="$1"; s="${s##[[:space:]]##}"; print -rn -- "${s%%[[:space:]]##}"; }

target="" task="" proj="" summary="" allow_wide=0 edit=0 timeout_sec=600 do_hist=0
typeset -a files allow
files=() allow=()
npos=0
while (( $# )); do
    case "$1" in
        --project)    proj="${2:-}"; shift ;;
        --summary)    summary="${2:-}"; shift ;;
        --files)      files+=("${2:-}"); shift ;;
        --allow)      allow+=("${2:-}"); shift ;;
        --allow-wide) allow_wide=1 ;;
        --edit)       edit=1 ;;
        --timeout)    timeout_sec="${2:-600}"; shift ;;
        --history)    do_hist=1 ;;
        *)            if (( npos == 0 )); then target="$1"; elif (( npos == 1 )); then task="$1"; fi; npos=$((npos + 1)) ;;
    esac
    shift
done
[[ "$timeout_sec" == <-> ]] || stop "--timeout needs a number of seconds"

dir="${proj:-${TAI_PROJECT_DIR:-$PWD}}"
[[ -d "$dir" ]] || stop "folder not found: $dir"
dir="${dir:A}"
tai="$dir/.tai"; hist_dir="$tai/history"; hist_log="$hist_dir/delegations.jsonl"

# ---- History listing --------------------------------------------------------------------------------------------
if (( do_hist )); then
    [[ -f "$hist_log" ]] || { print "No delegations yet."; exit 0; }
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
    if [[ "$r" =~ '^[^(]+\((.*)\)$' ]]; then inner="$(trim "${match[1]}")"; else return 0; fi   # no argument part: the whole tool
    [[ "$inner" =~ $re_any ]] && return 0
    [[ "$inner" =~ $re_shell ]] && return 0
    return 1
}
wide=()
for r in "${allow[@]}"; do [[ -n "$r" ]] && is_wide_rule "$r" && wide+=("$r"); done
if (( ${#wide} && ! allow_wide )); then
    stop "--allow rule too wide: ${(j:,:)wide}. It would let the target run almost anything. Give the exact command (for example 'Bash(npm test)'), or add --allow-wide if you really mean it."
fi

# ---- Checks -----------------------------------------------------------------------------------------------------
[[ -n "$target" && -n "$task" ]] || stop 'usage: delegate.zsh <target> "<task>" [--project dir] [--summary text] [--files a,b] [--allow rule] [--edit] [--timeout n]  |  --history'
command -v jq >/dev/null 2>&1 || stop "needs jq"
target="${(L)target}"
[[ "$target" == gemini ]] && target=agy   # gemini and agy are the same CLI
[[ -f "$REGISTRY" ]] || stop "agents.json not found"
if [[ "$(jq -r --arg a "$target" '.[$a].headless // empty | type' "$REGISTRY")" != object ]]; then
    ok="$(jq -r '[to_entries[] | select(.value.headless) | .key] | join(", ")' "$REGISTRY")"
    stop "'$target' cannot run headless here. Targets: $ok"
fi
exe_name="$(agent_exe "$target")"
exe="$(command -v "$exe_name")" || stop "'$target' is not installed (not on PATH)"
depth="${TAI_DELEGATE_DEPTH:-0}"; [[ "$depth" == <-> ]] || depth=0
(( depth >= 1 )) && stop "a delegated agent cannot delegate again (depth limit 1)"

hcfg() { jq -r --arg a "$target" "$1" "$REGISTRY"; }   # one value from the target's registry entry
harr() {   # array-name key-in-headless -> fills the named array with the registry's string array
    local out
    out="$(jq -r --arg a "$target" ".[\$a].headless.$2 // [] | .[]" "$REGISTRY")"
    eval "$1=( \${(f)out} )"
}

mkdir -p "$hist_dir"
# A git project: keep .tai out of status locally without touching the project's .gitignore.
if [[ -d "$dir/.git" ]]; then
    mkdir -p "$dir/.git/info"
    grep -qxF '.tai/' "$dir/.git/info/exclude" 2>/dev/null || print -r -- '.tai/' >> "$dir/.git/info/exclude"
fi

# One delegation per target at a time: a second one would overwrite the first one's files.
lock="$tai/running-$target.lock"
if [[ -f "$lock" ]]; then
    old_pid="$(jq -r '.pid // empty' "$lock" 2>/dev/null)"
    mt="$(file_mtime "$lock")"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null && (( EPOCHSECONDS - ${mt:-0} < timeout_sec + 120 )); then
        stop "a delegation to $target is already running in this project"
    fi
    rm -f "$lock"
fi
jq -nc --argjson pid "$$" --argjson since "$EPOCHSECONDS" '{pid: $pid, since: $since}' | write_atomic "$lock"

from="${TAI_AGENT:-user}"
mode=read-only; (( edit )) && mode=edit
task_file="$tai/task-$target.md"; reply_file="$tai/reply-$target.md"; set_file="$tai/run-$target.settings.json"
out_file="$tai/run-$target.out"; err_file="$tai/run-$target.err"; stamp_file="$tai/run-$target.stamp"
t0=$EPOCHSECONDS; t0_iso="$(strftime '%Y-%m-%dT%H:%M:%S' $t0)"
st=failed reason="" body=""
changed=()
bgpid=""

cleanup() {
    [[ -n "$bgpid" ]] && kill -0 "$bgpid" 2>/dev/null && { pkill -TERM -P "$bgpid" 2>/dev/null; kill -TERM "$bgpid" 2>/dev/null; }
    rm -f "$out_file" "$err_file" "$stamp_file" "$set_file" "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---- Task file --------------------------------------------------------------------------------------------------
file_list=()
for f in "${files[@]}"; do
    for x in "${(@s:,:)f}"; do x="$(trim "$x")"; [[ -n "$x" ]] && file_list+=("$x"); done
done
file_list=("${(@)file_list[1,$MAX_CHANGED]}")
{
    print -r -- "# Task for $target"
    print -r -- "From: $from | Mode: $mode | ${t0_iso[1,16]}"
    print
    print -r -- "## Task"
    limit_text "$task" "$MAX_TASK"; print
    if [[ -n "$summary" ]]; then
        print; print -r -- "## Context from the agent that asked"
        limit_text "$summary" "$MAX_SUMMARY"; print
    fi
    if (( ${#file_list} )); then print; print -r -- "## Files to look at"; for f in "${file_list[@]}"; do print -r -- "- $f"; done; fi
    print; print -r -- "## How to answer"
    print -r -- "Your final message goes straight back to the agent that asked, so make it a self-contained answer (findings, decisions, file names). Keep it short."
    if (( edit )); then print -r -- "You may change files in this folder if the task needs it; list every file you changed."
    else print -r -- "Read-only: do not create, change or delete files."; fi
} > "$task_file.tmp.$$"
mv -f "$task_file.tmp.$$" "$task_file"
rm -f "$reply_file"   # a leftover reply must never pass for the new one

# ---- Launch -----------------------------------------------------------------------------------------------------
prompt="Read .tai/task-$target.md in the current folder and carry out the task described there. Your final message is returned to the agent that asked."
allow_flag="$(hcfg '.[$a].headless.allowFlag // empty')"
settings_flag="$(hcfg '.[$a].headless.settingsFlag // empty')"
harr h_args args
if (( edit )); then harr h_mode edit; else harr h_mode readonly; fi
harr h_prompt prompt
harr h_defallow defaultAllow; harr h_deny readonlyDeny
rules=()
for r in "${h_defallow[@]}" "${allow[@]}"; do [[ -n "$r" ]] && rules+=("$r"); done   # defaultAllow: harmless read-only commands
extra=()
if [[ -n "$allow_flag" ]] && (( ${#rules} )); then extra+=("$allow_flag" "${(j:,:)rules}"); fi
if [[ -n "$settings_flag" ]]; then
    deny=(); (( edit )) || deny=("${h_deny[@]}")
    if (( ${#rules} || ${#deny} )); then
        jq -n --argjson a "$(printf '%s\n' "${rules[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
              --argjson d "$(printf '%s\n' "${deny[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
              '{permissions: {allow: $a, deny: $d}}' > "$set_file"
        extra+=("$settings_flag" "$set_file")
    fi
fi
cmd_args=("${h_args[@]}" "${h_mode[@]}" "${extra[@]}" "${h_prompt[@]}" "$prompt")

touch "$stamp_file"
(
    agent_env "$target"
    set_agent_account_env "$target" "$(project_account "$dir" "$target")"
    export TAI_DELEGATE_DEPTH=$((depth + 1)) TAI_PROJECT_DIR="$dir" TAI_AGENT="$target"
    cd "$dir" && exec "$exe" "${cmd_args[@]}"
) < /dev/null > "$out_file" 2> "$err_file" &   # empty stdin: a headless CLI must never wait for typing
bgpid=$!
deadline=$((t0 + timeout_sec))
while kill -0 "$bgpid" 2>/dev/null && (( EPOCHSECONDS < deadline )); do sleep 0.5; done
if kill -0 "$bgpid" 2>/dev/null; then
    st="timed out"; reason="no answer within $timeout_sec s"
    pkill -TERM -P "$bgpid" 2>/dev/null; kill -TERM "$bgpid" 2>/dev/null; sleep 1
    pkill -KILL -P "$bgpid" 2>/dev/null; kill -KILL "$bgpid" 2>/dev/null
    wait "$bgpid" 2>/dev/null
else
    wait "$bgpid"; code=$?
    body="$(trim "$(cat "$out_file" 2>/dev/null)")"
    if (( code == 0 )) && [[ "$body" == *"matches a user-configured deny rule"* ]]; then
        st=blocked
        reason="$target was refused by a deny rule (read-only mode blocks file writes). Re-run with --edit if the task needs to change files."
    elif (( code == 0 )) && [[ -n "$body" ]]; then
        st=done
    else
        st=failed
        err="$(trim "$(cat "$err_file" 2>/dev/null)")"
        (( ${#err} > 300 )) && err="${err[1,300]}..."
        if [[ "$err" == *"cannot prompt for"* ]]; then
            st=blocked
            reason="$target needed a permission that headless mode cannot ask for (a shell command, or a file write in read-only mode). Re-run with --allow <rule> for that command, or hand the task to another agent."
            [[ -n "$err" ]] && reason+=" Target said: $err"
        else
            reason="exit code $code"
            [[ -z "$body" ]] && reason+=", no answer"
            [[ -n "$err" ]] && reason+=": $err"
        fi
    fi
fi
bgpid=""

# ---- Changed files (edit mode only) -----------------------------------------------------------------------------
if (( edit )); then
    changed=( ${(f)"$(find "$dir" \( -name node_modules -o -name .git -o -name .tai -o -name bin -o -name obj -o -name dist \
        -o -name build -o -name __pycache__ -o -name .venv -o -name venv -o -name target \) -prune -o -type f -newer "$stamp_file" -print 2>/dev/null | head -n $((MAX_CHANGED + 1)))"} )
fi

seconds=$(( EPOCHSECONDS - t0 ))
changed_names=()
for f in "${(@)changed[1,$MAX_CHANGED]}"; do changed_names+=("${f#$dir/}"); done
more=""; (( ${#changed} > MAX_CHANGED )) && more=" (+ more)"
changed_line="Files changed: ${(j:, :)changed_names}$more"

# ---- Reply file, history ----------------------------------------------------------------------------------------
{
    print -r -- "<!-- tai delegate: from=$from target=$target status=$st seconds=$seconds -->"
    if [[ "$st" == done ]]; then limit_text "$body" "$MAX_REPLY"; print
    else
        print -r -- "Delegation $st. $reason"
        [[ -n "$body" ]] && { print; limit_text "$body" "$MAX_REPLY"; print; }
    fi
    (( ${#changed_names} )) && { print; print -r -- "$changed_line"; }
} | write_atomic "$reply_file"

stamp="$(strftime '%Y%m%d-%H%M%S' $t0)"
saved="$hist_dir/$stamp-$target.md"
if cp -f "$reply_file" "$saved" 2>/dev/null; then
    jq -nc --arg time "$t0_iso" --argjson epoch "$t0" --arg from "$from" --arg target "$target" --arg mode "$mode" --arg status "$st" \
        --argjson seconds "$seconds" --argjson allow "$(printf '%s\n' "${allow[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
        --argjson wide "$( (( ${#wide} )) && echo true || echo false )" --arg task "$(limit_text "$task" 500)" \
        --argjson changed "$(printf '%s\n' "${changed_names[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" --arg reply "history/$stamp-$target.md" \
        '{time: $time, epoch: $epoch, from: $from, target: $target, mode: $mode, status: $status, seconds: $seconds, allow: $allow, wide: $wide, task: $task, changed: $changed, reply: $reply}' >> "$hist_log"
    # Keep the newest runs and drop anything older than the age limit.
    cut=$(( EPOCHSECONDS - KEEP_DAYS * 86400 ))
    kept="$(jq -c --argjson cut "$cut" 'select((.epoch // 0) >= $cut)' "$hist_log" 2>/dev/null | tail -n "$KEEP_RUNS")"
    print -r -- "$kept" | write_atomic "$hist_log"
    keep_names="$(print -r -- "$kept" | jq -r '.reply | split("/") | last' 2>/dev/null)"
    for f in "$hist_dir"/*.md(N); do
        grep -qxF -- "${f:t}" <<< "$keep_names" || rm -f "$f"
    done
fi

# ---- Back to the caller -----------------------------------------------------------------------------------------
if [[ "$st" == done ]]; then limit_text "$body" "$MAX_REPLY"; print; else print -r -- "Delegation $st. $reason"; fi
(( ${#changed_names} )) && print -r -- "$changed_line"
print -r -- "[tai delegate: $target $st in ${seconds}s - reply saved to .tai/reply-$target.md]"
case "$st" in done) exit 0 ;; "timed out") exit 2 ;; *) exit 1 ;; esac
