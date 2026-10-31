# Antigravity (agy) status line: records model, context, quota and activity for the dashboard.
# Register it in ~/.gemini/antigravity-cli/settings.json (see agy-settings.example.json).
# Only panes started by tai (TAI_PROJECT_DIR set) are recorded; elsewhere it just prints the line.
$raw = (New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding $false))).ReadToEnd()   # UTF-8, not the OEM code page, so non-ASCII paths keep their state key
if ([string]::IsNullOrWhiteSpace($raw)) { return }
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }   # printed line as UTF-8 too
try { $data = $raw | ConvertFrom-Json } catch { return }

. (Join-Path $PSScriptRoot 'lib.ps1')

$ctx = $data.context_window.used_percentage
$ctxText = if ($null -ne $ctx) { '{0:N0}%' -f $ctx } else { '--' }

# Lowest remaining quota across model buckets, as a percentage.
$quotaLeft = $null
$quotas = @()   # per model bucket: name and percent left
if ($data.quota) {
    foreach ($b in $data.quota.PSObject.Properties) {
        $f = $b.Value.remaining_fraction
        if ($null -eq $f) { continue }
        $quotas += [pscustomobject]@{ name = [string]$b.Name; left = [math]::Round(100 * $f, 1) }
        if ($null -eq $quotaLeft -or 100 * $f -lt $quotaLeft) { $quotaLeft = 100 * $f }
    }
}

$activity = if ($data.tool_confirmation_pending) { 'waiting' }
            elseif (@('thinking', 'working', 'tool_use') -contains $data.agent_state) { 'working' }
            elseif ($data.agent_state -eq 'idle') { 'idle' }
            else { $null }

$dir = $env:TAI_PROJECT_DIR
if ($dir) {
    $stateDir = Join-Path $PSScriptRoot 'state'
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $file = Join-Path $stateDir ((Get-StateKey $dir) + '.json')
    $json = [pscustomobject]@{
        dir        = $dir
        agent      = 'agy'
        model      = $data.model.display_name
        ctx        = $ctx
        quota_left = $quotaLeft
        quotas     = $quotas
        activity  = $activity
        updated    = (Get-Date).ToString('o')
    } | ConvertTo-Json
    try {
        Set-Content "$file.$PID.tmp" $json -Encoding utf8 -ErrorAction Stop
        Move-Item "$file.$PID.tmp" $file -Force
    } catch { Remove-Item "$file.$PID.tmp" -Force -ErrorAction SilentlyContinue }
}

$project = if ($dir) { Split-Path $dir.TrimEnd('/', '\') -Leaf } else { $null }
if ($project) { Write-Output "[$project] ctx $ctxText" } else { Write-Output "ctx $ctxText" }
