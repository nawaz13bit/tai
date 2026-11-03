#!/usr/bin/env zsh
# Antigravity (agy) status line: records model, context, quota and activity for the dashboard.
# Register it in ~/.gemini/antigravity-cli/settings.json (see agy-settings.example.json).
# Only panes started by tai (TAI_PROJECT_DIR set) are recorded; elsewhere it just prints the line.
raw="$(cat)"
[[ -n "${raw//[[:space:]]/}" ]] || exit 0
. "${0:A:h}/lib.zsh"

dir="${TAI_PROJECT_DIR:-}"
# quotas: per model bucket, name and percent left; quota_left: the lowest of them.
res="$(jq -c --arg dir "$dir" '
    [(.quota // {}) | to_entries[] | select(.value.remaining_fraction != null)
        | {name: .key, left: ((100 * .value.remaining_fraction * 10 | round) / 10)}] as $q
    | {
        dir: $dir,
        agent: "agy",
        model: .model.display_name,
        ctx: .context_window.used_percentage,
        quota_left: ($q | map(.left) | min),
        quotas: $q,
        activity: (if .tool_confirmation_pending then "waiting"
                   elif (.agent_state | IN("thinking", "working", "tool_use")) then "working"
                   elif .agent_state == "idle" then "idle"
                   else null end),
        updated_epoch: (now | floor)
      }' <<< "$raw" 2>/dev/null)" || exit 0

if [[ -n "$dir" ]]; then
    mkdir -p "$STATE_DIR"
    write_atomic "$STATE_DIR/$(state_key "$dir").json" <<< "$res"
fi

ctx="$(jq -r 'if .ctx != null then "\(.ctx | round)%" else "--" end' <<< "$res")"
if [[ -n "$dir" ]]; then print -r -- "[${dir:t}] ctx $ctx"; else print -r -- "ctx $ctx"; fi
