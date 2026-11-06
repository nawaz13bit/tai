#!/usr/bin/env zsh
# The always-open left pane: project list, live status and usage. Runs inside the tai tmux session.
# Keys: Up/Down (or k/j), Enter open/focus, X close, D remove from list, A add, G change CLI,
#       Shift+Up/Down reorder within a CLI group, F diff in a new window, W new git worktree,
#       T toasts on/off, M then an arrow to move the pane, Q quit tai.
# Colours are plain ANSI 16-colour codes, so the terminal's colour scheme (Neon Retro) drives the look.
# Index convention: zsh arrays are 1-based; `order` holds 1-based indexes into names/paths/agents, `sel` is a position in `order`.
. "${0:A:h}/lib.zsh"

ensure_projects
update_installed
tmux bind-key -n M-d select-window -t "$TMUX_PANE" \; select-pane -t "$TMUX_PANE"   # Alt+D from any pane or the diff window jumps back here

OPEN_FILE="$STATE_DIR/open.json"
C_RST=$'\e[0m' C_DIM=$'\e[90m' C_HEAD=$'\e[96;1m' C_ACC=$'\e[95m' C_OK=$'\e[92m'
C_WORK=$'\e[93m' C_WAIT=$'\e[91;1m' C_IDLE=$'\e[37m' C_START=$'\e[96m' C_SEL=$'\e[7m'

sel=1 top=0 H=40 W=$DASH_COLS FULL=1 NEED_GATHER=0
MSG="CLIs found: ${INSTALLED[*]}"
names=() paths=() agents=() order=() prev=() USAGE=()
typeset -A SKEY P_pid P_since S_model S_eff S_ctx S_cmp S_quota S_act S_upd S_tr S_trm
typeset -A H_st H_upd SUBN SHN G G_t GH P_id NOTIFIED P_ag S_aa CX_MT CX_CTX CX_EFF
now=0 last_ps=0 last_usage=0 ST_STAT=idle

size() {
    local s e=""
    s="$(stty size 2>/dev/null < /dev/tty)" && { H=${s% *}; W=${s#* }; }
    ((H > 0)) || H=40
    ((W > 0)) || W=$DASH_COLS
    SEP=${(l:$W::─:)e}
    FULL=1
}

load() {
    names=() paths=() agents=() order=()
    local n p a ag i
    while IFS=$'\t' read -r n p a; do
        names+=("$n"); paths+=("$p"); agents+=("$a")
        SKEY[$p]="$(state_key "$p")"
    done < <(list_projects)
    for ag in "${AGENTS[@]}"; do   # grouped by CLI, list order kept inside a group
        for ((i = 1; i <= ${#names}; i++)); do
            [[ "${agents[i]/#-/claude}" == "$ag" ]] && order+=("$i")
        done
    done
    ((sel > ${#order})) && sel=${#order}
    ((sel < 1)) && sel=1
}

# --- data gathering (runs about once a second) -----------------------------------------------------

# jq -r <program> over many files. One corrupt file would make jq stop and hide every file after it, so on failure each
# file is tried on its own (the repeated output of the good ones is harmless: the callers overwrite by key).
jq_files() {
    local prog=$1 f; shift
    jq -r "$prog" "$@" 2>/dev/null && return 0
    for f in "$@"; do jq -r "$prog" "$f" 2>/dev/null; done
    return 0
}

gather() {
    now=$EPOCHSECONDS
    local id pid p ag since f d m e c k q ac u t st v aa
    P_pid=() P_since=() P_id=() P_ag=()
    while IFS=$'\t' read -r id pid p ag since; do
        P_pid[$p]=$pid; P_since[$p]=${since:-0}; P_id[$p]=$id; P_ag[$p]=${ag:-claude}
    done < <(tmux list-panes -s -t "$SESSION" -F '#{pane_id}'$'\t''#{pane_pid}'$'\t''#{@tai_path}'$'\t''#{@tai_agent}'$'\t''#{@tai_since}' |
             awk -F'\t' '$3 != ""')

    local -a sf=() hf=()
    SUBN=()
    for p in "${(@k)P_pid}"; do
        [[ -n "${SKEY[$p]:-}" ]] || SKEY[$p]="$(state_key "$p")"
        f="$STATE_DIR/${SKEY[$p]}.json";      [[ -f "$f" ]] && sf+=("$f")
        f="$STATE_DIR/hook_${SKEY[$p]}.json"; [[ -f "$f" ]] && hf+=("$f")
        f="$STATE_DIR/subs_${SKEY[$p]}.txt"
        if [[ -f "$f" ]]; then
            k=0; while IFS= read -r t; do [[ -n "$t" ]] && k=$((k + 1)); done < "$f"
            SUBN[$p]=$k
        fi
        if [[ -f "$STATE_DIR/gh_${SKEY[$p]}.txt" ]]; then read -r v < "$STATE_DIR/gh_${SKEY[$p]}.txt"; GH[$p]=$v; fi
    done

    S_model=() S_eff=() S_ctx=() S_cmp=() S_quota=() S_act=() S_upd=() S_tr=() S_trm=() S_aa=()
    if ((${#sf})); then
        while IFS=$'\t' read -r d m e c k q ac u t aa; do
            S_model[$d]=$m; S_eff[$d]=$e; S_ctx[$d]=$c; S_cmp[$d]=$k; S_quota[$d]=$q
            S_act[$d]=$ac; S_upd[$d]=$u; S_tr[$d]=$t; S_aa[$d]=$aa
        done < <(jq_files '[(.dir // "-"), (.model // "-"), (.effort // "-"),
                         (if .ctx == null then "-" else (.ctx | round | tostring) end),
                         (if .compact == null then "-" else (.compact | round | tostring) end),
                         (if .quota_left == null then "-" else (.quota_left | round | tostring) end),
                         (.activity // "-"), ((.updated_epoch // 0) | tostring), (.transcript // "-"),
                         ((.activity_at_epoch // 0) | tostring)] | @tsv' \
                     "${sf[@]}")
        for p in "${(@k)S_tr}"; do
            [[ "${S_tr[$p]}" != "-" ]] && S_trm[$p]="$(file_mtime "${S_tr[$p]}")"
        done
    fi

    H_st=() H_upd=()
    if ((${#hf})); then
        while IFS=$'\t' read -r d st u; do H_st[$d]=$st; H_upd[$d]=$u; done < <(
            jq_files '[(.dir // "-"), (.status // "-"), ((.updated_epoch // 0) | tostring)] | @tsv' "${hf[@]}")
    fi

    notify_waiting
    ((now - last_ps >= 6)) && snap_shells
    ((now - last_usage >= 10)) && usage_refresh
}

# Toast once per transition of an open project to "waiting" (hook status). The first call only records what is already
# waiting, so starting the dashboard does not announce old prompts. The T key toggles toasts via the toast.off flag file;
# while off, waiting states are still recorded, so turning toasts back on does not announce prompts already waiting.
TOAST_OFF="$STATE_DIR/toast.off"
PREVIEW_ON="$STATE_DIR/preview.on"
notify_seeded=0
notify_waiting() {
    local p since hu stamp
    for p in "${(@k)P_pid}"; do
        since=${P_since[$p]:-0} hu=${H_upd[$p]:-0}
        if [[ "${H_st[$p]:-}" != waiting ]]; then NOTIFIED[$p]=""; continue; fi
        ((hu >= since)) || continue
        stamp=$hu
        [[ "${NOTIFIED[$p]:-}" == "$stamp" ]] && continue
        NOTIFIED[$p]=$stamp
        if ((notify_seeded)) && [[ ! -e "$TOAST_OFF" ]]; then send_toast "${p:t} needs you" "Waiting for input in tai" &! fi
    done
    notify_seeded=1
}

# Shells started by each pane's agent: one process snapshot, counted in awk. Shells whose parent is itself a shell
# (the slot's menu, nested shells) are not counted. Sessions hosted by Claude's background daemon are
# attributed to the pane whose folder contains the session's cwd (longest match). macOS `ps` reports comm as a
# full path (/bin/zsh) or with a leading dash (-zsh), so the path is stripped before matching.
SHELL_AWK='
BEGIN {
    n = split(pids, pa, " "); for (i = 1; i <= n; i++) isroot[pa[i]] = 1
    m = split(sess, sa, " "); for (i = 1; i <= m; i++) { split(sa[i], kv, "="); sessroot[kv[1]] = kv[2] }
}
{
    a = $0; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ */, "", a)
    c0 = $3; sub(/.*\//, "", c0)
    par[$1] = $2; cm[$1] = c0; ar[$1] = a
}
END {
    for (pid in ar) {
        if (ar[pid] ~ /--bg-pty-host/) continue
        if (match(ar[pid], /--session-id [^ ]+/)) {
            sid = substr(ar[pid], RSTART + 13, RLENGTH - 13)
            if (sid in sessroot) host[pid] = sessroot[sid]
        }
    }
    for (pid in ar) {
        if (cm[pid] !~ /^-?(bash|sh|zsh|fish|dash)$/) continue
        if (ar[pid] ~ /statusline\.(zsh|sh)|hook\.(zsh|sh)/) continue
        c = par[pid]
        if (cm[c] ~ /^-?(bash|sh|zsh|fish|dash)$/) continue
        tgt = ""; guard = 0
        while (c != "" && c + 0 > 1 && guard < 64) {
            if (c in host) { tgt = host[c]; break }
            if (c in isroot) { tgt = c; break }
            c = par[c]; guard++
        }
        if (tgt != "") cnt[tgt]++
    }
    for (t in cnt) print t, cnt[t]
}'

snap_shells() {
    last_ps=$now
    local pids="" sess="" sid cwd upd best bl p pid cnt
    local -A who
    for p in "${(@k)P_pid}"; do pids+="${P_pid[$p]} "; who[${P_pid[$p]}]=$p; done
    if [[ -f "$STATE_DIR/sessions.txt" ]]; then
        while IFS=$'\t' read -r sid cwd upd; do
            best="" bl=0
            for p in "${(@k)P_pid}"; do
                if [[ "$cwd" == "$p" || "$cwd" == "$p"/* ]] && ((${#p} > bl)); then best=$p; bl=${#p}; fi
            done
            [[ -n "$best" ]] && sess+="$sid=${P_pid[$best]} "
        done < "$STATE_DIR/sessions.txt"
    fi
    SHN=()
    while read -r pid cnt; do
        [[ -n "${who[$pid]:-}" ]] && SHN[${who[$pid]}]=$cnt
    done < <(ps -ax -o pid=,ppid=,comm=,args= 2>/dev/null | awk -v pids="$pids" -v sess="$sess" "$SHELL_AWK")
}

# Git status of one open project per call, oldest first (each is refreshed at most every 10 s).
git_info() {
    local p=$1 out line br="" ah=0 bh=0 ch=0 wt=0 a b gd gc
    G_t[$p]=$now
    if ! out="$(git --no-optional-locks -C "$p" status --porcelain=v2 --branch 2>/dev/null)"; then G[$p]=""; return; fi
    while IFS= read -r line; do
        case "$line" in
            '# branch.head '*) br=${line#\# branch.head } ;;
            '# branch.ab '*)   read -r _ _ a b <<< "$line"; ah=${a#+}; bh=${b#-} ;;
            '#'*) ;;
            ?*) ch=$((ch + 1)) ;;
        esac
    done <<< "$out"
    gd="$(git -C "$p" rev-parse --git-dir 2>/dev/null)"
    gc="$(git -C "$p" rev-parse --git-common-dir 2>/dev/null)"
    [[ "$gd" != "$gc" ]] && wt=1
    G[$p]="$br|$wt|$ch|$ah|$bh"
}

git_refresh_one() {
    local idx p
    for idx in "${order[@]}"; do
        p=${paths[idx]}
        [[ -n "${P_pid[$p]:-}" ]] || continue
        if ((now - ${G_t[$p]:-0} >= 10)); then git_info "$p"; return; fi
    done
}

# GitHub issue / PR counts, one project at a time every 5 minutes, in the background (needs gh).
gh_poll() {
    command -v gh >/dev/null 2>&1 || return
    local n p i r
    while true; do
        while IFS=$'\t' read -r n p _; do
            git -C "$p" remote -v 2>/dev/null | grep -q github.com || continue
            i="$(cd "$p" && gh issue list --state open --limit 200 --json number --jq length 2>/dev/null)"
            r="$(cd "$p" && gh pr list --state open --limit 200 --json number --jq length 2>/dev/null)"
            if [[ "$i" =~ ^[0-9]+$ && "$r" =~ ^[0-9]+$ ]]; then printf '%s %s\n' "$i" "$r" | write_atomic "$STATE_DIR/gh_$(state_key "$p").txt"; fi
            sleep 2
        done < <(list_projects)
        sleep 300
    done
}

# --- usage bars ----------------------------------------------------------------------------------------

fmt_epoch() { strftime '%a %H:%M' "$1" 2>/dev/null; }

bar_line() {   # label used_percent [reset_text] -> appends one line to USAGE
    local label=${1:0:10} pct=$2 reset=${3:-} w=8 f i col line b=""
    ((pct < 0)) && pct=0
    ((pct > 100)) && pct=100
    f=$(((pct * w + 50) / 100))
    col=$C_OK; ((pct >= 70)) && col=$C_WORK; ((pct >= 90)) && col=$C_WAIT
    for ((i = 0; i < w; i++)); do if ((i < f)); then b+="█"; else b+="░"; fi; done
    line="$(printf '%-5s %s%s%s %3d%%' "$label" "$col" "$b" "$C_RST" "$pct")"
    [[ -n "$reset" ]] && line+="  ↻ $reset"
    USAGE+=("$line")
}

usage_section() {   # name start; lines added since start get a header, only when there are any
    local name=$1 start=$2
    local -a sub
    sub=("${(@)USAGE[$((start + 1)),-1]}")
    ((${#sub})) || return
    USAGE=("${(@)USAGE[1,$start]}" "${C_HEAD}-- $name --${C_RST}" "${sub[@]}")
}

# Which account's usage to show per agent: the highlighted project's account when it uses that agent, else the agent's
# first account. ACC_NAME / ACC_DIR stay empty for an agent without accounts; ACC_TAG is " @name" only when it has several.
typeset -A ACC_NAME ACC_DIR ACC_TAG
pick_accounts() {
    local a i src="" sa="" names
    local -a nl
    ACC_NAME=() ACC_DIR=() ACC_TAG=()
    (( ${#order} )) && sa="${agents[${order[sel]}]/#-/claude}"
    for a in claude codex; do
        names="$(agent_accounts "$a")"
        [[ -n "$names" ]] || continue
        src=""
        if [[ "$sa" == "$a" ]]; then src=${paths[${order[sel]}]}
        else for (( i = 1; i <= ${#paths}; i++ )); do [[ "${agents[i]/#-/claude}" == "$a" ]] && { src=${paths[i]}; break; }; done; fi
        if [[ -n "$src" ]]; then ACC_NAME[$a]="$(project_account "$src" "$a")"; else ACC_NAME[$a]="${names%%$'\n'*}"; fi
        ACC_DIR[$a]="$(account_dir "$a" "${ACC_NAME[$a]}")"
        nl=( ${(f)names} )
        (( ${#nl} > 1 )) && ACC_TAG[$a]=" @${ACC_NAME[$a]}"
    done
}

# Login behind the highlighted project's account (real email/plan, not just the accounts.json label), cached in IDENT.
IDENT="" IDENT_COL=""
ident_update() {
    local c a names acc who mine o
    IDENT="" IDENT_COL=$C_DIM
    (( ${#order} )) || return 0
    c=${order[sel]}; a="${agents[c]/#-/claude}"
    names="$(agent_accounts "$a")"
    [[ -n "$names" ]] || return 0
    acc="$(project_account "${paths[c]}" "$a")"
    who="$(account_identity "$a" "$acc")"
    [[ -n "$who" ]] || return 0
    if [[ "$who" == "not logged in" ]]; then who+=" (the CLI will ask to sign in)"; IDENT_COL=$C_WORK
    elif [[ "$who" != "checking..." ]]; then
        mine="$who"
        for o in ${(f)names}; do   # two accounts of one CLI that are the same login are almost always a setup mistake
            [[ "$o" != "$acc" && "$(account_identity "$a" "$o")" == "$mine" ]] && { who+="  = same as '$o'!"; IDENT_COL=$C_WORK; break; }
        done
    fi
    IDENT="$a @$acc: $who"
}

# Codex has no transcript or status line. For each open Codex project this reads the newest rollout log of the project's
# own account home (the newest 20 files): its last write time (stands in for a transcript, so a 'waiting' hook is
# cleared once Codex resumes), the context used, and the effort from config.toml (top level only). Runs with the usage
# refresh, about every 10 s.
codex_scan() {
    CX_MT=() CX_CTX=() CX_EFF=()
    local p acct dir f cwd line cnt win pct toml re
    local -a fl
    local -A files_of
    re='"total_tokens":([0-9]+)\},"model_context_window":([0-9]+)'
    for p in "${(@k)P_ag}"; do
        [[ "${P_ag[$p]}" == codex ]] || continue
        acct="$(project_account "$p" codex)"; dir=""
        [[ -n "$acct" ]] && dir="$(account_dir codex "$acct")"
        dir="${dir:-$HOME/.codex}"
        toml="$dir/config.toml"
        if [[ -f "$toml" ]]; then
            CX_EFF[$p]="$(sed -n -e '/^[[:space:]]*\[/q' -e 's/^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$toml" | head -n 1)"
        fi
        if (( ! ${+files_of[$dir]} )); then
            fl=( $dir/sessions/**/rollout-*.jsonl(.Nom[1,20]) )
            files_of[$dir]="${(F)fl}"
        fi
        for f in "${(@f)files_of[$dir]}"; do
            [[ -n "$f" ]] || continue
            cwd="$(head -c 3000 "$f" | grep -o '"cwd":"[^"]*"' | head -n 1)"
            cwd="${cwd#\"cwd\":\"}"; cwd="${cwd%\"}"
            [[ "${cwd%/}" == "${p%/}" ]] || continue
            CX_MT[$p]="$(file_mtime "$f")"
            line="$(tail -c 400000 "$f" | grep -o '"last_token_usage":{[^}]*"total_tokens":[0-9]*},"model_context_window":[0-9]*' | tail -n 1)"
            if [[ "$line" =~ $re ]] && (( match[2] > 0 )); then
                cnt=${match[1]} win=${match[2]}
                pct=$(( (100 * cnt + win / 2) / win )); (( pct > 100 )) && pct=100
                CX_CTX[$p]=$pct
            fi
            break   # newest log of this folder wins
        done
    done
}

usage_refresh() {
    last_usage=$now
    USAGE=()
    codex_scan
    local -a u files w q sj lbl
    local pct rs i start f mins k ufile="$USAGE_FILE" cdir="$HOME/.codex"
    pick_accounts
    if [[ -n "${ACC_DIR[claude]:-}" ]] && ! is_default_account_dir claude "${ACC_DIR[claude]}"; then
        ufile="$TAI_CONF/$(usage_name_for_dir "${ACC_DIR[claude]}")"
    fi
    [[ -n "${ACC_DIR[codex]:-}" ]] && cdir="${ACC_DIR[codex]}"
    # Claude: 5h / 7d windows from the status line's rate_limits
    start=${#USAGE}
    if [[ -f "$ufile" ]]; then
        u=( "${(@f)$(jq -r '(.five_hour, .seven_day) | if . == null then "- -" else "\(.used_percentage // 0 | round) \(.resets_at // "-")" end' "$ufile" 2>/dev/null)}" )
        lbl=(5h 7d)
        for i in 1 2; do
            read -r pct rs <<< "${u[i]:-- -}"
            [[ "$pct" =~ ^[0-9]+$ ]] || continue
            if [[ "$rs" =~ ^[0-9]+$ ]]; then
                ((rs < now)) && continue   # window already reset
                bar_line "⏱ ${lbl[i]}" "$pct" "$(fmt_epoch "$rs")"
            else
                bar_line "⏱ ${lbl[i]}" "$pct"
            fi
        done
    fi
    usage_section "claude${ACC_TAG[claude]:-}" "$start"

    # Codex: newest rollout files carry the account's rate limits (windows labelled by length)
    start=${#USAGE}
    if [[ -d "$cdir/sessions" ]]; then
        files=( $cdir/sessions/**/rollout-*.jsonl(.Nom[1,5]) )
        for f in "${files[@]}"; do
            w=( "${(@f)$(tail -c 400000 "$f" 2>/dev/null | grep '"rate_limits"' | tail -n 1 |
                jq -r '(.payload.rate_limits // .rate_limits // empty) | [.primary, .secondary][] | select(. != null) | "\(.used_percent // 0 | round) \(.window_minutes // 0) \(.resets_at // 0)"' 2>/dev/null)}" )
            [[ -n "${w[1]}" ]] || continue
            for k in "${w[@]}"; do
                [[ -n "$k" ]] || continue
                read -r pct mins rs <<< "$k"
                ((rs > 0 && rs < now)) && continue
                if ((mins >= 1440)); then lbl="$((mins / 1440))d"; else lbl="$((mins / 60))h"; fi
                bar_line "⏱ $lbl" "$pct" "$( ((rs > 0)) && fmt_epoch "$rs")"
            done
            break
        done
    fi
    usage_section "codex${ACC_TAG[codex]:-}" "$start"

    # agy: per-model quota left, lowest across the running sessions
    start=${#USAGE}
    sj=( $STATE_DIR/*.json(N) )
    if ((${#sj})); then
        q=( "${(@f)$(jq -rs '[.[] | select(type == "object" and .agent == "agy" and ((now - (.updated_epoch // 0)) < 86400)) | .quotas[]?]
                             | group_by(.name)[] | "\(.[0].name)\t\(map(.left) | min | round)"' "${sj[@]}" 2>/dev/null)}" )
        for k in "${q[@]}"; do
            [[ -n "$k" ]] && bar_line "${k%%$'\t'*}" "$((100 - ${k#*$'\t'}))"
        done
    fi
    usage_section agy "$start"
    ident_update
}

# --- status of one project pane --------------------------------------------------------------------------
# Sets ST_SYM, ST_TXT, ST_COL. Only state written after the pane was opened counts (@tai_since).

age_text() {
    local s=$(($1 > 0 ? $1 : 0))
    if ((s < 60)); then print -r -- "${s}s"; elif ((s < 3600)); then print -r -- "$((s / 60))m"; else print -r -- "$((s / 3600))h"; fi
}

status_info() {
    local p=$1 since=${P_since[$p]:-} upd trm act hs hu sx ref
    ST_STAT=closed
    if [[ -z "$since" ]]; then ST_SYM="·"; ST_TXT=""; ST_COL=$C_DIM; return; fi
    upd=${S_upd[$p]:-0} trm=${S_trm[$p]:-0} act=${S_act[$p]:--} hs=${H_st[$p]:--} hu=${H_upd[$p]:-0}
    local vs=0 vh=0
    ((upd >= since && upd > 0)) && vs=1
    ((hu >= since && hu > 0)) && vh=1
    if ((!vs && !vh)); then ST_SYM="…"; ST_TXT="starting"; ST_COL=$C_START; ST_STAT=idle; return; fi
    sx=idle ref=$upd
    if ((vs)); then
        if ((trm > 0 && now - trm < 20)); then sx=working
        elif ((trm > upd)); then ref=$trm; fi
        # A 'working' report from a non-Claude agent that went quiet for 3 minutes is stale (agy only writes when it
        # redraws), so it counts as idle.
        if [[ "$act" == working && "${P_ag[$p]:-claude}" != claude ]] && ((now - upd > 180)); then act=idle; fi
        case "$act" in
            waiting) sx=waiting ;;
            working) sx=working ;;
            done)    sx=done ref=${S_aa[$p]:-0}; ((ref > 0)) || ref=$upd ;;
            idle)    sx=idle ref=$upd ;;
        esac
    fi
    if ((vh)); then
        # No hook fires when a prompt is answered; a transcript write after it means the agent resumed. Codex has no
        # transcript, so its newest rollout log write plays that part.
        local wm=$trm
        ((wm > 0)) || wm=${CX_MT[$p]:-0}
        case "$hs" in
            waiting) ((wm > hu + 2)) || sx=waiting ;;
            working) sx=working ;;
            done)    if [[ "$sx" != working && "$sx" != waiting ]]; then sx=done ref=$hu; fi ;;
        esac
    fi
    ST_STAT=$sx
    case "$sx" in
        working) ST_SYM="◐"; ST_TXT="working";                       ST_COL=$C_WORK ;;
        waiting) ST_SYM="!"; ST_TXT="! waiting";                     ST_COL=$C_WAIT ;;
        done)    ST_SYM="✓"; ST_TXT="done $(age_text $((now - ref)))"; ST_COL=$C_OK ;;
        *)       ST_SYM="○"; ST_TXT="idle $(age_text $((now - ref)))"; ST_COL=$C_IDLE ;;
    esac
}

pct_col() { local v=$1; if ((v >= 90)); then print -r -- "$C_WAIT"; elif ((v >= 70)); then print -r -- "$C_WORK"; else print -r -- "$C_OK"; fi; }

# --- drawing ----------------------------------------------------------------------------------------------

render() {
    now=$EPOCHSECONDS
    local -a body=() core=() keys=() bot=() frame=()
    local oi idx p ag lastag="" selfirst=0 sellast=0 mark st name max pad sp line t model eff ctx cmp qt sh sb g
    local br wt ch ah bh gi gp pa
    local -A byag
    local -a agord=()
    local n_open=0 n_work=0 n_wait=0 n_idle=0
    for ((oi = 1; oi <= ${#order}; oi++)); do
        idx=${order[oi]}; p=${paths[idx]}; ag=${agents[idx]/#-/claude}
        if [[ "$ag" != "$lastag" ]]; then body+=("${C_HEAD}-- $ag --${C_RST}"); lastag=$ag; fi
        ((oi == sel)) && selfirst=${#body}
        status_info "$p"
        if [[ -n "${P_pid[$p]:-}" ]]; then   # count open agents by state and CLI for the summary line
            n_open=$((n_open + 1))
            case "$ST_STAT" in working) n_work=$((n_work + 1)) ;; waiting) n_wait=$((n_wait + 1)) ;; *) n_idle=$((n_idle + 1)) ;; esac
            pa=${P_ag[$p]:-claude}
            if (( ! ${+byag[$pa]} )); then agord+=("$pa"); byag[$pa]=0; fi
            byag[$pa]=$((byag[$pa] + 1))
        fi
        mark=" "; ((oi == sel)) && mark="▸"
        st=$ST_TXT; name=${names[idx]}
        max=$((W - 5 - ${#st})); ((max < 4)) && max=4
        name=${name:0:$max}
        pad=$((W - 5 - ${#name} - ${#st})); ((pad < 1)) && pad=1
        sp=${(l:$pad:)}
        if ((oi == sel)); then line="${C_SEL}${mark} ${ST_SYM} ${name}${sp}${st}${C_RST}"
        else line="${mark} ${ST_COL}${ST_SYM}${C_RST} ${name}${sp}${ST_COL}${st}${C_RST}"; fi
        body+=("$line")
        if [[ -n "${P_pid[$p]:-}" ]]; then
            model=${S_model[$p]:--}; eff=${S_eff[$p]:--}; ctx=${S_ctx[$p]:--}; cmp=${S_cmp[$p]:--}; qt=${S_quota[$p]:--}
            if [[ "${P_ag[$p]:-claude}" == codex ]]; then   # Codex has no status line: effort from config.toml, ctx from its rollout log
                [[ "$eff" == "-" && -n "${CX_EFF[$p]:-}" ]] && eff=${CX_EFF[$p]}
                [[ "$ctx" == "-" && -n "${CX_CTX[$p]:-}" ]] && ctx=${CX_CTX[$p]}
            fi
            if [[ "$model" != "-" || "$eff" != "-" ]]; then
                t=$model; [[ "$model" == "-" ]] && t="--"
                [[ "$eff" != "-" ]] && t+=" · $eff"
                body+=("    ${C_ACC}${t:0:$((W - 5))}${C_RST}")
            fi
            t=""
            [[ "$ctx" != "-" ]] && t+="ctx $(pct_col "$ctx")${ctx}%${C_RST}"
            [[ "$cmp" != "-" ]] && t+="  compact ~${cmp}%"
            [[ "$qt" != "-" ]] && t+="  quota ${qt}% left"
            [[ -n "$t" ]] && body+=("    $t")
            sh=${SHN[$p]:-0}; sb=${SUBN[$p]:-0}; t=""
            ((sh > 0)) && t+="▶ $sh sh  "
            ((sb > 0)) && t+="◈ $sb"
            [[ -n "$t" ]] && body+=("    ${C_ACC}${t}${C_RST}")
        fi
        if [[ -n "${P_pid[$p]:-}" || $oi -eq $sel ]] && [[ -n "${G[$p]:-}" ]]; then
            IFS='|' read -r br wt ch ah bh <<< "${G[$p]}"
            g="⎇ $br"
            [[ "$wt" == 1 ]] && g+=" └wt"
            ((ch > 0)) && g+=" ●$ch"
            ((ah > 0)) && g+=" ↑$ah"
            ((bh > 0)) && g+=" ↓$bh"
            ((ch == 0 && ah == 0 && bh == 0)) && g+=" ✓"
            if [[ -n "${GH[$p]:-}" ]]; then read -r gi gp <<< "${GH[$p]}"; g+=" · ${gi}i ${gp}pr"; fi
            body+=("    ${C_DIM}${g:0:$((W - 5))}${C_RST}")
        fi
        ((oi == sel)) && sellast=$((${#body} - 1))
    done

    # Bottom block, pinned: separator, selected path, hint, message, usage, keys.
    local selp="" hint="Enter open  D remove" selpath=""
    if ((${#order})); then
        selpath=${paths[${order[sel]}]}
        selp=$selpath
        [[ -n "${P_pid[$selpath]:-}" ]] && hint="Enter focus  X close"
    fi
    ((${#selp} > W - 2)) && selp="…${selp: -$((W - 3))}"
    core+=("${C_DIM}${SEP}${C_RST}" "${C_DIM}${selp}${C_RST}" "${C_DIM}${hint}${C_RST}")
    [[ -n "$IDENT" ]] && core+=("${IDENT_COL}${IDENT:0:$((W - 1))}${C_RST}")   # who the selected project's account is logged in as
    core+=("${C_WORK}${MSG:0:$((W - 1))}${C_RST}")
    # V: the last lines of the selected pane's screen (tmux capture-pane), any CLI.
    if [[ -e "$PREVIEW_ON" && -n "$selpath" ]]; then
        local pid_=${P_id[$selpath]:-} pl
        if [[ -z "$pid_" ]]; then core+=("${C_DIM}-- preview: not open --${C_RST}")
        else
            core+=("${C_HEAD}-- screen --${C_RST}")
            while IFS= read -r pl; do core+=("  ${C_DIM}${pl:0:$((W - 3))}${C_RST}"); done < <(
                tmux capture-pane -p -J -t "$pid_" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -4)
        fi
    fi
    keys+=("${C_HEAD}-- keys --${C_RST}"
           "${C_DIM}↑↓ select  ⏎ open  X close${C_RST}"
           "${C_DIM} D remove  A add  G cli${C_RST}"
           "${C_DIM}⇧↑↓ reorder  F diff  V view${C_RST}"
           "${C_DIM} P push/PR  W tree  S agents  / find${C_RST}"
           "${C_DIM} T toasts  U account  H hooks  M+arrow move  Q quit${C_RST}"
           "${C_DIM}◐ work  ! wait  ✓ done  ○ idle${C_RST}"
           "${C_DIM}▶ shells  ◈ sub-agents  Alt+D${C_RST}")
    local room=$((H - 6))
    local -a use=("${USAGE[@]}")
    if ((n_open)); then   # one-line summary of all open agents
        local per="" a_ ac_=$C_DIM sum
        for a_ in "${agord[@]}"; do per+="${per:+, }${byag[$a_]} $a_"; done
        ((n_work)) && ac_=$C_WORK
        ((n_wait)) && ac_=$C_WAIT
        sum="agents: $n_open open ($per) - $n_work working, $n_wait waiting, $n_idle idle"
        use+=("${ac_}${sum:0:$((W - 1))}${C_RST}")
    fi
    if ((${#core} + ${#use} + ${#keys} > room)); then keys=(); fi
    if ((${#core} + ${#use} > room)); then use=(); fi
    bot=("${core[@]}")
    ((${#use})) && bot+=("${use[@]}")
    ((${#keys})) && bot+=("${keys[@]}")

    local nb=${#bot}
    local rh=$((H - 2 - nb)) total=${#body}
    ((rh < 1)) && rh=1
    ((sellast >= top + rh)) && top=$((sellast - rh + 1))
    ((selfirst < top)) && top=$selfirst
    ((top > total - rh)) && top=$((total - rh))
    ((top < 0)) && top=0

    local r
    for ((r = 1; r <= H; r++)); do frame[r]=""; done
    frame[1]="${C_HEAD} tai ${C_RST}${C_DIM}${#P_pid} open${C_RST}"
    for ((r = 1; r <= rh; r++)); do frame[$((r + 2))]="${body[top + r]:-}"; done
    for ((r = 1; r <= nb; r++)); do frame[$((H - nb + r))]="${bot[r]}"; done

    local out="" first_bot=$((H - nb + 1))
    if ((FULL)); then out=$'\e[2J'; prev=(); FULL=0; fi
    for ((r = 1; r <= H; r++)); do
        line="${frame[r]}"
        if [[ "$line" != "${prev[r]-}" || $r -ge $first_bot ]]; then
            out+=$'\e['$r';1H'"$line"$'\e[K'
            prev[r]=$line
        fi
    done
    printf '%s' "$out"
}

# One-key y/N question on the message line.
confirm() {
    MSG="$1 (y/N)"; render
    local k; read -rs -k 1 k
    [[ "$k" == [yY] ]]
}

choose_agent() {   # prints the chosen CLI (empty if cancelled)
    if ((${#INSTALLED} == 1)); then print -r -- "${INSTALLED[1]}"; return; fi
    local line="" i k
    for ((i = 1; i <= ${#INSTALLED}; i++)); do line+="$i=${INSTALLED[i]} "; done
    MSG="CLI: $line"; render >&2
    read -rs -k 1 k
    if [[ "$k" == [1-9] ]] && ((k <= ${#INSTALLED})); then print -r -- "${INSTALLED[k]}"; fi
}

add_flow() {
    local dir=""
    printf '\e[H\e[2J\e[?25h\e[1mAdd project\e[0m\n'
    if zmodload zsh/zle 2>/dev/null; then vared -p 'Folder path: ' dir || dir=""
    else read -r "dir?Folder path: "; fi
    printf '\e[?25l'
    FULL=1
    dir="${dir/#\~/$HOME}"
    [[ -z "$dir" ]] && { MSG="Add cancelled"; return; }
    if [[ ! -d "$dir" ]]; then
        if confirm "Create $dir?"; then mkdir -p "$dir" || { MSG="Could not create folder"; return; }
        else MSG="Add cancelled"; return; fi
    fi
    dir="$(cd "$dir" && pwd)"
    add_project "$dir" || return
    load
    MSG="Added ${dir:t}"
}

# P: commit everything, push the branch, optionally open a PR with gh (--fill). Prompts on the full screen.
publish_flow() {   # name dir
    local name=$1 dir=$2 br ch msg out ans
    export GIT_TERMINAL_PROMPT=0   # a missing credential fails instead of hanging the dashboard
    printf '\e[H\e[2J\e[?25h'
    if ! br="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>&1)"; then MSG="$name is not a git repository"; return; fi
    printf '\e[1m%s\e[0m on branch %s\n' "$name" "$br"
    ch="$(git -C "$dir" status --porcelain)"
    [[ -n "$ch" ]] && printf '%s\n' "$ch" | head -15 | sed 's/^/  /'
    if [[ "$br" == main || "$br" == master ]]; then
        read -r "ans?You are on '$br'. Continue (y/N) "; [[ "$ans" == [yY]* ]] || { MSG="Cancelled"; return; }
    fi
    if [[ -n "$ch" ]]; then
        read -r "msg?Commit message (blank cancels): "
        [[ -n "$msg" ]] || { MSG="Cancelled"; return; }
        git -C "$dir" add -A
        if ! out="$(git -C "$dir" commit -m "$msg" 2>&1)"; then MSG="${out##*$'\n'}"; return; fi
        printf 'Committed.\n'
    else
        read -r "ans?Nothing to commit. Push anyway (y/N) "; [[ "$ans" == [yY]* ]] || { MSG="Nothing to commit"; return; }
    fi
    if ! out="$(git -C "$dir" push -u origin HEAD 2>&1)"; then
        printf '%s\n' "$out" | tail -6 | sed 's/^/  /'
        read -r "ans?Push failed. Enter to return"; MSG="Push failed"; return
    fi
    printf '%s\n' "$out" | tail -6 | sed 's/^/  /'
    MSG="Pushed $br"
    if command -v gh >/dev/null && [[ "$br" != main && "$br" != master ]]; then
        read -r "ans?Open a pull request (y/N) "
        if [[ "$ans" == [yY]* ]]; then
            if out="$(cd "$dir" && gh pr create --fill 2>&1)"; then MSG="PR opened: ${out##*$'\n'}"
            else MSG="Pushed $br; gh pr create failed"; fi
            printf '%s\n' "$out" | tail -4 | sed 's/^/  /'
        fi
    fi
    read -r "ans?Enter to return"
}

# /: incremental find. Typing moves the highlight to the first project whose name contains the text; Tab / Down go
# to the next match, Up to the previous, Enter keeps the spot, Esc goes back. Nothing is hidden or saved.
find_match() {   # from(1-based) step -> position of the next match (uses q), or nothing
    local from=$1 step=$2 i j n=${#order}
    for ((i = 0; i < n; i++)); do
        j=$(( ((from - 1 + i * step) % n + n) % n + 1 ))
        [[ "${(L)names[${order[j]}]}" == *"${(L)q}"* ]] && { print -r -- "$j"; return; }
    done
}

find_flow() {
    local n=${#order} start=$sel q="" m
    ((n > 1)) || return
    while true; do
        MSG="/$q   Enter keep, Esc cancel, Tab next"
        render
        read_key || continue
        case "$KEY" in
            enter) MSG=""; return ;;
            other) sel=$start; MSG=""; return ;;
            $'\x7f'|$'\b') q=${q%?}; m="$(find_match "$start" 1)"; sel=${m:-$start} ;;
            $'\t'|down) if [[ -n "$q" ]]; then m="$(find_match $((sel + 1)) 1)"; [[ -n "$m" ]] && sel=$m; fi ;;
            up) if [[ -n "$q" ]]; then m="$(find_match $((sel - 1)) -1)"; [[ -n "$m" ]] && sel=$m; fi ;;
            *) if ((${#KEY} == 1)); then q+=$KEY; m="$(find_match "$start" 1)"; sel=${m:-$start}; fi ;;
        esac
    done
}

# Reads a key into KEY; returns 1 on the 1 s timeout so the list can refresh.
read_key() {
    local k rest=""
    read -rs -k 1 -t 1 k || return 1
    if [[ "$k" == $'\e' ]]; then
        read -rs -k 2 -t 0.05 rest
        case "$rest" in
            '[A'|'OA') KEY=up ;; '[B'|'OB') KEY=down ;; '[C'|'OC') KEY=right ;; '[D'|'OD') KEY=left ;;
            '[1') rest=""; read -rs -k 3 -t 0.05 rest   # modified arrows: ESC [ 1 ; 2 A is Shift+Up
                  case "$rest" in ';2A') KEY=sup ;; ';2B') KEY=sdown ;; *) KEY=other ;; esac ;;
            *) KEY=other ;;
        esac
    elif [[ "$k" == $'\n' || "$k" == $'\r' ]]; then KEY=enter
    else KEY="$k"; fi
}

# --- session restore: the open projects come back after a restart ----------------------------------------

restored=0 last_sig="" sig_since=0 saved_sig=""

open_sig() {   # open project paths in list order, one per line
    local idx
    for idx in "${order[@]}"; do [[ -n "${P_pid[${paths[idx]}]:-}" ]] && printf '%s\n' "${paths[idx]}"; done
}

restore_session() {
    restored=1
    ((${#P_pid})) && return
    [[ -f "$OPEN_FILE" ]] || return
    local p i
    while IFS= read -r p; do
        for ((i = 1; i <= ${#paths}; i++)); do
            [[ "${paths[i]}" == "$p" ]] && { open_project "${names[i]}" "$p" "${agents[i]}" nofocus; break; }
        done
    done < <(jq -r '.[]' "$OPEN_FILE" 2>/dev/null)
    tmux select-pane -t "$TMUX_PANE"
}

save_open() {   # stable for 4 s -> write open.json
    ((restored)) || return
    local sig
    local -a arr
    sig="$(open_sig)"
    if [[ "$sig" != "$last_sig" ]]; then last_sig=$sig; sig_since=$now; return; fi
    [[ "$sig" == "$saved_sig" ]] && return
    ((now - sig_since >= 4)) || return
    saved_sig=$sig
    if [[ -n "$sig" ]]; then
        arr=( "${(@f)sig}" )
        jq -n '$ARGS.positional' --args "${arr[@]}" | write_atomic "$OPEN_FILE"
    else
        print -r -- '[]' | write_atomic "$OPEN_FILE"
    fi
}

# --- main -------------------------------------------------------------------------------------------------

gh_poll & GH_PID=$!
cleanup() { kill "$GH_PID" 2>/dev/null; printf '\e[?25h'; }
trap cleanup EXIT
trap 'cleanup; exit 0' HUP TERM
TRAPWINCH() { size }
printf '\e[?25l'
size
load
gather
restore_session
gather
usage_refresh
if [[ -n "$(hooks_pending)" ]]; then MSG="Press H to install status hooks for: $(hooks_pending | tr '\n' ' ')"; fi

last_sig=""
while true; do
    # The usage bars and login line follow the highlighted project's account, so refresh them when the highlight moves.
    sig="${order[sel]:-}|${paths[${order[sel]:-0}]:-}|${agents[${order[sel]:-0}]:-}"
    if [[ "$sig" != "$last_sig" ]]; then [[ -n "$last_sig" ]] && usage_refresh; last_sig="$sig"; fi
    render
    if read_key; then
        n=${#order}
        cur=0; ((n)) && cur=${order[sel]}
        case "$KEY" in
            up|k)   ((n)) && sel=$(((sel + n - 2) % n + 1)) ;;
            down|j) ((n)) && sel=$((sel % n + 1)) ;;
            sup|sdown)   # reorder within the CLI group; the highlight follows the project
                ((n)) || continue
                if [[ "$KEY" == sup ]]; then to=$((sel - 1)); else to=$((sel + 1)); fi
                if ((to < 1 || to > n)); then continue; fi
                nbr=${order[to]}
                if [[ "${agents[cur]/#-/claude}" != "${agents[nbr]/#-/claude}" ]]; then MSG="Different CLI group"; continue; fi
                swap_projects "${paths[cur]}" "${paths[nbr]}" && sel=$to
                load ;;
            f|F)
                ((n)) || continue
                cmd="git -C ${(q)paths[cur]} -c color.ui=always -c core.pager='less -R' diff HEAD --stat --patch || { echo 'git diff failed (not a repo?)'; sleep 2; }"
                tmux new-window -n "diff ${names[cur]}" -c "${paths[cur]}" "$cmd"
                MSG="Diff of ${names[cur]} opened in a new window (q closes it)" ;;
            s|S)   # agents screen of the selected project, in its own tmux window, on the project's account
                ((n)) || continue
                a="${agents[cur]/#-/claude}"
                acct_s="$(project_account "${paths[cur]}" "$a")"
                cmd="${(q)TAI_DIR}/agentsview.zsh ${(q)paths[cur]} ${(q)a} ${(q)acct_s}"
                tmux new-window -n "agents ${names[cur]}" -c "${paths[cur]}" "$cmd"
                MSG="Agents of ${names[cur]} opened in a new window (q closes it)" ;;
            p|P)
                ((n)) || continue
                publish_flow "${names[cur]}" "${paths[cur]}"
                printf '\e[?25l'; FULL=1 ;;
            r|R)   # tmux layout is always live; this just forces a fresh scan of panes, state and usage
                load; gather; usage_refresh; FULL=1; MSG="Refreshed" ;;
            h|H)
                printf '\e[H\e[2J\e[?25h\e[1mInstall tai status hooks\e[0m\n'
                pend=( ${(f)"$(hooks_pending)"} )
                (( ${#pend} )) || pend=("${HOOK_AGENTS[@]}")   # nothing new: offer every target again
                install_agent_hooks "${pend[@]}"
                printf '\e[?25l'; FULL=1 ;;
            v|V)
                if [[ -e "$PREVIEW_ON" ]]; then rm -f "$PREVIEW_ON"; MSG="Preview off"
                else : > "$PREVIEW_ON"; MSG="Preview on"; fi ;;
            /)  find_flow ;;
            t|T)
                if [[ -e "$TOAST_OFF" ]]; then rm -f "$TOAST_OFF"; MSG="Toasts on"
                else : > "$TOAST_OFF"; MSG="Toasts off"; fi ;;
            w|W)
                ((n)) || continue
                printf '\e[H\e[2J\e[?25h\e[1mNew worktree of %s\e[0m\n' "${names[cur]}"
                br=""
                if zmodload zsh/zle 2>/dev/null; then vared -p 'New branch (blank cancels): ' br || br=""
                else read -r "br?New branch (blank cancels): "; fi
                printf '\e[?25l'; FULL=1
                [[ -z "$br" ]] && { MSG="Worktree cancelled"; continue; }
                safe="${br//[^A-Za-z0-9._-]/-}"
                wdir="${paths[cur]%/}-$safe"
                if out="$(git -C "${paths[cur]}" worktree add -b "$br" "$wdir" 2>&1)"; then
                    if add_project "$wdir"; then
                        load; MSG="Worktree $safe added"
                        for ((oi = 1; oi <= ${#order}; oi++)); do [[ "${paths[${order[oi]}]}" == "$wdir" ]] && sel=$oi; done
                    fi
                else MSG="${out##*$'\n'}"; fi ;;
            enter)
                ((n)) || continue
                if [[ -z "$(pane_for_path "${paths[cur]}")" && "${agents[cur]}" == "-" ]]; then
                    a="$(choose_agent)"
                    if [[ -z "$a" ]]; then MSG="Cancelled"; continue; fi
                    set_agent "${paths[cur]}" "$a"; agents[cur]="$a"; load
                fi
                open_project "${names[cur]}" "${paths[cur]}" "${agents[cur]}"; NEED_GATHER=1 ;;
            x|X)    ((n)) && { close_project "${names[cur]}" "${paths[cur]}"; NEED_GATHER=1; } ;;
            d|D)
                ((n)) || continue
                if [[ -n "$(pane_for_path "${paths[cur]}")" ]]; then MSG="Close it first (X)"
                elif confirm "Remove ${names[cur]} from the list?"; then
                    remove_project "${paths[cur]}"; load; MSG="Removed"
                else MSG="Kept"; fi ;;
            a|A)    add_flow ;;
            g|G)
                ((n)) || continue
                if [[ -n "$(pane_for_path "${paths[cur]}")" ]]; then MSG="Close it first (X), then change the CLI"
                else
                    a="$(choose_agent)"
                    if [[ -n "$a" ]]; then set_agent "${paths[cur]}" "$a"; MSG="${names[cur]} -> $a"; load
                    else MSG="Cancelled"; fi
                fi ;;
            u|U)
                ((n)) || continue
                a="${agents[cur]/#-/claude}"
                accts=( ${(f)"$(agent_accounts "$a")"} )
                if [[ -n "$(pane_for_path "${paths[cur]}")" ]]; then MSG="Close ${names[cur]} first (X) to change its account"
                elif ((${#accts} < 2)); then MSG="No accounts for $a in accounts.json (see accounts.example.json)"
                else
                    cura="$(project_account "${paths[cur]}" "$a")"; nexta="${accts[1]}"
                    for ((ai = 1; ai <= ${#accts}; ai++)); do
                        [[ "${accts[ai]}" == "$cura" ]] && nexta="${accts[ai % ${#accts} + 1]}"
                    done
                    set_project_account "${paths[cur]}" "$a" "$nexta"
                    usage_refresh
                    MSG="${names[cur]} will use $a account '$nexta'"
                fi ;;
            m|M)
                ((n)) || continue
                if [[ -z "$(pane_for_path "${paths[cur]}")" ]]; then MSG="Open it first (Enter)"; continue; fi
                MSG="Move ${names[cur]}: arrow keys, other = cancel"; render
                while ! read_key; do :; done
                case "$KEY" in
                    up|k)    move_project "${paths[cur]}" up ;;
                    down|j)  move_project "${paths[cur]}" down ;;
                    left|h)  move_project "${paths[cur]}" left ;;
                    right|l) move_project "${paths[cur]}" right ;;
                    *)       MSG="Move cancelled" ;;
                esac
                tmux select-pane -t "$TMUX_PANE"; NEED_GATHER=1 ;;
            q|Q)    confirm "Quit tai and stop every session?" && tmux kill-session -t "$SESSION" ;;
        esac
        ((NEED_GATHER)) && { NEED_GATHER=0; gather; }
    else
        gather
        git_refresh_one
        save_open
    fi
done
