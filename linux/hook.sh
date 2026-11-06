#!/usr/bin/env bash
# Claude Code / Codex hook (UserPromptSubmit, Notification, Stop, SessionEnd, SubagentStart/Stop, PreToolUse,
# PermissionRequest): records what the session is doing so the dashboard can show working / waiting / done.
raw="$(cat)"
[[ -n "${raw//[[:space:]]/}" ]] || exit 0
. "$(dirname "$(readlink -f "$0")")/lib.sh"

IFS=$'\t' read -r event ntype sid cwd agent_id agent_type model ctxp message < <(
    jq -r '[.hook_event_name // "-", .notification_type // "-", .session_id // "-", .cwd // "-", .agent_id // "-",
            .agent_type // "-", (.model | if type == "string" and . != "" then . else "-" end),
            (.context_usage | if type == "number" then ((if . <= 1 then . * 100 else . end) | round) else "-" end),
            ((.message // "") | tostring | gsub("[\t\n]"; " "))] | @tsv' <<< "$raw" 2>/dev/null) || exit 0
event="${1:-$event}"   # Copilot's default payload carries no event name, so its hook entries pass it as the first argument
[[ -n "$event" && "$event" != "-" ]] || exit 0

dir="${TAI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"   # TAI_PROJECT_DIR: the listed folder, even if the CLI's cwd moved
[[ -n "$dir" ]] || { [[ "$cwd" != "-" ]] && dir="$cwd"; }
[[ -n "$dir" ]] || exit 0
mkdir -p "$STATE_DIR"
key="$(state_key "$dir")"
now="$(date +%s)"

# The idle reminder fires about a minute after Stop; it must not turn "done" into "waiting".
[[ "$event" == Notification && "$ntype" == idle_prompt ]] && exit 0

# Session -> working folder ("session_id<TAB>cwd<TAB>updated_epoch" in state/sessions.txt). Sessions hosted by
# Claude's background daemon live outside the pane's process tree; the dashboard uses this to find their shells.
update_sessions() {
    local f="$STATE_DIR/sessions.txt" keep=""
    [[ -f "$f" ]] && keep="$(awk -F'\t' -v sid="$sid" -v now="$now" '$1 != sid && NF >= 3 && now - $3 < 86400' "$f")"
    { [[ -n "$keep" ]] && printf '%s\n' "$keep"; printf '%s\t%s\t%s\n' "$sid" "$cwd" "$now"; } | write_atomic "$f"
}
if [[ "$sid" != "-" && "$cwd" != "-" ]]; then with_lock update_sessions; fi

# Sub-agents running inside the session: one line per running agent ("id<TAB>type<TAB>started_epoch") in
# state/subs_<key>.txt. Parallel agents fire hooks together, so the read-modify-write is locked.
update_subs() {
    local f="$STATE_DIR/subs_$key.txt" keep=""
    [[ -f "$f" ]] && keep="$(awk -F'\t' -v id="$agent_id" '$1 != id' "$f")"
    { [[ -n "$keep" ]] && printf '%s\n' "$keep"
      [[ "$event" == SubagentStart ]] && printf '%s\t%s\t%s\n' "$agent_id" "$agent_type" "$now"; } > "$f.tmp.$$"
    if [[ -s "$f.tmp.$$" ]]; then mv -f "$f.tmp.$$" "$f"; else rm -f "$f.tmp.$$" "$f"; fi
}
if [[ "$event" == SubagentStart || "$event" == SubagentStop ]]; then
    [[ "$agent_id" != "-" ]] && with_lock update_subs
    exit 0
fi

# Claude and Codex use the PascalCase names; Copilot's camelCase and Cursor's names map to the same states.
case "$event" in
    UserPromptSubmit|userPromptSubmitted|beforeSubmitPrompt|PreToolUse) status=working ;;
    Notification|PermissionRequest) status=waiting ;;
    Stop|agentStop) status=done ;;
    *) status="" ;;
esac

# Codex, Cursor, Qwen and Copilot put the model on hook payloads (Qwen's Stop also carries context_usage); keep them
# for the dashboard (Claude's status line does this for Claude). Merged into the old file: Stop has no model.
case "${TAI_AGENT:-}" in codex|cursor|qwen|copilot)
    if [[ "$model" != "-" || "$ctxp" != "-" ]]; then
        old='{}'; [[ -f "$STATE_DIR/$key.json" ]] && old="$(jq -c . "$STATE_DIR/$key.json" 2>/dev/null)"
        [[ -n "$old" ]] || old='{}'
        jq -nc --argjson o "$old" --arg d "$dir" --arg a "$TAI_AGENT" --arg m "$model" --arg c "$ctxp" --argjson t "$now" \
            '$o + {dir: $d, agent: $a, updated_epoch: $t}
             + (if $m != "-" then {model: $m} else {} end)
             + (if $c != "-" then {ctx: ($c | tonumber)} else {} end)' | write_atomic "$STATE_DIR/$key.json"
    fi ;;
esac

hook_file="$STATE_DIR/hook_$key.json"
if [[ -z "$status" ]]; then   # SessionEnd
    rm -f "$hook_file" "$STATE_DIR/subs_$key.txt"
    exit 0
fi
msg=""; [[ "$message" != "-" ]] && msg="$message"
jq -nc --arg d "$dir" --arg s "$status" --arg m "$msg" --argjson t "$now" \
    '{dir: $d, status: $s, message: $m, updated_epoch: $t}' | write_atomic "$hook_file"
