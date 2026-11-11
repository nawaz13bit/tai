# One of up to nine panes (created on demand, see lib.ps1). Claude starts with Remote Control on. Waits for the dashboard to assign a project, runs Claude
# there (resuming the most recent conversation), then goes back to waiting (or closes the pane when the dashboard asked for that).
param([Parameter(Mandatory)][int]$Slot)

. (Join-Path $PSScriptRoot 'lib.ps1')
# Windows Terminal runs at a raised priority (Protect-Tai) and its panes inherit it; agents should stay Normal.
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'Normal' } catch { }
$stateDir = Join-Path $PSScriptRoot 'state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$assign = Join-Path $stateDir "slot$Slot.assign"
$running = Join-Path $stateDir "slot$Slot.json"
$closeFlag = Join-Path $stateDir "slot$Slot.close"
$exitFlag = Join-Path $stateDir "slot$Slot.exit"
# claude-settings.example.json is the tracked template (placeholder C:/path/to/terminal_ai). claude-settings.json is the
# copy in use (git-ignored): it is created from the template with this checkout's real folder the first time a pane
# starts, and then left alone so it can be edited by hand.
$settings = Join-Path $PSScriptRoot 'claude-settings.json'
if (-not (Test-Path -LiteralPath $settings)) {
    try {
        $repoRoot = (Split-Path $PSScriptRoot -Parent) -replace '\\', '/'
        $template = Join-Path $PSScriptRoot 'claude-settings.example.json'
        $text = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8).Replace('C:/path/to/terminal_ai', $repoRoot)
        [IO.File]::WriteAllText($settings, $text, (New-Object Text.UTF8Encoding $false))
    } catch { }
}

# Writes the slot file through a temp file, so the dashboard never reads it half written (and sees the slot as free).
function Write-SlotFile($Json) {
    $tmp = "$running.$PID.tmp"
    Set-Content $tmp $Json -Encoding utf8 -ErrorAction Stop
    Move-Item $tmp $running -Force -ErrorAction Stop
}

# Heartbeat: lets the dashboard notice when this pane's window is closed and drop it from the layout.
[pscustomobject]@{ slot = $Slot; pid = $PID; since = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content (Join-Path $stateDir "slot$Slot.pane") -Encoding utf8

Write-Boot "slot ${Slot}: ready"
while ($true) {
    Clear-Host
    $Host.UI.RawUI.WindowTitle = "pane $Slot"
    Write-Host "Pane $Slot - empty" -ForegroundColor DarkGray
    Write-Host 'Pick a project in the dashboard (left) and press Enter.' -ForegroundColor DarkGray
    while (-not (Test-Path $assign)) { Start-Sleep -Milliseconds 100 }

    try { $job = Get-Content $assign -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { Start-Sleep -Milliseconds 300; continue }   # unreadable: retry on the next pass
    if (-not $job.path) { Remove-Item $assign -Force; continue }
    # pid lets the dashboard find and stop Claude when the user closes the project.
    # The slot file is written before the assignment is removed: otherwise the dashboard can see this slot as free in between
    # and give it to another project (restore race).
    $slotJson = [pscustomobject]@{ slot = $Slot; name = $job.name; path = $job.path; agent = $job.agent; pid = $PID; since = (Get-Date).ToString('o') } | ConvertTo-Json
    try { Write-SlotFile $slotJson }
    catch { Start-Sleep -Milliseconds 300; continue }   # not written: keep the assignment and retry on the next pass
    Remove-Item $assign -Force

    # The window title follows the focused pane, so it shows the project; Sync-Layout maps the name back to this slot.
    $Host.UI.RawUI.WindowTitle = [string]$job.name
    Clear-Host
    $agent = if ($job.agent) { [string]$job.agent } else { 'claude' }
    # Chosen CLI not installed: use the first one that is (saved choice stays unchanged).
    if (-not (Test-AgentInstalled $agent)) {
        $alt = @($script:agents) | Where-Object { Test-AgentInstalled $_ } | Select-Object -First 1
        if (-not $alt) {
            Write-Host "No supported CLI ($($script:agents -join ', ')) found on PATH." -ForegroundColor Red
            Remove-Item $running -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 4
            continue
        }
        Write-Host "'$agent' is not installed - using '$alt' instead." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        $agent = $alt
        # Tell the dashboard what actually runs here so it shows the right info.
        try {
            Write-SlotFile ([pscustomobject]@{ slot = $Slot; name = $job.name; path = $job.path; agent = $agent; pid = $PID; since = (Get-Date).ToString('o') } | ConvertTo-Json)
        } catch { }
    }
    Remove-Item $closeFlag -Force -ErrorAction SilentlyContinue
    # A missing folder must not start the CLI in tai's own directory; [ ] in a path are not wildcards.
    if (-not (Test-Path -LiteralPath $job.path -PathType Container)) {
        Write-Host "Folder not found: $($job.path)" -ForegroundColor Red
        Remove-Item $running -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4
        continue
    }
    Push-Location -LiteralPath $job.path
    $env:TAI_PROJECT_DIR = $job.path
    $env:TAI_AGENT = $agent
    # Where an agent finds `tai delegate` (hand a task to another agent CLI).
    $env:TAI_DELEGATE = Join-Path $PSScriptRoot 'delegate.cmd'
    # Claude would retitle the window; the dashboard finds the focused pane by its "pane N" title.
    $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'
    # Windows Terminal mangles Claude's incremental fullscreen repaints after a pane resize (scroll and wheel stop working); repaint fully instead.
    $env:CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT = '1'
    # The CLI may retitle the window after a resize or move (Windows Terminal drops the pane's title when it
    # moves it); this thread, which runs while the CLI blocks the main one, puts the project name back.
    # Created last, right before the try, so the finally below always stops it.
    $titleThread = [powershell]::Create()
    [void]$titleThread.AddScript({
        param($t)
        while ($true) {
            Start-Sleep -Milliseconds 700
            try { if ([Console]::Title -ne $t) { [Console]::Title = $t } } catch { }
        }
    }).AddArgument([string]$job.name)
    [void]$titleThread.BeginInvoke()
    try {
        while ($true) {
            Write-Boot "slot ${Slot}: launching $agent"
            $env:TAI_AGENT = $agent
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Clear-AgentEnv
            Set-AgentEnv $agent
            # Account of this project for this agent (accounts.json); read again each launch so U + restart picks it up.
            $proj = @(Get-Projects) | Where-Object { (Get-NormPath $_.path) -eq (Get-NormPath $job.path) } | Select-Object -First 1
            $account = if ($proj) { Get-ProjectAccount $proj $agent } else { '' }
            Set-AgentAccountEnv $agent $account
            $exe = Get-AgentExe $agent
            $sflag = @(if (Get-AgentSettingsFlag $agent) { Get-AgentSettingsFlag $agent; $settings })
            $argv = @(Get-AgentArgs $agent 'resume' $job.name) + $sflag + @(Get-DelegateHintArgs $agent 'resume')
            & $exe @argv
            # Nothing to continue (new project): the command fails fast, so start a fresh session.
            # Skipped when the dashboard closed it on purpose.
            if ($LASTEXITCODE -ne 0 -and $clock.Elapsed.TotalSeconds -lt 3 -and -not (Test-Path $closeFlag)) {
                Write-Host 'No earlier conversation to continue (or it failed to load) - starting a new one.' -ForegroundColor Yellow
                $argv = @(Get-AgentArgs $agent 'fresh' $job.name) + $sflag + @(Get-DelegateHintArgs $agent 'fresh')
                & $exe @argv
            }
            # The dashboard closed this project on purpose: no menu.
            if ((Test-Path $closeFlag) -or (Test-Path $exitFlag)) { break }

            # The CLI ended by itself: offer to restart it or switch this project to another installed CLI.
            $choices = @("Restart $agent") + @($script:agents | Where-Object { $_ -ne $agent -and (Get-Command (Get-AgentExe $_) -ErrorAction SilentlyContinue) } | ForEach-Object { "Switch to $_" }) + 'Close project (and pane)'
            $idx = 0
            $pick = $null
            $menuSeconds = 3   # idle time before the pane closes
            while ($null -eq $pick) {
                Clear-Host
                Write-Host "$agent exited in $($job.name)" -ForegroundColor Yellow
                for ($n = 0; $n -lt $choices.Count; $n++) {
                    if ($n -eq $idx) { Write-Host "> $($choices[$n])" -ForegroundColor Black -BackgroundColor Gray } else { Write-Host "  $($choices[$n])" }
                }
                Write-Host 'Up/Down + Enter, or 1-' -NoNewline -ForegroundColor DarkGray
                Write-Host "$($choices.Count). Esc: close pane" -ForegroundColor DarkGray
                $wait = [Diagnostics.Stopwatch]::StartNew()
                $countRow = [Console]::CursorTop
                $shown = -1
                while (-not [Console]::KeyAvailable -and $wait.Elapsed.TotalSeconds -lt $menuSeconds) {
                    $left = [math]::Ceiling($menuSeconds - $wait.Elapsed.TotalSeconds)
                    if ($left -ne $shown) {
                        $shown = $left
                        [Console]::SetCursorPosition(0, $countRow)
                        Write-Host "Closing pane in $left s - press a key to choose  " -NoNewline -ForegroundColor Yellow
                    }
                    Start-Sleep -Milliseconds 100
                }
                if (-not [Console]::KeyAvailable) { $pick = -1; break }
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'UpArrow') { $idx = ($idx - 1 + $choices.Count) % $choices.Count }
                elseif ($key.Key -eq 'DownArrow') { $idx = ($idx + 1) % $choices.Count }
                elseif ($key.Key -eq 'Enter') { $pick = $idx }
                elseif ([string]$key.KeyChar -match '^[1-9]$' -and [int][string]$key.KeyChar -le $choices.Count) { $pick = [int][string]$key.KeyChar - 1 }
                else { $pick = -1 }
            }
            if ($pick -lt 0 -or $pick -eq $choices.Count - 1) {
                # No choice made or "Close project": close the pane too, unless it is the last one.
                if ((Get-PaneCount) -gt 1) { Set-Content $exitFlag 1 }
                break
            }
            if ($pick -gt 0) {
                $agent = ($choices[$pick] -replace '^Switch to ', '')
                Set-ProjectAgent $job.path $agent
                # Tell the dashboard what runs here now.
                try {
                    Write-SlotFile ([pscustomobject]@{ slot = $Slot; name = $job.name; path = $job.path; agent = $agent; pid = $PID; since = (Get-Date).ToString('o') } | ConvertTo-Json)
                } catch { }
            }
            Clear-Host
        }
    } finally {
        try { $titleThread.Stop(); $titleThread.Dispose() } catch { }
        Remove-Item $closeFlag -Force -ErrorAction SilentlyContinue
        Pop-Location
        Remove-Item $running -Force -ErrorAction SilentlyContinue
        # A crashed or killed session never sends SessionEnd, so drop its hook file here.
        Remove-Item (Join-Path $stateDir ('hook_' + (Get-StateKey $job.path) + '.json*')) -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $stateDir ('subs_' + (Get-StateKey $job.path) + '.txt')) -Force -ErrorAction SilentlyContinue
        Clear-AgentEnv
        Remove-Item Env:TAI_PROJECT_DIR, Env:TAI_AGENT, Env:TAI_DELEGATE,Env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE, Env:CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT -ErrorAction SilentlyContinue
    }
    # The dashboard closed this project with X and wants the pane gone too (never set for the last pane).
    # Exit ends a -NoExit host, so Windows Terminal closes the pane; the dashboard then fixes the layout.
    if (Test-Path $exitFlag) { [Environment]::Exit(0) }
}
