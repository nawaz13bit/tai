#!/usr/bin/env zsh
# Claude Code status line: model, context usage, auto-compaction. Records the per-project state for the dashboard
# and the account rate limits to usage.json for the usage bars.
raw="$(cat)"
[[ -n "${raw//[[:space:]]/}" ]] || exit 0
. "${0:A:h}/lib.zsh"

# A pane on another account (CLAUDE_CONFIG_DIR set by tai) has its own settings.json.
user_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
[[ -f "$user_settings" ]] || user_settings="$HOME/.claude/settings.json"
us="$(jq -c 'if type == "object" then . else {} end' "$user_settings" 2>/dev/null)" || us='{}'
[[ -n "$us" ]] || us='{}'

# Auto-compaction isn't sent on stdin; read the window (tokens) from user settings. Effort: what Claude Code
# reports if present, else the user's configured level.
res="$(jq -c --argjson us "$us" '
    . as $d
    | $d.context_window.used_percentage as $ctx
    | $d.context_window.context_window_size as $win
    | (if ($us.autoCompactWindow | type) == "number" and $win then ([100, 100 * $us.autoCompactWindow / $win] | min) else 95 end) as $at
    | ([$d.effort.level?, ($d.effort | strings?), $d.effort_level?] | map(select(type == "string" and . != "")) | .[0]) as $eff
    | ($d.workspace.project_dir // $d.workspace.current_dir) as $dir
    | {
        dir: $dir,
        model: $d.model.display_name,
        effort: ($eff // $us.effortLevel),
        ctx: $ctx,
        compact: (if $ctx != null then ([0, $at - $ctx] | max) else null end),
        cost: $d.cost.total_cost_usd,
        transcript: $d.transcript_path,
        updated_epoch: (now | floor)
      }' <<< "$raw" 2>/dev/null)" || exit 0

dir="$(jq -r '.dir // empty' <<< "$res")"
if [[ -n "$dir" ]]; then
    mkdir -p "$STATE_DIR"
    write_atomic "$STATE_DIR/$(state_key "$dir").json" <<< "$res"
fi

usage="$(jq -c '.rate_limits | select(. != null) | {updated_epoch: (now | floor), five_hour, seven_day}' <<< "$raw" 2>/dev/null)"
if [[ -n "$usage" ]]; then
    # A pane on another account (CLAUDE_CONFIG_DIR set by tai) writes its own file, so accounts don't overwrite each other.
    ufile="$USAGE_FILE"
    [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && ! is_default_account_dir claude "$CLAUDE_CONFIG_DIR" && ufile="$TAI_CONF/$(usage_name_for_dir "$CLAUDE_CONFIG_DIR")"
    mkdir -p "$TAI_CONF"
    write_atomic "$ufile" <<< "$usage"
fi

if [[ -n "$dir" ]]; then
    ctx="$(jq -r 'if .ctx != null then "\(.ctx | round)%" else "--" end' <<< "$res")"
    compact="$(jq -r 'if .compact != null then "compact in ~\(.compact | round)%" else "compact --" end' <<< "$res")"
    print -r -- "[${dir:t}] ctx $ctx | $compact"
fi
