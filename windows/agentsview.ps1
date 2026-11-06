param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Agent, [string]$Account = '')
# Runs in its own wt tab (started by the dashboard's S key): tai's own agents screen for this project, on the
# project's account. Claude: background/live sessions from `claude agents --json`. Codex: tai's panes plus
# `codex queue` to message a session. agy: tai's own view of its panes (agy cannot list running sessions).
. (Join-Path $PSScriptRoot 'lib.ps1')
Set-Location -LiteralPath $Path
$stateDir = Join-Path $PSScriptRoot 'state'

function Read-Json($file) { try { Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }

function Get-PaneRows($wantAgent) {
    $rows = @()
    $states = @()   # read once, not per slot
    foreach ($g in Get-ChildItem $stateDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        if ($g.Name -like 'slot*' -or $g.Name -like 'hook_*') { continue }
        $st = Read-Json $g.FullName
        if ($st -and $st.agent -eq $wantAgent) { $states += , $st }
    }
    foreach ($f in Get-ChildItem $stateDir -Filter 'slot*.json' -ErrorAction SilentlyContinue) {
        $s = Read-Json $f.FullName
        if (-not $s -or $s.agent -ne $wantAgent) { continue }
        if ($s.pid -and -not (Test-SlotAlive $s.pid $s.since)) { continue }
        $state = 'running'; $model = ''; $quota = ''
        foreach ($st in $states) {
            try {
                if ((Get-NormPath $st.dir) -ne (Get-NormPath $s.path)) { continue }
                if ([datetime]$st.updated -lt [datetime]$s.since) { continue }
                if ($st.activity) { $state = [string]$st.activity }
                if ($st.model) { $model = [string]$st.model }
                $q = @($st.quotas | Where-Object { $null -ne $_ -and $null -ne $_.left } | Sort-Object left | Select-Object -First 1)
                if ($q.Count) { $quota = "$($q[0].name) $([math]::Round(100 - $q[0].left))% used" }
            } catch { continue }
        }
        $rows += , [pscustomobject]@{ Pane = $s.slot; Project = $s.name; State = $state; Model = $model; Quota = $quota }
    }
    $rows | Sort-Object Pane
}

function Get-ClaudeSessions {
    $raw = & claude agents --json --cwd $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    try { $j = ($raw -join "`n") | ConvertFrom-Json } catch { return @() }
    $out = @()
    foreach ($a in @($j)) {
        $st = if ($a.state) { [string]$a.state } elseif ($a.status) { [string]$a.status } else { 'live' }
        $age = ''
        if ($a.startedAt) {
            try {
                $span = (Get-Date) - [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$a.startedAt).LocalDateTime
                $age = if ($span.TotalHours -ge 1) { '{0}h{1}m' -f [int]$span.TotalHours, $span.Minutes } else { '{0}m' -f [int]$span.TotalMinutes }
            } catch { }
        }
        $id = if ($a.id) { [string]$a.id } else { '' }
        $out += , [pscustomobject]@{
            Id = $id; Name = [string]$a.name; State = $st; Kind = [string]$a.kind; Age = $age
            Waiting = [string]$a.waitingFor; Pid = $a.pid
        }
    }
    # blocked/waiting first
    $out | Sort-Object @{ Expression = { if ($_.State -in 'blocked', 'waiting') { 0 } else { 1 } } }, Name
}

function Get-StateColor($s) {
    switch -Regex ($s) { 'blocked|waiting' { 'Magenta' } 'working|busy' { 'Yellow' } 'failed' { 'Red' } 'done|idle|stopped' { 'DarkGray' } default { 'Gray' } }
}

function Confirm-Key($q) {
    Write-Host "$q [y/N] " -NoNewline -ForegroundColor Yellow
    $k = [Console]::ReadKey($true)
    Write-Host ''
    return ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y')
}

function Wait-Key {
    Write-Host ''
    Write-Host 'Press any key to return' -ForegroundColor DarkGray
    $null = [Console]::ReadKey($true)
}

# Waits up to $ms for a key; returns the key info or $null.
function Wait-Input($ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $end) {
        if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
        Start-Sleep -Milliseconds 80
    }
    return $null
}

function Show-Claude {
    $sel = 0
    $sessions = @(Get-ClaudeSessions); $next = Get-Date
    while ($true) {
        if ((Get-Date) -ge $next) { $sessions = @(Get-ClaudeSessions); $next = (Get-Date).AddSeconds(3) }
        if ($sel -ge $sessions.Count) { $sel = [math]::Max(0, $sessions.Count - 1) }
        Clear-Host
        Write-Host "claude agents - $Path" -ForegroundColor Cyan
        if ($Account) { Write-Host "account: $Account" -ForegroundColor DarkGray }
        Write-Host ''
        if (-not $sessions.Count) { Write-Host 'No Claude sessions for this project.' -ForegroundColor DarkGray }
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            $s = $sessions[$i]
            $mark = if ($i -eq $sel) { '>' } else { ' ' }
            $label = if ($s.Name) { $s.Name } elseif ($s.Id) { $s.Id } else { "pid $($s.Pid)" }
            $extra = if ($s.Waiting) { " waiting for $($s.Waiting)" } else { '' }
            $line = '{0} {1,-9} {2,-28} {3,-6} {4,-10}{5}' -f $mark, $s.State, $label, $s.Age, $s.Kind, $extra
            Write-Host $line -ForegroundColor (Get-StateColor $s.State)
        }
        Write-Host ''
        Write-Host 'up/down select  Enter attach  l logs  x stop  r refresh  o claude agents  q close' -ForegroundColor DarkGray
        $k = Wait-Input 500
        if (-not $k) { continue }
        $cur = if ($sessions.Count) { $sessions[$sel] } else { $null }
        switch ($k.Key) {
            'UpArrow'   { if ($sel -gt 0) { $sel-- } }
            'DownArrow' { if ($sel -lt $sessions.Count - 1) { $sel++ } }
            'Enter' {
                if ($cur -and $cur.Id) { Clear-Host; & claude attach $cur.Id; $next = Get-Date }
                elseif ($cur) { Write-Host 'Live (non-background) sessions run in their own pane; only background ones can be attached.' -ForegroundColor Yellow; Wait-Key }
            }
            'L' { if ($cur -and $cur.Id) { Clear-Host; & claude logs $cur.Id; Wait-Key } }
            'X' {
                if ($cur -and $cur.Id -and (Confirm-Key "Stop $($cur.Id)?")) { & claude stop $cur.Id | Out-Host; $next = Get-Date; Start-Sleep -Milliseconds 400 }
            }
            'R' { $next = Get-Date }
            'O' { Clear-Host; & claude agents --cwd $Path; $next = Get-Date }
            'Q' { return }
            'Escape' { return }
        }
    }
}

function Show-Panes($title, $wantAgent, $openKeyHint) {
    $rows = @(Get-PaneRows $wantAgent)
    Clear-Host
    Write-Host $title -ForegroundColor Cyan
    Write-Host ''
    if ($rows.Count) { ($rows | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host }
    else { Write-Host "No $wantAgent pane is running." -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host $openKeyHint -ForegroundColor DarkGray
}

function Show-Codex {
    while ($true) {
        Show-Panes "codex panes running in tai - $Path" 'codex' 'm message a session (codex queue)  o codex agents  q close  (refreshes every 2 s)'
        $k = Wait-Input 2000
        if (-not $k) { continue }
        switch ($k.Key) {
            'Q' { return }
            'Escape' { return }
            'O' { Clear-Host; & codex agents --cd $Path }
            'M' {
                Write-Host ''
                $thread = Read-Host 'Session id or exact name (blank cancels)'
                if (-not $thread) { continue }
                $msg = Read-Host 'Message'
                if (-not $msg) { continue }
                & codex queue --thread $thread --message $msg | Out-Host
                Wait-Key
            }
        }
    }
}

function Show-Agy {
    while ($true) {
        Show-Panes 'agy sessions running in tai (agy has no command that lists them)' 'agy' 'o agy agent (definitions)  q close  (refreshes every 2 s)'
        $k = Wait-Input 2000
        if (-not $k) { continue }
        switch ($k.Key) {
            'Q' { return }
            'Escape' { return }
            'O' { Clear-Host; & agy agent; Wait-Key }
        }
    }
}

Set-AgentAccountEnv $Agent $Account
switch ($Agent) {
    'claude' { Show-Claude }
    'codex'  { Show-Codex }
    'agy'    { Show-Agy }
    default  { Write-Host "$Agent has no agents screen" -ForegroundColor Yellow; Wait-Key }
}
