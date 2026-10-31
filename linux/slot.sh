#!/usr/bin/env bash
# Runs one project's coding CLI inside its tmux pane: resumes the last conversation (or starts a fresh one),
# and when the CLI exits by itself offers restart / switch CLI / close. The pane closes when this script ends.
# Usage: slot.sh <name> <path> <agent|->
. "$(dirname "$(readlink -f "$0")")/lib.sh"

name="$1" path="$2" agent="${3:--}"
[[ "$agent" == "-" ]] && agent=claude
cd "$path" || exit 1
update_installed

export TAI_PROJECT_DIR="$path"
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1

installed() { command -v "$(agent_exe "$1")" >/dev/null 2>&1; }

# Leaves no hook / sub-agent state behind when the pane goes away (closed, killed or window gone).
cleanup() { key="$(state_key "$path")"; rm -f "$STATE_DIR/hook_$key.json" "$STATE_DIR/subs_$key.txt"; }
trap cleanup EXIT
trap 'exit 0' HUP TERM

start_agent() {   # resume|fresh
    agent_env "$agent"
    agent_args "$agent" "$1" "$name"   # fills ARGV from agents.json (the Claude --settings flag is Windows-only)
    "$(agent_exe "$agent")" "${ARGV[@]}"
}

# Chosen CLI not installed: use the first one that is (the saved choice stays unchanged).
if ! installed "$agent"; then
    alt=""
    for a in "${AGENTS[@]}"; do installed "$a" && { alt="$a"; break; }; done
    if [[ -z "$alt" ]]; then
        echo "No supported CLI (${AGENTS[*]}) found on PATH."; sleep 4; exit 1
    fi
    echo "'$agent' is not installed - using '$alt' instead."; sleep 2
    agent="$alt"
fi

# Reads one key into $KEY ("up", "down", "enter", a digit, or "other"); returns 1 after 5 s without a key.
read_key() {
    local k rest
    IFS= read -rsn1 -t 3 k || return 1
    if [[ "$k" == $'\e' ]]; then
        IFS= read -rsn2 -t 0.05 rest
        case "$rest" in '[A') KEY=up ;; '[B') KEY=down ;; *) KEY=other ;; esac
    elif [[ -z "$k" ]]; then KEY=enter
    else KEY="$k"; fi
}

# Menu shown when the CLI ended by itself. Prints the chosen action: restart, switch:<cli> or close.
exit_menu() {
    local choices=("Restart $agent") acts=(restart) a idx=0 n
    for a in "${AGENTS[@]}"; do
        [[ "$a" != "$agent" ]] && installed "$a" && { choices+=("Switch to $a"); acts+=("switch:$a"); }
    done
    choices+=("Close project (and pane)"); acts+=(close)
    while true; do
        clear
        echo "$agent exited in $name"
        for n in "${!choices[@]}"; do
            if ((n == idx)); then printf '\e[7m> %s\e[0m\n' "${choices[n]}"; else printf '  %s\n' "${choices[n]}"; fi
        done
        printf '\e[90mUp/Down + Enter, or 1-%d. Esc or 3 s idle: close pane\e[0m\n' "${#choices[@]}"
        read_key || { echo close; return; }
        case "$KEY" in
            up)    idx=$(((idx + ${#choices[@]} - 1) % ${#choices[@]})) ;;
            down)  idx=$(((idx + 1) % ${#choices[@]})) ;;
            enter) echo "${acts[idx]}"; return ;;
            [1-9]) ((KEY <= ${#choices[@]})) && { echo "${acts[KEY - 1]}"; return; } ;;
            *)     echo close; return ;;
        esac
    done
}

while true; do
    export TAI_AGENT="$agent"
    clear
    SECONDS=0
    start_agent resume
    status=$?
    # Nothing to continue (new project): the command fails fast, so start a fresh session.
    if ((status != 0 && SECONDS < 3)); then
        echo "No earlier conversation to continue (or it failed to load) - starting a new one."
        start_agent fresh
    fi
    action="$(exit_menu)"
    case "$action" in
        restart) ;;
        switch:*)
            agent="${action#switch:}"; set_agent "$path" "$agent"
            tmux set-option -p -t "$TMUX_PANE" @tai_agent "$agent" 2>/dev/null
            tmux set-option -p -t "$TMUX_PANE" @tai_since "$(date +%s)" 2>/dev/null ;;
        *) exit 0 ;;
    esac
done
