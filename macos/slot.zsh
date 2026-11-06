#!/usr/bin/env zsh
# Runs one project's coding CLI inside its tmux pane: resumes the last conversation (or starts a fresh one),
# and when the CLI exits by itself offers restart / switch CLI / close. The pane closes when this script ends.
# Usage: slot.zsh <name> <path> <agent|->
. "${0:A:h}/lib.zsh"

name="$1" ppath="$2" agent="${3:--}"
[[ "$agent" == "-" ]] && agent=claude
cd "$ppath" 2>/dev/null || { echo "Folder not found: $ppath"; sleep 4; exit 1; }   # say why the pane closes
update_installed

export TAI_PROJECT_DIR="$ppath"
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1

installed() { command -v "$(agent_exe "$1")" >/dev/null 2>&1; }

# Leaves no hook / sub-agent state behind when the pane goes away (closed, killed or window gone).
cleanup() { local key; key="$(state_key "$ppath")"; rm -f "$STATE_DIR/hook_$key.json" "$STATE_DIR/subs_$key.txt"; }
trap cleanup EXIT
trap 'exit 0' HUP TERM

start_agent() {   # resume|fresh
    agent_env "$agent"
    set_agent_account_env "$agent" "$(project_account "$ppath" "$agent")"   # read each launch, so U + restart picks it up
    agent_args "$agent" "$1" "$name"   # fills ARGV from agents.json
    # Agents run slightly niced so the dashboard, tmux and the terminal stay responsive when the machine is busy
    # (raising the UI's own priority needs root). TAI_AGENT_NICE=0 turns it off; the default is 5.
    local n="${TAI_AGENT_NICE:-5}"
    if [[ "$n" == <-> && "$n" -gt 0 ]] && command -v nice >/dev/null 2>&1; then
        nice -n "$n" "$(agent_exe "$agent")" "${ARGV[@]}"
    else
        "$(agent_exe "$agent")" "${ARGV[@]}"
    fi
}

# Chosen CLI not installed: use the first one that is (the saved choice stays unchanged).
if ! installed "$agent"; then
    alt=""
    for a in "${AGENTS[@]}"; do installed "$a" && { alt="$a"; break; }; done
    if [[ -z "$alt" ]]; then
        print "No supported CLI (${AGENTS[*]}) found on PATH."; sleep 4; exit 1
    fi
    print "'$agent' is not installed - using '$alt' instead."; sleep 2
    agent="$alt"
    tmux set-option -p -t "$TMUX_PANE" @tai_agent "$agent" 2>/dev/null   # the dashboard shows what actually runs
fi

# Reads one key into $KEY ("up", "down", "enter", a digit, or "other"); returns 1 after 3 s without a key.
read_key() {
    local k rest=""
    read -rs -k 1 -t 3 k || return 1
    if [[ "$k" == $'\e' ]]; then
        read -rs -k 2 -t 0.05 rest
        case "$rest" in '[A'|'OA') KEY=up ;; '[B'|'OB') KEY=down ;; *) KEY=other ;; esac
    elif [[ "$k" == $'\n' || "$k" == $'\r' ]]; then KEY=enter
    else KEY="$k"; fi
}

# Menu shown when the CLI ended by itself. Sets ACTION: restart, switch:<cli> or close.
exit_menu() {
    local -a choices=("Restart $agent") acts=(restart)
    local a idx=1 n
    for a in "${AGENTS[@]}"; do
        [[ "$a" != "$agent" ]] && installed "$a" && { choices+=("Switch to $a"); acts+=("switch:$a"); }
    done
    choices+=("Close project (and pane)"); acts+=(close)
    ACTION=close
    while true; do
        printf '\e[H\e[2J'
        print -r -- "$agent exited in $name"
        for ((n = 1; n <= ${#choices}; n++)); do
            if ((n == idx)); then printf '\e[7m> %s\e[0m\n' "${choices[n]}"; else printf '  %s\n' "${choices[n]}"; fi
        done
        printf '\e[90mUp/Down + Enter, or 1-%d. Esc or 3 s idle: close pane\e[0m\n' "${#choices}"
        read_key || { ACTION=close; return; }
        case "$KEY" in
            up)    idx=$(((idx + ${#choices} - 2) % ${#choices} + 1)) ;;
            down)  idx=$((idx % ${#choices} + 1)) ;;
            enter) ACTION="${acts[idx]}"; return ;;
            [1-9]) if ((KEY <= ${#choices})); then ACTION="${acts[KEY]}"; return; fi ;;
            *)     ACTION=close; return ;;
        esac
    done
}

while true; do
    export TAI_AGENT="$agent"
    printf '\e[H\e[2J'
    SECONDS=0
    start_agent resume
    rc=$?
    # Nothing to continue (new project): the command fails fast, so start a fresh session.
    if ((rc != 0 && SECONDS < 3)); then
        print "No earlier conversation to continue (or it failed to load) - starting a new one."
        start_agent fresh
    fi
    exit_menu
    case "$ACTION" in
        restart) ;;
        switch:*)
            agent="${ACTION#switch:}"; set_agent "$ppath" "$agent"
            tmux set-option -p -t "$TMUX_PANE" @tai_agent "$agent" 2>/dev/null
            tmux set-option -p -t "$TMUX_PANE" @tai_since "$EPOCHSECONDS" 2>/dev/null ;;
        *) exit 0 ;;
    esac
done
