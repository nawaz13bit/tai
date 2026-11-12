# Per-pane status line: model, context usage, auto-compaction. Also records
# account rate limits to usage.json so the global usage pane can show them.
$raw = (New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding $false))).ReadToEnd()   # UTF-8, not the OEM code page, so non-ASCII paths keep their state key
if ([string]::IsNullOrWhiteSpace($raw)) { return }
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }   # printed line as UTF-8 too
try { $data = $raw | ConvertFrom-Json } catch { return }

# Write via a temp file so the dashboard never reads a half-written file.
function Write-Atomic($path, $json) {
    $tmp = "$path.$PID.tmp"   # per-process name: several panes write the shared usage.json at once
    try { Set-Content $tmp $json -Encoding utf8; Move-Item $tmp $path -Force }
    catch { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

$model = $data.model.display_name
$ctx = $data.context_window.used_percentage
$ctxText = if ($null -ne $ctx) { '{0:N0}%' -f $ctx } else { '--' }
# Auto-compaction isn't sent on stdin; read the window (tokens) from user settings.
$compactAt = 95
$window = $data.context_window.context_window_size
# A pane on another account (CLAUDE_CONFIG_DIR set by tai) has its own settings.json.
$userSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
if ($env:CLAUDE_CONFIG_DIR) {
    $acctSettings = Join-Path $env:CLAUDE_CONFIG_DIR 'settings.json'
    if (Test-Path $acctSettings) { $userSettings = $acctSettings }
}
# settings.json is parsed once and shared by the compaction and effort lookups below.
$settingsObj = $null
$settingsLoaded = $false
function Get-UserSettings {
    if (-not $script:settingsLoaded) {
        $script:settingsLoaded = $true
        try { $script:settingsObj = [IO.File]::ReadAllText($userSettings) | ConvertFrom-Json } catch { }
    }
    return $script:settingsObj
}
if ((Test-Path $userSettings) -and $window) {
    $acw = $null
    try { $acw = (Get-UserSettings).autoCompactWindow } catch { }
    if ($acw -is [int] -or $acw -is [long] -or $acw -is [double]) {
        $compactAt = [math]::Min(100, 100 * $acw / $window)
    }
}
# Effort: use what Claude Code reports if present, else the user's configured level.
$effort = $null
foreach ($candidate in @($data.effort.level, $data.effort, $data.effort_level)) {
    if ($candidate -is [string] -and $candidate) { $effort = $candidate; break }
}
if (-not $effort -and (Test-Path $userSettings)) {
    try { $effort = (Get-UserSettings).effortLevel } catch { }
}
$left = if ($null -ne $ctx) { [math]::Max(0, $compactAt - $ctx) } else { $null }
$compact = if ($null -ne $left) { 'compact in ~{0:N0}%' -f $left } else { 'compact --' }

# Per-project state for the dashboard pane (slot.ps1 / status.ps1).
$dir = $data.workspace.project_dir
if (-not $dir) { $dir = $data.workspace.current_dir }
if ($dir) {
    $stateDir = Join-Path $PSScriptRoot 'state'
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $norm = $dir.Replace('/', '\').TrimEnd('\').ToLower()
    # Readable prefix plus a hash, so C:\a-b and C:\a_b get different files.
    $md5 = [Security.Cryptography.MD5]::Create()
    $hash = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))) -replace '-', '').Substring(0, 8)
    $key = ($norm -replace '[^a-z0-9]', '_') + '_' + $hash
    $state = [pscustomobject]@{
        dir        = $dir
        model      = $model
        effort     = $effort
        ctx        = $ctx
        compact    = $left
        cost      = $data.cost.total_cost_usd
        transcript = $data.transcript_path
        updated    = (Get-Date).ToString('o')
    } | ConvertTo-Json
    try { Write-Atomic (Join-Path $stateDir "$key.json") $state } catch { }
}

if ($data.rate_limits) {
    $usage = [pscustomobject]@{
        updated   = (Get-Date).ToString('o')
        five_hour = $data.rate_limits.five_hour
        seven_day = $data.rate_limits.seven_day
    } | ConvertTo-Json -Depth 5
    # A pane on another account (CLAUDE_CONFIG_DIR set by tai) writes its own file, so accounts don't overwrite each other.
    $usageName = 'usage.json'
    if ($env:CLAUDE_CONFIG_DIR) { $usageName = 'usage-' + ((Split-Path $env:CLAUDE_CONFIG_DIR.TrimEnd('/', '\') -Leaf).ToLower() -replace '[^a-z0-9]', '_') + '.json' }
    # Skip the write when the limits are unchanged and the file was refreshed in the last 30 s: the status line runs
    # after every message, but the numbers move rarely.
    $usagePath = Join-Path $PSScriptRoot $usageName
    $same = $false
    try {
        $fi = New-Object IO.FileInfo $usagePath
        if ($fi.Exists -and ((Get-Date) - $fi.LastWriteTime).TotalSeconds -lt 30) {
            $old = [IO.File]::ReadAllText($usagePath) | ConvertFrom-Json
            $oldCore = [pscustomobject]@{ f = $old.five_hour; s = $old.seven_day } | ConvertTo-Json -Depth 5 -Compress
            $newCore = [pscustomobject]@{ f = $data.rate_limits.five_hour; s = $data.rate_limits.seven_day } | ConvertTo-Json -Depth 5 -Compress
            $same = ($oldCore -eq $newCore)
        }
    } catch { }
    if (-not $same) { try { Write-Atomic $usagePath $usage } catch { } }
}

# Model and effort are shown in the dashboard's project pane, so the line is the folder, context and compaction.
$project = if ($dir) { Split-Path $dir.TrimEnd('/', '\') -Leaf } else { $null }
if ($project) { Write-Output "[$project] ctx $ctxText | $compact" }
