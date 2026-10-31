# terminal_ai: one Windows Terminal window with a project dashboard and up to nine Claude panes (as many as the window fits).
# Usage:
#   .\tai.ps1                              open the workspace (dashboard + 1 pane; more panes appear as projects open)
#   .\tai.ps1 add <path> [<path> ...] [-Name <name>]   add projects (any drive)
#   .\tai.ps1 remove <name>               remove a project
#   .\tai.ps1 list                        show projects
# Projects are opened from the dashboard: select one and press Enter.
param(
    [Parameter(Position = 0)][ValidateSet('open', 'add', 'remove', 'list')][string]$Command = 'open',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Args2,
    [string]$Name,
    [switch]$DryRun   # print the wt command instead of launching
)

. (Join-Path $PSScriptRoot 'lib.ps1')
$root = $PSScriptRoot
$stateDir = Join-Path $root 'state'

function Open-Workspace {
    $alive = Join-Path $stateDir 'dashboard.alive'
    if ((Test-Path $alive) -and ((Get-Date) - (Get-Item $alive).LastWriteTime).TotalSeconds -lt 3) {
        Write-Host 'Workspace is already open (dashboard is running).'
        return
    }
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    Remove-Item (Join-Path $stateDir 'boot.log') -Force -ErrorAction SilentlyContinue
    Write-Boot 'tai: start'
    # Panes that survived a dashboard crash would collide with the new ones; don't stack a second set.
    $live = @()
    foreach ($f in Get-ChildItem $stateDir -Filter 'slot*.json' -ErrorAction SilentlyContinue) {
        try { $s = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        if ($s.pid -and (Test-SlotAlive $s.pid $s.since)) { $live += $s.slot }
    }
    if ($live.Count) {
        Write-Host "Panes $($live -join ', ') are still running without a dashboard. Close the terminal window, then run tai again."
        return
    }
    Remove-Item (Join-Path $stateDir 'slot*') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $stateDir 'hook_*') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $stateDir 'subs_*') -Force -ErrorAction SilentlyContinue

    # Start with the dashboard and one pane; the dashboard splits in more as projects open (see lib.ps1).
    Remove-Item (Join-Path $stateDir 'layout.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $stateDir 'cells.json') -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $stateDir 'panes.count') 1
    Save-Rects @(, $script:firstRect)
    $parts = @(
        "-M -w tai new-tab $script:wtProfile --title dashboard -d `"$root`" $script:psCmd `"$root\dashboard.ps1`"",
        "split-pane -V -s 0.8 $(New-SlotArgs 1)",
        'move-focus first'
    )
    $wtArgs = $parts -join ' ; '
    if ($DryRun) { Write-Host $wtArgs; return }
    Start-Process wt.exe -ArgumentList $wtArgs
    Write-Boot 'tai: wt launched'
}

switch ($Command) {
    'open' { Open-Workspace }
    'add' {
        if (-not $Args2) { throw 'Usage: tai add <path> [<path> ...] [-Name <name>]' }
        if ($Name -and $Args2.Count -gt 1) { throw '-Name only works with a single path.' }
        Save-Projects (Add-Projects (Get-Projects) $Args2 $Name)
    }
    'remove' {
        if (-not $Args2) { throw 'Usage: tai remove <name>' }
        $projects = @(Get-Projects)
        $kept = @($projects | Where-Object { $_.name -ne $Args2[0] })
        if ($kept.Count -eq $projects.Count) { throw "No project named '$($Args2[0])'." }
        Save-Projects $kept
        Write-Host "Removed $($Args2[0])"
    }
    'list' {
        @(Get-Projects) | Format-Table name, path -AutoSize
    }
}
