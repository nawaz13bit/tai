#!/usr/bin/env bash
# The always-open left pane: project list, live status and usage. Runs inside the tai tmux session.
# Keys: Up/Down (or k/j), Enter open/focus, X close, D remove from list, A add, G change CLI,
#       Shift+Up/Down reorder within a CLI group, F diff in a new window, W new git worktree,
#       T toasts on/off, M then an arrow to move the pane, Q quit tai.
# Colours are plain ANSI 16-colour codes, so the terminal's colour scheme (Neon Retro) drives the look.
. "$(dirname "$(readlink -f "$0")")/lib.sh"

ensure_projects
update_installed
tmux bind-key -n M-d select-window -t "$TMUX_PANE" \; select-pane -t "$TMUX_PANE"   # Alt+D from any pane or the diff window jumps back here

OPEN_FILE="$STATE_DIR/open.json"
C_RST=$'\e[0m' C_DIM=$'\e[90m' C_HEAD=$'\e[96;1m' C_ACC=$'\e[95m' C_OK=$'\e[92m'
C_WORK=$'\e[93m' C_WAIT=$'\e[91;1m' C_IDLE=$'\e[37m' C_START=$'\e[96m' C_SEL=$'\e[7m'

sel=0 top=0 H=40 W=$DASH_COLS FULL=1 NEED_GATHER=0
MSG="CLIs found: ${INSTALLED[*]}"
names=() paths=() agents=() order=() prev=() USAGE=()
declare -A SKEY P_pid P_since S_model S_eff S_ctx S_cmp S_quota S_act S_upd S_tr S_trm
declare -A H_st H_upd SUBN SHN G G_t GH
now=0 last_ps=0 last_usage=0

size() {
    local s
    s="$(stty size 2>/dev/null < /dev/tty)" && { H=${s% *}; W=${s#* }; }
    ((H > 0)) || H=40
    ((W > 0)) || W=$DASH_COLS
    printf -v SEP '%*s' "$W" ''
    SEP=${SEP// /─}
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
        for i in "${!names[@]}"; do
            [[ "${agents[i]/#-/claude}" == "$ag" ]] && order+=("$i")
        done
    done
    ((sel >= ${#order[@]})) && sel=$((${#order[@]} - 1))
    ((sel < 0)) && sel=0
}

# --- data gathering (runs about once a second) -----------------------------------------------------

gather() {
    printf -v now '%(%s)T' -1
    local id pid p ag since f d m e c k q ac u t st
    P_pid=() P_since=()
    while IFS=$'\t' read -r id pid p ag since; do
        P_pid[$p]=$pid; P_since[$p]=${since:-0}
    done < <(tmux list-panes -s -t "$SESSION" -F '#{pane_id}'$'\t''#{pane_pid}'$'\t''#{@tai_path}'$'\t''#{@tai_agent}'$'\t''#{@tai_since}' |
             awk -F'\t' '$3 != ""')

    local -a sf=() hf=()
    SUBN=()
    for p in "${!P_pid[@]}"; do
        [[ -n "${SKEY[$p]:-}" ]] || SKEY[$p]="$(state_key "$p")"
        f="$STATE_DIR/${SKEY[$p]}.json";      [[ -f "$f" ]] && sf+=("$f")
        f="$STATE_DIR/hook_${SKEY[$p]}.json"; [[ -f "$f" ]] && hf+=("$f")
        f="$STATE_DIR/subs_${SKEY[$p]}.txt"
        if [[ -f "$f" ]]; then
            k=0; while IFS= read -r t; do [[ -n "$t" ]] && k=$((k + 1)); done < "$f"
            SUBN[$p]=$k
        fi
        if [[ -f "$STATE_DIR/gh_${SKEY[$p]}.txt" ]]; then read -r GH[$p] < "$STATE_DIR/gh_${SKEY[$p]}.txt"; fi
    done

    S_model=() S_eff=() S_ctx=() S_cmp=() S_quota=() S_act=() S_upd=() S_tr=() S_trm=()
    if ((${#sf[@]})); then
        while IFS=$'\t' read -r d m e c k q ac u t; do
            S_model[$d]=$m; S_eff[$d]=$e; S_ctx[$d]=$c; S_cmp[$d]=$k; S_quota[$d]=$q
            S_act[$d]=$ac; S_upd[$d]=$u; S_tr[$d]=$t
        done < <(jq -r '[(.dir // "-"), (.model // "-"), (.effort // "-"),
                         (if .ctx == null then "-" else (.ctx | round | tostring) end),
                         (if .compact == null then "-" else (.compact | round | tostring) end),
                         (if .quota_left == null then "-" else (.quota_left | round | tostring) end),
                         (.activity // "-"), ((.updated_epoch // 0) | tostring), (.transcript // "-")] | @tsv' \
                     "${sf[@]}" 2>/dev/null)
        for p in "${!S_tr[@]}"; do
            [[ "${S_tr[$p]}" != "-" ]] && S_trm[$p]="$(file_mtime "${S_tr[$p]}")"
        done
    fi

    H_st=() H_upd=()
    if ((${#hf[@]})); then
        while IFS=$'\t' read -r d st u; do H_st[$d]=$st; H_upd[$d]=$u; done < <(
            jq -r '[(.dir // "-"), (.status // "-"), ((.updated_epoch // 0) | tostring)] | @tsv' "${hf[@]}" 2>/dev/null)
    fi

    notify_waiting
    ((now - last_ps >= 6)) && snap_shells
    ((now - last_usage >= 10)) && usage_refresh
}

# Toast once per transition of an open project to "waiting" (hook status). The first call only records what is already
# waiting, so starting the dashboard does not announce old prompts. The T key toggles toasts via the toast.off flag file;
# while off, waiting states are still recorded, so turning toasts back on does not announce prompts already waiting.
TOAST_OFF="$STATE_DIR/toast.off"
declare -A NOTIFIED
notify_seeded=0
notify_waiting() {
    local p since hu stamp
    for p in "${!P_pid[@]}"; do
        since=${P_since[$p]:-0} hu=${H_upd[$p]:-0}
        if [[ "${H_st[$p]:-}" != waiting ]]; then unset 'NOTIFIED[$p]'; continue; fi
        ((hu >= since)) || continue
        stamp=$hu
        [[ "${NOTIFIED[$p]:-}" == "$stamp" ]] && continue
        NOTIFIED[$p]=$stamp
        if ((notify_seeded)) && [[ ! -e "$TOAST_OFF" ]]; then send_toast "$(basename "$p") needs you" "Waiting for input in tai" & fi
    done
    notify_seeded=1
}

# Shells started by each pane's agent: one process snapshot, counted in awk. Shells whose parent is itself a shell
# (the slot's menu subshell, nested shells) are not counted. Sessions hosted by Claude's background daemon are
# attributed to the pane whose folder contains the session's cwd (longest match).
SHELL_AWK='
BEGIN {
    n = split(pids, pa, " "); for (i = 1; i <= n; i++) isroot[pa[i]] = 1
    m = split(sess, sa, " "); for (i = 1; i <= m; i++) { split(sa[i], kv, "="); sessroot[kv[1]] = kv[2] }
}
{
    a = $0; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ */, "", a)
    par[$1] = $2; cm[$1] = $3; ar[$1] = a
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
        if (ar[pid] ~ /statusline\.sh|hook\.sh/) continue
        c = par[pid]
        if (cm[c] ~ /^-?(bash|sh|zsh|fish|dash)$/) continue
        tgt = ""; guard = 0
        while (c != "" && c > 1 && guard < 64) {
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
    declare -A who=()
    for p in "${!P_pid[@]}"; do pids+="${P_pid[$p]} "; who[${P_pid[$p]}]=$p; done
    if [[ -f "$STATE_DIR/sessions.txt" ]]; then
        while IFS=$'\t' read -r sid cwd upd; do
            best="" bl=0
            for p in "${!P_pid[@]}"; do
                if [[ "$cwd" == "$p" || "$cwd" == "$p"/* ]] && ((${#p} > bl)); then best=$p; bl=${#p}; fi
            done
            [[ -n "$best" ]] && sess+="$sid=${P_pid[$best]} "
        done < "$STATE_DIR/sessions.txt"
    fi
    SHN=()
    while read -r pid cnt; do
        [[ -n "${who[$pid]:-}" ]] && SHN[${who[$pid]}]=$cnt
    done < <(ps -e -o pid=,ppid=,comm=,args= 2>/dev/null | awk -v pids="$pids" -v sess="$sess" "$SHELL_AWK")
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
            [[ "$i" =~ ^[0-9]+$ && "$r" =~ ^[0-9]+$ ]] && printf '%s %s\n' "$i" "$r" | write_atomic "$STATE_DIR/gh_$(state_key "$p").txt"
            sleep 2
        done < <(list_projects)
        sleep 300
    done
}

# --- usage bars ----------------------------------------------------------------------------------------

fmt_epoch() { date -d "@$1" '+%a %H:%M' 2>/dev/null || date -r "$1" '+%a %H:%M' 2>/dev/null; }

bar_line() {   # label used_percent [reset_text] -> appends one line to USAGE
    local label=${1:0:10} pct=$2 reset=${3:-} w=8 f i col line b=""
    ((pct < 0)) && pct=0; ((pct > 100)) && pct=100
    f=$(((pct * w + 50) / 100))
    col=$C_OK; ((pct >= 70)) && col=$C_WORK; ((pct >= 90)) && col=$C_WAIT
    for ((i = 0; i < w; i++)); do if ((i < f)); then b+="█"; else b+="░"; fi; done
    printf -v line '%-5s %s%s%s %3d%%' "$label" "$col" "$b" "$C_RST" "$pct"
    [[ -n "$reset" ]] && line+="  ↻ $reset"
    USAGE+=("$line")
}

usage_section() {   # name; lines go to USAGE, a header only when there are any
    local name=$1 sub=("${USAGE[@]:$2}")
    ((${#sub[@]})) || return
    USAGE=("${USAGE[@]:0:$2}" "$C_HEAD-- $name --$C_RST" "${sub[@]}")
}

usage_refresh() {
    last_usage=$now
    USAGE=()
    local u=() pct rs lbl i start f w mins k files=() q
    # Claude: 5h / 7d windows from the status line's rate_limits
    start=${#USAGE[@]}
    if [[ -f "$USAGE_FILE" ]]; then
        mapfile -t u < <(jq -r '(.five_hour, .seven_day) | if . == null then "- -" else "\(.used_percentage // 0 | round) \(.resets_at // "-")" end' "$USAGE_FILE" 2>/dev/null)
        lbl=(5h 7d)
        for i in 0 1; do
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
    usage_section claude "$start"

    # Codex: newest rollout files carry the account's rate limits (windows labelled by length)
    start=${#USAGE[@]}
    if [[ -d "$HOME/.codex/sessions" ]]; then
        mapfile -t files < <(find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -print0 2>/dev/null | xargs -r -0 ls -t 2>/dev/null | head -n 5)
        for f in "${files[@]}"; do
            mapfile -t w < <(tail -c 400000 "$f" 2>/dev/null | grep '"rate_limits"' | tail -n 1 |
                jq -r '(.payload.rate_limits // .rate_limits // empty) | [.primary, .secondary][] | select(. != null) | "\(.used_percent // 0 | round) \(.window_minutes // 0) \(.resets_at // 0)"' 2>/dev/null)
            ((${#w[@]})) || continue
            for k in "${w[@]}"; do
                read -r pct mins rs <<< "$k"
                ((rs > 0 && rs < now)) && continue
                if ((mins >= 1440)); then lbl="$((mins / 1440))d"; else lbl="$((mins / 60))h"; fi
                bar_line "⏱ $lbl" "$pct" "$( ((rs > 0)) && fmt_epoch "$rs")"
            done
            break
        done
    fi
    usage_section codex "$start"

    # agy: per-model quota left, lowest across the running sessions
    start=${#USAGE[@]}
    mapfile -t q < <(jq -rs '[.[] | select(.agent == "agy" and ((now - (.updated_epoch // 0)) < 86400)) | .quotas[]?]
                             | group_by(.name)[] | "\(.[0].name)\t\(map(.left) | min | round)"' "$STATE_DIR"/*.json 2>/dev/null)
    for k in "${q[@]}"; do
        [[ -n "$k" ]] && bar_line "${k%%$'\t'*}" "$((100 - ${k#*$'\t'}))"
    done
    usage_section agy "$start"
}

# --- status of one project pane --------------------------------------------------------------------------
# Sets ST_SYM, ST_TXT, ST_COL. Only state written after the pane was opened counts (@tai_since).

age_text() {
    local s=$(($1 > 0 ? $1 : 0))
    if ((s < 60)); then echo "${s}s"; elif ((s < 3600)); then echo "$((s / 60))m"; else echo "$((s / 3600))h"; fi
}

status_info() {
    local p=$1 since=${P_since[$p]:-} upd trm act hs hu stat ref
    if [[ -z "$since" ]]; then ST_SYM="·"; ST_TXT=""; ST_COL=$C_DIM; return; fi
    upd=${S_upd[$p]:-0} trm=${S_trm[$p]:-0} act=${S_act[$p]:--} hs=${H_st[$p]:--} hu=${H_upd[$p]:-0}
    local vs=0 vh=0
    ((upd >= since && upd > 0)) && vs=1
    ((hu >= since && hu > 0)) && vh=1
    if ((!vs && !vh)); then ST_SYM="…"; ST_TXT="starting"; ST_COL=$C_START; return; fi
    stat=idle ref=$upd
    if ((vs)); then
        if ((trm > 0 && now - trm < 20)); then stat=working
        else ((trm > upd)) && ref=$trm; fi
        case "$act" in
            waiting) stat=waiting ;;
            working) stat=working ;;
            idle)    stat=idle ref=$upd ;;
        esac
    fi
    if ((vh)); then
        case "$hs" in
            waiting) ((trm > hu + 2)) || stat=waiting ;;   # the transcript moved on: it was answered
            working) stat=working ;;
            done)    if [[ "$stat" != working && "$stat" != waiting ]]; then stat=done ref=$hu; fi ;;
        esac
    fi
    case "$stat" in
        working) ST_SYM="◐"; ST_TXT="working";                    ST_COL=$C_WORK ;;
        waiting) ST_SYM="!"; ST_TXT="! waiting";                  ST_COL=$C_WAIT ;;
        done)    ST_SYM="✓"; ST_TXT="done $(age_text $((now - ref)))"; ST_COL=$C_OK ;;
        *)       ST_SYM="○"; ST_TXT="idle $(age_text $((now - ref)))"; ST_COL=$C_IDLE ;;
    esac
}

pct_col() { local v=$1; if ((v >= 90)); then echo "$C_WAIT"; elif ((v >= 70)); then echo "$C_WORK"; else echo "$C_OK"; fi; }

# --- drawing ----------------------------------------------------------------------------------------------

render() {
    printf -v now '%(%s)T' -1
    local -a body=() core=() keys=() bot=() frame=()
    local oi idx p ag lastag="" selfirst=0 sellast=0 mark st name max pad sp line t model eff ctx cmp qt sh sb g
    local br wt ch ah bh gi gp
    for ((oi = 0; oi < ${#order[@]}; oi++)); do
        idx=${order[oi]}; p=${paths[idx]}; ag=${agents[idx]/#-/claude}
        if [[ "$ag" != "$lastag" ]]; then body+=("$C_HEAD-- $ag --$C_RST"); lastag=$ag; fi
        ((oi == sel)) && selfirst=${#body[@]}
        status_info "$p"
        mark=" "; ((oi == sel)) && mark="▸"
        st=$ST_TXT; name=${names[idx]}
        max=$((W - 5 - ${#st})); ((max < 4)) && max=4
        name=${name:0:max}
        pad=$((W - 5 - ${#name} - ${#st})); ((pad < 1)) && pad=1
        printf -v sp '%*s' "$pad" ''
        if ((oi == sel)); then line="$C_SEL$mark $ST_SYM $name$sp$st$C_RST"
        else line="$mark $ST_COL$ST_SYM$C_RST $name$sp$ST_COL$st$C_RST"; fi
        body+=("$line")
        if [[ -n "${P_pid[$p]:-}" ]]; then
            model=${S_model[$p]:--}; eff=${S_eff[$p]:--}; ctx=${S_ctx[$p]:--}; cmp=${S_cmp[$p]:--}; qt=${S_quota[$p]:--}
            if [[ "$model" != "-" ]]; then
                t=$model; [[ "$eff" != "-" ]] && t+=" · $eff"
                body+=("    $C_ACC${t:0:$((W - 5))}$C_RST")
            fi
            t=""
            [[ "$ctx" != "-" ]] && t+="ctx $(pct_col "$ctx")$ctx%$C_RST"
            [[ "$cmp" != "-" ]] && t+="  compact ~$cmp%"
            [[ "$qt" != "-" ]] && t+="  quota $qt% left"
            [[ -n "$t" ]] && body+=("    $t")
            sh=${SHN[$p]:-0}; sb=${SUBN[$p]:-0}; t=""
            ((sh > 0)) && t+="▶ $sh sh  "
            ((sb > 0)) && t+="◈ $sb"
            [[ -n "$t" ]] && body+=("    $C_ACC$t$C_RST")
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
            body+=("    $C_DIM${g:0:$((W - 5))}$C_RST")
        fi
        ((oi == sel)) && sellast=$((${#body[@]} - 1))
    done

    # Bottom block, pinned: separator, selected path, hint, message, usage, keys.
    local selp="" hint="Enter open  D remove"
    if ((${#order[@]})); then
        selp=${paths[${order[sel]}]}
        [[ -n "${P_pid[$selp]:-}" ]] && hint="Enter focus  X close"
    fi
    ((${#selp} > W - 2)) && selp="…${selp: -$((W - 3))}"
    core+=("$C_DIM$SEP$C_RST" "$C_DIM$selp$C_RST" "$C_DIM$hint$C_RST" "$C_WORK${MSG:0:$((W - 1))}$C_RST")
    keys+=("$C_HEAD-- keys --$C_RST"
           "$C_DIM↑↓ select  ⏎ open  X close$C_RST"
           "$C_DIM D remove  A add  G cli$C_RST"
           "$C_DIM⇧↑↓ reorder  F diff  W tree$C_RST"
           "$C_DIM T toasts  M+arrow move  Q quit$C_RST"
           "$C_DIM◐ work  ! wait  ✓ done  ○ idle$C_RST"
           "$C_DIM▶ shells  ◈ sub-agents  Alt+D$C_RST")
    local room=$((H - 6))
    local -a use=("${USAGE[@]}")
    if ((${#core[@]} + ${#use[@]} + ${#keys[@]} > room)); then keys=(); fi
    if ((${#core[@]} + ${#use[@]} > room)); then use=(); fi
    bot=("${core[@]}")
    ((${#use[@]})) && bot+=("${use[@]}")
    ((${#keys[@]})) && bot+=("${keys[@]}")

    local rh=$((H - 2 - ${#bot[@]})) total=${#body[@]}
    ((rh < 1)) && rh=1
    ((sellast >= top + rh)) && top=$((sellast - rh + 1))
    ((selfirst < top)) && top=$selfirst
    ((top > total - rh)) && top=$((total - rh))
    ((top < 0)) && top=0

    frame[0]="$C_HEAD tai $C_RST${C_DIM}${#P_pid[@]} open$C_RST"
    frame[1]=""
    local r
    for ((r = 0; r < rh; r++)); do frame[$((r + 2))]="${body[top + r]:-}"; done
    for ((r = 0; r < ${#bot[@]}; r++)); do frame[$((H - ${#bot[@]} + r))]="${bot[r]}"; done

    local out="" first_bot=$((H - ${#bot[@]}))
    if ((FULL)); then out=$'\e[2J'; prev=(); FULL=0; fi
    for ((r = 0; r < H; r++)); do
        line="${frame[r]:-}"
        if [[ "$line" != "${prev[r]-}" || $r -ge $first_bot ]]; then
            out+=$'\e['$((r + 1))';1H'"$line"$'\e[K'
            prev[r]=$line
        fi
    done
    printf '%s' "$out"
}

# One-key y/N question on the message line.
confirm() {
    MSG="$1 (y/N)"; render
    local k; IFS= read -rsn1 k
    [[ "$k" == [yY] ]]
}

choose_agent() {   # prints the chosen CLI (empty if cancelled)
    if ((${#INSTALLED[@]} == 1)); then echo "${INSTALLED[0]}"; return; fi
    local line="" i k
    for i in "${!INSTALLED[@]}"; do line+="$((i + 1))=${INSTALLED[i]} "; done
    MSG="CLI: $line"; render >&2
    IFS= read -rsn1 k
    [[ "$k" =~ ^[1-9]$ ]] && ((k <= ${#INSTALLED[@]})) && echo "${INSTALLED[k - 1]}"
}

add_flow() {
    local dir
    printf '\e[H\e[2J\e[?25h\e[1mAdd project\e[0m\nFolder path:\n'
    IFS= read -re dir
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
    MSG="Added $(basename "$dir")"
}

# Reads a key into KEY; returns 1 on the 1 s timeout so the list can refresh.
read_key() {
    local k rest
    IFS= read -rsn1 -t 1 k || return 1
    if [[ "$k" == $'\e' ]]; then
        IFS= read -rsn2 -t 0.05 rest
        case "$rest" in
            '[A') KEY=up ;; '[B') KEY=down ;; '[C') KEY=right ;; '[D') KEY=left ;;
            '[1') IFS= read -rsn3 -t 0.05 rest   # modified arrows: ESC [ 1 ; 2 A is Shift+Up
                  case "$rest" in ';2A') KEY=sup ;; ';2B') KEY=sdown ;; *) KEY=other ;; esac ;;
            *) KEY=other ;;
        esac
    elif [[ -z "$k" ]]; then KEY=enter
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
    ((${#P_pid[@]})) && return
    [[ -f "$OPEN_FILE" ]] || return
    local p i
    while IFS= read -r p; do
        for i in "${!paths[@]}"; do
            [[ "${paths[i]}" == "$p" ]] && { open_project "${names[i]}" "$p" "${agents[i]}" nofocus; break; }
        done
    done < <(jq -r '.[]' "$OPEN_FILE" 2>/dev/null)
    tmux select-pane -t "$TMUX_PANE"
}

save_open() {   # stable for 4 s -> write open.json
    ((restored)) || return
    local sig
    sig="$(open_sig)"
    if [[ "$sig" != "$last_sig" ]]; then last_sig=$sig; sig_since=$now; return; fi
    [[ "$sig" == "$saved_sig" ]] && return
    ((now - sig_since >= 4)) || return
    saved_sig=$sig
    if [[ -n "$sig" ]]; then
        mapfile -t arr <<< "$sig"
        jq -n '$ARGS.positional' --args "${arr[@]}" | write_atomic "$OPEN_FILE"
    else
        echo '[]' | write_atomic "$OPEN_FILE"
    fi
}

# --- main -------------------------------------------------------------------------------------------------

gh_poll & GH_PID=$!
cleanup() { kill "$GH_PID" 2>/dev/null; printf '\e[?25h'; }
trap cleanup EXIT
trap 'size' WINCH
printf '\e[?25l'
size
load
gather
restore_session
gather
usage_refresh

while true; do
    render
    if read_key; then
        n=${#order[@]}
        cur=-1; ((n)) && cur=${order[sel]}
        case "$KEY" in
            up|k)   ((n)) && sel=$(((sel + n - 1) % n)) ;;
            down|j) ((n)) && sel=$(((sel + 1) % n)) ;;
            sup|sdown)   # reorder within the CLI group; the highlight follows the project
                ((n)) || continue
                if [[ "$KEY" == sup ]]; then to=$((sel - 1)); else to=$((sel + 1)); fi
                if ((to < 0 || to >= n)); then continue; fi
                nb=${order[to]}
                if [[ "${agents[cur]/#-/claude}" != "${agents[nb]/#-/claude}" ]]; then MSG="Different CLI group"; continue; fi
                swap_projects "${paths[cur]}" "${paths[nb]}" && sel=$to
                load ;;
            f|F)
                ((n)) || continue
                printf -v cmd 'git -C %q -c color.ui=always -c core.pager="less -R" diff HEAD --stat --patch || { echo "git diff failed (not a repo?)"; sleep 2; }' "${paths[cur]}"
                tmux new-window -n "diff ${names[cur]}" -c "${paths[cur]}" "$cmd"
                MSG="Diff of ${names[cur]} opened in a new window (q closes it)" ;;
            t|T)
                if [[ -e "$TOAST_OFF" ]]; then rm -f "$TOAST_OFF"; MSG="Toasts on"
                else date -Iseconds > "$TOAST_OFF" 2>/dev/null || : > "$TOAST_OFF"; MSG="Toasts off"; fi ;;
            w|W)
                ((n)) || continue
                printf '\e[H\e[2J\e[?25h\e[1mNew worktree of %s\e[0m\nNew branch (blank cancels):\n' "${names[cur]}"
                IFS= read -re br
                printf '\e[?25l'; FULL=1
                [[ -z "$br" ]] && { MSG="Worktree cancelled"; continue; }
                safe="${br//[^A-Za-z0-9._-]/-}"
                wdir="${paths[cur]%/}-$safe"
                if out="$(git -C "${paths[cur]}" worktree add -b "$br" "$wdir" 2>&1)"; then
                    if add_project "$wdir"; then load; MSG="Worktree $safe added"
                        for oi in "${!order[@]}"; do [[ "${paths[${order[oi]}]}" == "$wdir" ]] && sel=$oi; done
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
