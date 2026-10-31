# Claude Code hook (UserPromptSubmit, Notification, Stop, SessionEnd, SubagentStart/Stop): records what the
# session is doing so the dashboard can show working / waiting-for-you / done.
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { return }
try { $data = $raw | ConvertFrom-Json } catch { return }

. (Join-Path $PSScriptRoot 'lib.ps1')
# Copilot's default payload carries no event name, so its hook entries pass it as the first argument.
$event = if ($args.Count) { [string]$args[0] } else { [string]$data.hook_event_name }
$dir = $env:TAI_PROJECT_DIR   # set by slot.ps1: the listed project folder, even if Claude's cwd moved
if (-not $dir) { $dir = $env:CLAUDE_PROJECT_DIR }
if (-not $dir) { $dir = $data.cwd }
if (-not $dir) { return }

# The idle reminder fires about a minute after Stop; it must not turn "done" into "waiting".
if ($event -eq 'Notification' -and $data.notification_type -eq 'idle_prompt') { return }

# Session -> working folder ("session_id<TAB>cwd<TAB>updated" in state\sessions.txt). Sessions hosted by Claude's
# background daemon live outside the pane's process tree; the dashboard uses this to find their shells.
if ($data.session_id -and $data.cwd) {
    $mapDir = Join-Path $PSScriptRoot 'state'
    New-Item -ItemType Directory -Force $mapDir | Out-Null
    $mapFile = Join-Path $mapDir 'sessions.txt'
    $sid = [string]$data.session_id
    $mapMutex = New-Object System.Threading.Mutex($false, 'Global\tai_sessions')
    try {
        [void]$mapMutex.WaitOne(3000)
        $now = Get-Date
        $keep = @()
        if (Test-Path $mapFile) {
            foreach ($l in @(Get-Content $mapFile -ErrorAction SilentlyContinue)) {
                $f = $l -split "`t"
                if ($f.Count -lt 3 -or $f[0] -eq $sid) { continue }
                try { if (($now - [datetime]$f[2]).TotalHours -gt 24) { continue } } catch { continue }
                $keep += $l
            }
        }
        $keep += "$sid`t$($data.cwd)`t$($now.ToString('o'))"
        Set-Content $mapFile $keep -Encoding utf8
    } catch { }
    finally { try { $mapMutex.ReleaseMutex() } catch { } }
}

# Sub-agents running inside the session: one line per running agent ("id<TAB>type<TAB>started") in
# state\subs_<key>.txt. Parallel agents fire hooks at the same moment, so the read-modify-write is locked.
if ($event -eq 'SubagentStart' -or $event -eq 'SubagentStop') {
    $subDir = Join-Path $PSScriptRoot 'state'
    New-Item -ItemType Directory -Force $subDir | Out-Null
    $subFile = Join-Path $subDir ('subs_' + (Get-StateKey $dir) + '.txt')
    $id = [string]$data.agent_id
    if (-not $id) { return }
    $mutex = New-Object System.Threading.Mutex($false, 'Global\tai_subs')
    try {
        [void]$mutex.WaitOne(3000)
        $lines = @()
        if (Test-Path $subFile) { $lines = @(Get-Content $subFile -ErrorAction SilentlyContinue | Where-Object { $_ -and -not $_.StartsWith("$id`t") }) }
        if ($event -eq 'SubagentStart') { $lines += "$id`t$($data.agent_type)`t$((Get-Date).ToString('o'))" }
        if ($lines.Count) { Set-Content $subFile $lines -Encoding utf8 } else { Remove-Item $subFile -Force -ErrorAction SilentlyContinue }
    } catch { }
    finally { try { $mutex.ReleaseMutex() } catch { } }
    return
}

# Claude and Codex use the PascalCase names (see codex-hooks.example.json); Copilot's camelCase and Cursor's
# names map to the same states (switch matches case-insensitively). Anything else, e.g. SessionEnd, clears the state.
$status = switch ($event) {
    { $_ -in 'UserPromptSubmit', 'userPromptSubmitted', 'beforeSubmitPrompt', 'PreToolUse' } { 'working' }
    { $_ -in 'Notification', 'PermissionRequest' } { 'waiting' }
    { $_ -in 'Stop', 'agentStop' }                 { 'done' }
    default                                        { $null }
}
$stateDir = Join-Path $PSScriptRoot 'state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
# Codex, Cursor, Qwen and Copilot put the model on hook payloads (Qwen's Stop also carries context_usage, a 0-1
# ratio); keep them for the dashboard (Claude's status line does this for Claude). Merged into the old file: Stop has no model.
$hasModel = $data.model -is [string] -and $data.model
$ctxPct = $null
if ($env:TAI_AGENT -eq 'qwen' -and $data.context_usage -is [ValueType]) {
    $u = [double]$data.context_usage
    $ctxPct = [int][math]::Round($(if ($u -le 1) { $u * 100 } else { $u }))
}
if ($env:TAI_AGENT -in 'codex', 'cursor', 'qwen', 'copilot' -and ($hasModel -or $null -ne $ctxPct)) {
    $sf = Join-Path $stateDir ((Get-StateKey $dir) + '.json')
    $st = [ordered]@{}
    try { foreach ($pr in (Get-Content $sf -Raw -ErrorAction Stop | ConvertFrom-Json).PSObject.Properties) { $st[$pr.Name] = $pr.Value } } catch { }
    $st['dir'] = $dir; $st['agent'] = $env:TAI_AGENT; $st['updated'] = (Get-Date).ToString('o')
    if ($hasModel) { $st['model'] = $data.model }
    if ($null -ne $ctxPct) { $st['ctx'] = $ctxPct }
    $sj = [pscustomobject]$st | ConvertTo-Json
    try { Set-Content "$sf.tmp" $sj -Encoding utf8 -ErrorAction Stop; Move-Item "$sf.tmp" $sf -Force } catch { }
}
$file = Join-Path $stateDir ('hook_' + (Get-StateKey $dir) + '.json')
if (-not $status) {   # SessionEnd
    Remove-Item $file -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $stateDir ('subs_' + (Get-StateKey $dir) + '.txt')) -Force -ErrorAction SilentlyContinue
    return
}

$json = [pscustomobject]@{
    dir     = $dir
    status  = $status
    message = $data.message
    updated = (Get-Date).ToString('o')
} | ConvertTo-Json
try {
    Set-Content "$file.tmp" $json -Encoding utf8 -ErrorAction Stop
    Move-Item "$file.tmp" $file -Force
} catch { }
