#!/usr/bin/env bash
# Runs in its own tmux window (started by the dashboard's S key): tai's own agents screen for one project, on the
# project's account. Claude: background/live sessions from `claude agents --json`. Codex: tai's panes plus
# `codex queue` to message a session. Other CLIs: tai's own view of its panes (they cannot list running sessions).
# Usage: agentsview.sh <path> <agent> [account]
set -u
path="${1:?path}"; agent="${2:?agent}"; account="${3:-}"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$path" 2>/dev/null || { echo "Folder not found: $path"; sleep 3; exit 1; }
set_agent_account_env "$agent" "$account"
C_HEAD=$'\e[36m'; C_DIM=$'\e[90m'; C_WAIT=$'\e[35m'; C_WORK=$'\e[33m'; C_ERR=$'\e[31m'; C_RST=$'\e[0m'

state_color() {
    case "$1" in
        blocked|waiting) printf '%s' "$C_WAIT" ;;
        working|busy)    printf '%s' "$C_WORK" ;;
        failed)          printf '%s' "$C_ERR" ;;
        done|idle|stopped) printf '%s' "$C_DIM" ;;
        *) printf '' ;;
    esac
}

# Waits up to $1 seconds for one key (arrows come back as up/down); sets KEY, empty on timeout.
wait_key() {
    local k rest
    KEY=""
    IFS= read -rsn1 -t "$1" k || return 0
    if [[ "$k" == $'\e' ]]; then
        IFS= read -rsn2 -t 0.05 rest || true
        case "$rest" in '[A'|'OA') KEY=up ;; '[B'|'OB') KEY=down ;; '') KEY=esc ;; esac   # other sequences (Left, Home, ...) are ignored
    else
        KEY="${k,,}"
        [[ -z "$k" ]] && KEY=enter
    fi
}

press_any() { printf '\n%sPress any key to return%s' "$C_DIM" "$C_RST"; IFS= read -rsn1 _; }

confirm() { local k; printf '%s%s [y/N] %s' $'\e[33m' "$1" "$C_RST"; IFS= read -rsn1 k; echo; [[ "$k" == [yY] ]]; }

# tai's own panes running this agent: pane<TAB>project<TAB>state<TAB>model<TAB>quota
pane_rows() {
    local id ppath pagent since f st model q
    while IFS=$'\t' read -r id ppath pagent since; do
        [[ "$pagent" == "$agent" ]] || continue
        st=running; model=""; q=""
        f="$STATE_DIR/$(state_key "$ppath").json"
        if [[ -f "$f" ]]; then
            # "-" placeholders: read with a tab IFS collapses empty fields
            IFS=$'\t' read -r st model q < <(jq -r '[(.activity // "running"), (.model // "-"),
                (if .quota_left == null then "-" else "\(100 - (.quota_left | round))% used" end)] | @tsv' "$f" 2>/dev/null) || true
            [[ "$model" == "-" ]] && model=""; [[ "$q" == "-" ]] && q=""
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$(basename "$ppath")" "${st:-running}" "${model:--}" "${q:--}"
    done < <(tmux list-panes -s -t "$SESSION" -F '#{pane_id}'$'\t''#{@tai_path}'$'\t''#{@tai_agent}'$'\t''#{@tai_since}' 2>/dev/null |
             awk -F'\t' '$2 != ""')
}

show_panes() {   # title hint
    clear
    printf '%s%s%s\n\n' "$C_HEAD" "$1" "$C_RST"
    local rows n=0 id proj st model q
    rows="$(pane_rows)"
    if [[ -z "$rows" ]]; then printf '%sNo %s pane is running.%s\n' "$C_DIM" "$agent" "$C_RST"
    else
        printf '%-6s %-24s %-10s %-22s %s\n' PANE PROJECT STATE MODEL QUOTA
        while IFS=$'\t' read -r id proj st model q; do
            [[ "$model" == "-" ]] && model=""; [[ "$q" == "-" ]] && q=""
            printf '%s%-6s %-24s %-10s %-22s %s%s\n' "$(state_color "$st")" "$id" "${proj:0:24}" "$st" "${model:0:22}" "$q" "$C_RST"
        done <<< "$rows"
    fi
    printf '\n%s%s%s\n' "$C_DIM" "$2" "$C_RST"
}

# Claude sessions of this folder: id<TAB>name<TAB>state<TAB>kind<TAB>age<TAB>waitingFor ; blocked/waiting first.
claude_sessions() {
    local raw
    raw="$(claude agents --json --cwd "$path" 2>/dev/null)" || return 0
    [[ -n "$raw" ]] || return 0
    jq -r 'def d: if . == null or . == "" then "-" else tostring end;
           if type == "array" then . else [.] end
           | map({id: (.id // ""), name: (.name // ""), state: (.state // .status // "live"), kind: (.kind // ""),
                  wait: (.waitingFor // ""), pid: (.pid // ""),
                  age: (if .startedAt then ((now - (.startedAt / 1000)) / 60 | floor) else null end)})
           | sort_by([(if (.state == "blocked" or .state == "waiting") then 0 else 1 end), .name])
           | .[] | [(.id | d), (.name | d), (.state | d), (.kind | d),
                    (if .age == null then "-" elif .age >= 60 then "\(.age / 60 | floor)h\(.age % 60)m" else "\(.age)m" end),
                    (.wait | d), (.pid | d)] | @tsv' <<< "$raw" 2>/dev/null
}

show_claude() {
    local sel=0 next=0 n i line id name st kind age wait pid mark label extra k
    local -a rows=()
    while true; do
        if (($(date +%s) >= next)); then mapfile -t rows < <(claude_sessions); next=$(($(date +%s) + 3)); fi
        n=${#rows[@]}
        ((sel >= n)) && sel=$((n > 0 ? n - 1 : 0))
        clear
        printf '%sclaude agents - %s%s\n' "$C_HEAD" "$path" "$C_RST"
        [[ -n "$account" ]] && printf '%saccount: %s%s\n' "$C_DIM" "$account" "$C_RST"
        echo
        ((n)) || printf '%sNo Claude sessions for this project.%s\n' "$C_DIM" "$C_RST"
        for ((i = 0; i < n; i++)); do
            IFS=$'\t' read -r id name st kind age wait pid <<< "${rows[i]}"
            [[ "$id" == "-" ]] && id=""; [[ "$name" == "-" ]] && name=""; [[ "$age" == "-" ]] && age=""
            [[ "$kind" == "-" ]] && kind=""; [[ "$wait" == "-" ]] && wait=""
            mark=" "; ((i == sel)) && mark=">"
            label="${name:-${id:-pid $pid}}"
            extra=""; [[ -n "$wait" ]] && extra=" waiting for $wait"
            printf '%s%s %-9s %-28s %-6s %-10s%s%s\n' "$(state_color "$st")" "$mark" "$st" "${label:0:28}" "$age" "$kind" "$extra" "$C_RST"
        done
        printf '\n%sup/down select  Enter attach  l logs  x stop  r refresh  o claude agents  q close%s\n' "$C_DIM" "$C_RST"
        wait_key 1
        [[ -n "$KEY" ]] || continue
        id=""; ((n)) && { IFS=$'\t' read -r id _ <<< "${rows[sel]}"; [[ "$id" == "-" ]] && id=""; }
        case "$KEY" in
            up)   ((sel > 0)) && sel=$((sel - 1)) ;;
            down) ((sel < n - 1)) && sel=$((sel + 1)) ;;
            enter)
                if [[ -n "$id" ]]; then clear; claude attach -- "$id"; next=0
                elif ((n)); then printf '\n%sLive (non-background) sessions run in their own pane; only background ones can be attached.%s\n' $'\e[33m' "$C_RST"; press_any; fi ;;
            l) [[ -n "$id" ]] && { clear; claude logs -- "$id"; press_any; } ;;
            x) [[ -n "$id" ]] && confirm "Stop $id?" && { claude stop -- "$id"; next=0; sleep 0.4; } ;;
            r) next=0 ;;
            o) clear; claude agents --cwd "$path"; next=0 ;;
            q|esc) return ;;
        esac
    done
}

show_codex() {
    local thread msg
    while true; do
        show_panes "codex panes running in tai - $path" "m message a session (codex queue)  o codex agents  q close  (refreshes every 2 s)"
        wait_key 2
        case "$KEY" in
            q|esc) return ;;
            o) clear; codex agents --cd "$path" ;;
            m)
                printf '\nSession id or exact name (blank cancels): '; IFS= read -r thread
                [[ -n "$thread" ]] || continue
                printf 'Message: '; IFS= read -r msg
                [[ -n "$msg" ]] || continue
                codex queue --thread "$thread" --message "$msg"
                press_any ;;
        esac
    done
}

show_other() {
    local hint="q close  (refreshes every 2 s)"
    [[ "$agent" == agy ]] && hint="o agy agent (definitions)  $hint"
    while true; do
        show_panes "$agent sessions running in tai ($agent has no command that lists them)" "$hint"
        wait_key 2
        case "$KEY" in
            q|esc) return ;;
            o) [[ "$agent" == agy ]] && { clear; agy agent; press_any; } ;;
        esac
    done
}

printf '\e[?25l'
trap 'printf "\e[?25h"' EXIT
case "$agent" in
    claude) show_claude ;;
    codex)  show_codex ;;
    *)      show_other ;;
esac
