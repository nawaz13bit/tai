#!/usr/bin/env bash
# Antigravity (agy) status line: records model, context, quota and activity for the dashboard.
# Register it in ~/.gemini/antigravity-cli/settings.json (see agy-settings.example.json).
# Only panes started by tai (TAI_PROJECT_DIR set) are recorded; elsewhere it just prints the line.
raw="$(cat)"
[[ -n "${raw//[[:space:]]/}" ]] || exit 0
. "$(dirname "$(readlink -f "$0")")/lib.sh"

dir="${TAI_PROJECT_DIR:-}"
# Like Claude's hooks: working/waiting -> idle becomes "done" (kept until the next working/waiting); activity_at is
# when the activity last changed, so the dashboard can show its age.
prev="null"
if [[ -n "$dir" && -f "$STATE_DIR/$(state_key "$dir").json" ]]; then
    prev="$(jq -c '.' "$STATE_DIR/$(state_key "$dir").json" 2>/dev/null)" || prev="null"
    [[ -n "$prev" ]] || prev="null"
fi
# quotas: per model bucket, name and percent left; quota_left: the lowest of them.
res="$(jq -c --arg dir "$dir" --argjson prev "$prev" '
    [(.quota // {}) | to_entries[] | select(.value.remaining_fraction != null)
        | {name: .key, left: ((100 * .value.remaining_fraction * 10 | round) / 10)}] as $q
    | (if $prev != null and $prev.agent == "agy" then ($prev.activity // "") else "" end) as $pa
    | (if .tool_confirmation_pending then "waiting"
       elif (.agent_state | IN("thinking", "working", "tool_use")) then "working"
       elif .agent_state == "idle" then (if ($pa | IN("working", "waiting", "done")) then "done" else "idle" end)
       else null end) as $act
    | (now | floor) as $now
    | {
        dir: $dir,
        agent: "agy",
        model: .model.display_name,
        ctx: .context_window.used_percentage,
        quota_left: ($q | map(.left) | min),
        quotas: $q,
        activity: $act,
        activity_at_epoch: (if $prev != null and $prev.agent == "agy" and $prev.activity_at_epoch != null and $pa == $act
                            then $prev.activity_at_epoch else $now end),
        updated_epoch: $now
      }' <<< "$raw" 2>/dev/null)" || exit 0

if [[ -n "$dir" ]]; then
    mkdir -p "$STATE_DIR"
    write_atomic "$STATE_DIR/$(state_key "$dir").json" <<< "$res"
fi

ctx="$(jq -r 'if .ctx != null then "\(.ctx | round)%" else "--" end' <<< "$res")"
if [[ -n "$dir" ]]; then echo "[$(basename "$dir")] ctx $ctx"; else echo "ctx $ctx"; fi
