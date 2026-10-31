# Always-open left pane: account usage plus every project. Move with Up/Down,
# Enter focuses the project's pane, or opens it in the first free pane.
. (Join-Path $PSScriptRoot 'lib.ps1')

$stateDir = Join-Path $PSScriptRoot 'state'
$usageFile = Join-Path $PSScriptRoot 'usage.json'
$alive = Join-Path $stateDir 'dashboard.alive'
$maxSlots = 9
# Icons built from code points so the script stays plain ASCII (PS 5.1 misreads UTF-8 without a BOM).
$icon = @{
    hourly  = [string][char]0x23F1   # stopwatch
    weekly  = [string][char]0x25A6   # grid
    reset   = [string][char]0x21BB   # clockwise arrow
    model   = [string][char]0x25C6   # diamond
    effort  = [string][char]0x2699   # gear
    ctx     = [string][char]0x25E7   # half square
    compact = [string][char]0x21E3   # down dashed arrow
    shell   = [string][char]0x25B6   # play triangle
    sub     = [string][char]0x25C8   # diamond in diamond
    changed = [string][char]0x25CF   # filled dot
    ahead   = [string][char]0x2191   # up arrow
    behind  = [string][char]0x2193   # down arrow
    wtree   = [string][char]0x2514   # tree corner
    ok      = [string][char]0x2713   # check mark
}
$busySeconds = 20   # transcript written within this window = "working"
New-Item -ItemType Directory -Force $stateDir | Out-Null

function Bar($pct) {
    $filled = [math]::Max(0, [math]::Min(10, [int][math]::Round(($pct / 100) * 10)))
    ([string][char]0x2588) * $filled + ([string][char]0x2591) * (10 - $filled)
}

function Age($ts) {
    $s = [int]((Get-Date) - $ts).TotalSeconds
    if ($s -lt 60) { return "${s}s" }
    if ($s -lt 3600) { return '{0}m' -f [int]($s / 60) }
    return '{0}h' -f [int]($s / 3600)
}

function UsageLine($label, $limit) {
    if ($null -eq $limit -or $null -eq $limit.used_percentage) { return "$label --" }
    '{0} {1} {2,3:N0}%' -f $label, (Bar $limit.used_percentage), $limit.used_percentage
}

# Green under 70%, yellow to 90%, red above: how close you are to the limit.
function UsageColor($limit) {
    if ($null -eq $limit -or $null -eq $limit.used_percentage) { return 'White' }
    if ($limit.used_percentage -ge 90) { return 'Red' }
    if ($limit.used_percentage -ge 70) { return 'Yellow' }
    return 'Green'
}

function ResetLine($limit) {
    if ($null -eq $limit -or -not $limit.resets_at) { return '' }
    $t = [DateTimeOffset]::FromUnixTimeSeconds([long]$limit.resets_at).LocalDateTime
    "  $($icon.reset) " + $t.ToString('ddd HH:mm')
}

# Codex 5h / weekly limits: the newest rate_limits report in Codex's own session logs (token_count events),
# read from the tail of the most recently written rollout file. Cached 10 s; $null when nothing found.
$script:codexUsage = $null
$script:codexStamp = [datetime]::MinValue
$script:codexCtxByDir = @{}
function Get-CodexUsage {
    if (((Get-Date) - $script:codexStamp).TotalSeconds -lt 30) { return $script:codexUsage }
    $script:codexStamp = Get-Date
    try {
        $root = Join-Path $env:USERPROFILE '.codex\sessions'
        $files = @(Get-ChildItem $root -Recurse -Filter 'rollout-*.jsonl' -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 20)
        $byDir = @{}
        $gotLimits = $false
        $script:codexUsage = $null
        foreach ($f in $files) {
            $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                $len = [math]::Min($fs.Length, 400000)
                [void]$fs.Seek(-$len, 'End')
                $buf = New-Object byte[] $len
                [void]$fs.Read($buf, 0, $len)
                # The first line (session_meta) holds the project folder the session ran in.
                $hlen = [int][math]::Min($fs.Length, 3000)
                $hbuf = New-Object byte[] $hlen
                [void]$fs.Seek(0, 'Begin')
                [void]$fs.Read($hbuf, 0, $hlen)
            } finally { $fs.Dispose() }
            # Context per project folder: newest log wins (files are newest first).
            $txt = [Text.Encoding]::UTF8.GetString($buf)
            $cwd = [regex]::Match([Text.Encoding]::UTF8.GetString($hbuf), '"cwd":"((?:[^"\\]|\\.)*)"')
            $c = [regex]::Matches($txt, '"last_token_usage":\{[^}]*?"total_tokens":(\d+)\},"model_context_window":(\d+)')
            if ($cwd.Success -and $c.Count -and [double]$c[$c.Count - 1].Groups[2].Value -gt 0) {
                $key = Get-NormPath ($cwd.Groups[1].Value -replace '\\\\', '\')
                if (-not $byDir.ContainsKey($key)) {
                    $cg = $c[$c.Count - 1].Groups
                    $byDir[$key] = [math]::Min(100, [math]::Round(100 * [double]$cg[1].Value / [double]$cg[2].Value))
                }
            }
            if ($script:codexUsage -and $gotLimits) { continue }
            $m = [regex]::Matches($txt, '"rate_limits":\{.*?"primary":\{"used_percent":([\d.]+),"window_minutes":(\d+),"resets_at":(\d+)\},"secondary":(?:null|\{"used_percent":([\d.]+),"window_minutes":(\d+),"resets_at":(\d+)\})')
            if ($m.Count) {
                $l = $m[$m.Count - 1].Groups
                # A window whose reset time has passed describes an old period: don't show it as current.
                $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $hasSec = $l[4].Success
                if ([long]$l[3].Value -lt $nowUnix -and (-not $hasSec -or [long]$l[6].Value -lt $nowUnix)) { continue }
                # Free plans have one 30-day window and no secondary; label each window by its length.
                function WinLabel($min) { $min = [int]$min; if ($min -ge 1440) { '{0}d' -f [math]::Round($min / 1440) } else { '{0}h' -f [math]::Round($min / 60) } }
                $wins = @([pscustomobject]@{ label = (WinLabel $l[2].Value); used_percentage = [double]$l[1].Value; resets_at = [long]$l[3].Value })
                if ($hasSec) { $wins += [pscustomobject]@{ label = (WinLabel $l[5].Value); used_percentage = [double]$l[4].Value; resets_at = [long]$l[6].Value } }
                $script:codexUsage = $wins
                $gotLimits = $true
            }
        }
        $script:codexCtxByDir = $byDir
    } catch { }
    return $script:codexUsage
}

# Git branch and worktree of a project folder, cached 5 s (git is quick; only the highlighted project is asked).
$gitCache = @{}
function Get-GitInfo($path, [switch]$Cached) {
    $key = Get-NormPath $path
    $c = $gitCache[$key]
    if ($Cached) { if ($c) { return $c.info } else { return $null } }
    if ($c -and ((Get-Date) - $c.time).TotalSeconds -lt 10) { return $c.info }
    $info = $null
    $top = git -C $path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) {
        $branch = git -C $path branch --show-current 2>$null
        if (-not $branch) { $branch = 'detached ' + (git -C $path rev-parse --short HEAD 2>$null) }
        $gitDir = [string](git -C $path rev-parse --git-dir 2>$null)
        $count = 0
        foreach ($l in (git -C $path worktree list --porcelain 2>$null)) { if ($l -like 'worktree *') { $count++ } }
        $changed = 0; $new = 0
        foreach ($l in (git -C $path status --porcelain 2>$null)) { if ($l.StartsWith('??')) { $new++ } else { $changed++ } }
        # Commits not yet pushed / not yet pulled, against the upstream branch (null when none is set).
        $ahead = $null; $behind = $null
        $lr = [string](git -C $path rev-list --left-right --count '@{u}...HEAD' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $lr) { $f = $lr.Trim() -split '\s+'; $behind = [int]$f[0]; $ahead = [int]$f[1] }
        $info = @{
            branch  = $branch
            tree    = Split-Path $top -Leaf
            linked  = [bool]($gitDir -match '[/\\]worktrees[/\\]')
            count   = $count
            changed = $changed
            new     = $new
            ahead   = $ahead
            behind  = $behind
        }
    }
    $gitCache[$key] = @{ time = Get-Date; info = $info }
    $info
}

# GitHub stars/forks/open issues/open PRs via `gh` in a background job (refreshed every 5 min), so the UI never waits.
$ghCache = @{}
function Get-GhStats($path, [switch]$NoStart) {
    $key = Get-NormPath $path
    $c = $ghCache[$key]
    if (-not $c) { $c = @{ time = [datetime]::MinValue; text = $null; job = $null }; $ghCache[$key] = $c }
    if ($c.job -and $c.job.State -ne 'Running') {
        $out = @(Receive-Job $c.job -ErrorAction SilentlyContinue)
        Remove-Job $c.job -Force
        $c.job = $null
        $c.time = Get-Date
        $f = if ($out.Count) { ([string]$out[0]).Split("`t") } else { @() }
        $c.text = if ($f.Count -ge 4) { ('issues {0}  PRs {1}' -f $f[2], $f[3]) } else { 'no GitHub repo' }
    }
    # One lookup at a time, so many projects don't spawn many gh processes at once.
    $busy = $false
    foreach ($o in $ghCache.Values) { if ($o.job) { $busy = $true } }
    if (-not $NoStart -and -not $busy -and -not $c.job -and ((Get-Date) - $c.time).TotalSeconds -ge 300) {
        $c.time = Get-Date
        $c.job = Start-Job -ArgumentList $path -ScriptBlock {
            param($d)
            Set-Location -LiteralPath $d
            $nwo = gh repo view --json nameWithOwner --jq .nameWithOwner 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $nwo) { return }
            $owner, $name = $nwo.Split('/')
            $q = 'query($o:String!,$n:String!){repository(owner:$o,name:$n){stargazerCount forkCount issues(states:OPEN){totalCount} pullRequests(states:OPEN){totalCount}}}'
            gh api graphql -f query=$q -F o=$owner -F n=$name --jq '.data.repository | [.stargazerCount,.forkCount,.issues.totalCount,.pullRequests.totalCount] | @tsv' 2>$null
        }
    }
    if ($c.text) { $c.text } else { 'GitHub: loading...' }
}

# Compact git/GitHub summary shown under every project row, from caches only (Refresh-RepoInfo fills them).
function Get-RepoLine($path) {
    $g = Get-GitInfo $path -Cached
    if (-not $g) { return '' }
    $t = $g.branch
    if ($g.linked) { $t += " $($icon.wtree)wt" }
    $n = $g.changed + $g.new
    $p = @()
    if ($n) { $p += "$($icon.changed)$n" }
    if ($g.ahead) { $p += "$($icon.ahead)$($g.ahead)" }
    if ($g.behind) { $p += "$($icon.behind)$($g.behind)" }
    $t += '  ' + $(if ($p.Count) { $p -join ' ' } else { $icon.ok })
    $gh = Get-GhStats $path -NoStart
    if ($gh -and $gh -notlike 'GitHub:*' -and $gh -ne 'no GitHub repo') { $t += '  ' + $gh }
    $t
}

# Refresh one stale project per frame (git) and let one GitHub lookup run, so a long list never stalls the UI.
function Refresh-RepoInfo($projects) {
    # Git runs only on idle redraws (not while a key is being handled) and at most every 10 s per project.
    if (-not $script:keyRedraw) {
        foreach ($p in $projects) {
            $c = $gitCache[(Get-NormPath $p.path)]
            if (-not $c -or ((Get-Date) - $c.time).TotalSeconds -ge 10) { $null = Get-GitInfo $p.path; break }
        }
    }
    foreach ($p in $projects) {
        $c = $ghCache[(Get-NormPath $p.path)]
        if ($c -and $c.job) { $null = Get-GhStats $p.path -NoStart; continue }
        if (-not $c -or ((Get-Date) - $c.time).TotalSeconds -ge 300) { if ($gitCache[(Get-NormPath $p.path)].info) { $null = Get-GhStats $p.path; break } }
    }
}

# Panes in use, keyed by normalized project path. Includes panes still starting up.
function Get-Slots {
    $slots = @{}
    # A file can be mid-write or deleted between listing and reading; skip it and retry next refresh.
    foreach ($f in Get-ChildItem $stateDir -Filter 'slot*.json' -ErrorAction SilentlyContinue) {
        try {
            $s = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            # Pane window closed without exiting Claude: its file is stale. (Files from older panes have no pid.)
            if ($s.pid -and -not (Test-SlotAlive $s.pid $s.since)) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; continue }
            $slots[(Get-NormPath $s.path)] = $s
        } catch { continue }
    }
    foreach ($f in Get-ChildItem $stateDir -Filter 'slot*.assign' -ErrorAction SilentlyContinue) {
        try {
            $s = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            $n = [int]($f.BaseName -replace '\D', '')
            if ($slots.ContainsKey((Get-NormPath $s.path))) { continue }   # keep the running entry (has the pid)
            $slots[(Get-NormPath $s.path)] = [pscustomobject]@{ slot = $n; name = $s.name; path = $s.path; agent = $s.agent; since = (Get-Date).ToString('o') }
        } catch { continue }
    }
    return $slots
}

# Latest status-line report per project directory (model, context, cost, transcript).
function Get-Statuses {
    $statuses = @{}
    foreach ($f in Get-ChildItem $stateDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        if ($f.Name -like 'slot*' -or $f.Name -like 'hook_*') { continue }
        try {
            $s = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            $statuses[(Get-NormPath $s.dir)] = $s
        } catch { continue }
    }
    return $statuses
}

# Latest hook report per project directory (working / waiting / done), written by hook.ps1.
function Get-Hooks {
    $hooks = @{}
    foreach ($f in Get-ChildItem $stateDir -Filter 'hook_*.json' -ErrorAction SilentlyContinue) {
        try {
            $h = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            $hooks[(Get-NormPath $h.dir)] = $h
        } catch { continue }
    }
    return $hooks
}

# Windows toast (falls back to a beep if the WinRT types are unavailable).
function Send-Toast($title, $text) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [Security.SecurityElement]::Escape($title); $b = [Security.SecurityElement]::Escape($text)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastText02'><text id='1'>$t</text><text id='2'>$b</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch { try { [Console]::Beep(880, 150) } catch { } }
}

# Toast once per transition of an open project to "waiting" (hook status). The first call only records
# what is already waiting, so starting the dashboard does not notify for old prompts.
# The T key toggles toasts; the flag file keeps the choice across restarts. While off, waiting states are still
# recorded, so turning toasts back on does not announce prompts that are already waiting.
$script:toastOff = Join-Path $stateDir 'toast.off'
$script:notified = @{}
$script:notifySeeded = $false
function Notify-Waiting($projects) {
    $slots = Get-Slots
    $hooks = Get-Hooks
    foreach ($p in $projects) {
        $key = Get-NormPath $p.path
        $slot = $slots[$key]; $hk = $hooks[$key]
        if (-not $slot -or -not $hk -or $hk.status -ne 'waiting') { $script:notified.Remove($key); continue }
        if ([datetime]$hk.updated -lt [datetime]$slot.since) { continue }
        $stamp = [string]$hk.updated
        if ($script:notified[$key] -eq $stamp) { continue }
        $script:notified[$key] = $stamp
        if ($script:notifySeeded -and -not (Test-Path $script:toastOff)) { Send-Toast "$($p.name) needs you" 'Waiting for input in tai' }
    }
    $script:notifySeeded = $true
}

# Sub-agents running inside a project's session (SubagentStart/SubagentStop hooks, see hook.ps1).
# Entries from before the pane started, or older than half an hour (a stop that never came), are ignored.
function Get-SubCount($project, $slot) {
    if (-not $slot) { return 0 }
    $file = Join-Path $stateDir ('subs_' + (Get-StateKey $project.path) + '.txt')
    if (-not (Test-Path $file)) { return 0 }
    $n = 0
    try {
        foreach ($line in Get-Content $file -ErrorAction Stop) {
            $f = $line -split "`t"
            if ($f.Count -lt 3) { continue }
            $t = [datetime]$f[2]
            if ($t -ge [datetime]$slot.since -and ((Get-Date) - $t).TotalMinutes -lt 30) { $n++ }
        }
    } catch { }
    return $n
}

# Shells (bash / powershell) running under each pane's Claude, e.g. background commands, keyed by
# slot number. Statusline and hook helpers are shells too but live well under a second; skip them.
# The process snapshot is slow, so it is refreshed at most every few seconds.
$script:shellCache = @{}
$script:shellStamp = [datetime]::MinValue

# Ids of the shells under the CLI processes $roots: direct children, plus children of the CLI's non-shell
# helpers (node wrappers). Shells running statusline.ps1 / hook.ps1 are left out.
function Get-ShellPids($all, $roots) {
    $cliIds = @($roots)
    $cliIds += @($all | Where-Object { $cliIds -contains $_.ParentProcessId -and $_.Name -notmatch '^(bash|powershell|pwsh|conhost)\.exe$' } | ForEach-Object { $_.ProcessId })
    return @($all | Where-Object {
        $cliIds -contains $_.ParentProcessId -and
        $_.Name -match '^(bash|powershell|pwsh)\.exe$' -and
        $_.CommandLine -notmatch 'statusline\.ps1|hook\.ps1'
    } | ForEach-Object { $_.ProcessId })
}
function Get-ShellCounts($slots) {
    # A redraw caused by a keypress never waits for the slow snapshot; the next timed redraw refreshes it.
    if ($script:keyRedraw -or ((Get-Date) - $script:shellStamp).TotalSeconds -lt 6) { return $script:shellCache }
    $counts = @{}
    try {
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop)
        foreach ($s in $slots.Values) {
            if (-not $s.pid) { continue }
            # Whatever CLI runs in the pane (claude, codex, agy) is a child of the slot's PowerShell; node-based
            # ones can have a wrapper process in between, so non-shell children of the CLI count as part of it too.
            $roots = @($all | Where-Object { $_.ParentProcessId -eq $s.pid -and $_.Name -ne 'conhost.exe' } | ForEach-Object { $_.ProcessId })
            $ids = @{}
            foreach ($id in (Get-ShellPids $all $roots)) { $ids[[int]$id] = 1 }
            $counts[[int]$s.slot] = $ids
        }
        # Sessions hosted by Claude's background daemon run outside the pane's process tree. hook.ps1 maps each
        # session id to its folder (state\sessions.txt); count the shells under those sessions for the matching pane.
        $mapFile = Join-Path $stateDir 'sessions.txt'
        if (Test-Path $mapFile) {
            $bySlot = @{}
            foreach ($s in $slots.GetEnumerator()) { $bySlot[[string]$s.Key] = [int]$s.Value.slot }
            foreach ($line in @(Get-Content $mapFile -ErrorAction SilentlyContinue)) {
                $f = $line -split "`t"
                if ($f.Count -lt 3) { continue }
                $cwd = Get-NormPath $f[1]
                $best = $null
                foreach ($k in $bySlot.Keys) {
                    if (($cwd -eq $k -or $cwd.StartsWith($k + '\') -or $cwd.StartsWith($k + '/')) -and (-not $best -or $k.Length -gt $best.Length)) { $best = $k }
                }
                if (-not $best -or -not $counts.ContainsKey($bySlot[$best])) { continue }
                $sid = $f[0]
                $sess = @($all | Where-Object { $_.Name -eq 'claude.exe' -and $_.CommandLine -match '--session-id' -and $_.CommandLine -like "*$sid*" -and $_.CommandLine -notmatch '--bg-pty-host' })
                if (-not $sess.Count) { continue }
                foreach ($id in (Get-ShellPids $all @($sess | ForEach-Object { $_.ProcessId }))) { $counts[$bySlot[$best]][[int]$id] = 1 }
            }
        }
        foreach ($k in @($counts.Keys)) { $counts[$k] = $counts[$k].Count }
    } catch { return $script:shellCache }
    $script:shellCache = $counts
    $script:shellStamp = Get-Date
    return $counts
}

function Open-Project($project, $slots, $batch = $null) {
    $key = Get-NormPath $project.path
    if ($slots.ContainsKey($key)) { if ($null -ne $batch) { return "$($project.name) already open" }; Focus-Slot ([int]$slots[$key].slot); return "$($project.name) -> pane $($slots[$key].slot)" }
    if (-not (Test-Path $project.path)) { return "Folder missing: $($project.path)" }
    $taken = @($slots.Values | ForEach-Object { [int]$_.slot })
    $paneCount = Get-PaneCount
    # Slot numbers can have gaps once panes were closed, so take them from the layout.
    $layout = @(Get-Layout $paneCount)
    $free = $layout | Sort-Object | Where-Object { $taken -notcontains $_ } | Select-Object -First 1
    $create = $false
    if (-not $free) {
        if ($paneCount -ge $maxSlots) { return "All $maxSlots panes busy. Close a project first." }
        if (-not (Get-NextSplit (Get-Rects $paneCount))) { return "Window fits only $paneCount panes. Enlarge it or close a project." }
        # Every pane is in use: split a new one off the layout, numbered with the lowest unused slot.
        $free = 1..$maxSlots | Where-Object { $layout -notcontains $_ } | Select-Object -First 1
        $create = $true
    }
    # Write via a temp name so the slot never reads a half-written assignment.
    $assignFile = Join-Path $stateDir "slot$free.assign"
    [pscustomobject]@{ name = $project.name; path = $project.path; agent = (Get-Agent $project) } |
        ConvertTo-Json | Set-Content "$assignFile.tmp" -Encoding utf8
    Move-Item "$assignFile.tmp" $assignFile -Force
    # In a batch (session restore) the panes are only collected; the caller starts them all at once.
    if ($create) { [void](New-Pane $free $batch) } elseif ($null -eq $batch) { Focus-Slot $free }
    return "Opening $($project.name) in pane $free"
}

# Stop Claude in the project's pane. With other panes open, slot.ps1 then exits so the pane closes
# (the main loop fixes the layout); the last pane goes back to its empty prompt instead.
function Close-Project($project, $slots) {
    $slot = $slots[(Get-NormPath $project.path)]
    if (-not $slot) { return "$($project.name) is not open" }
    if (-not $slot.pid) { return "$($project.name) is still starting; try again" }
    # A stale slot file can hold a dead pid that Windows has reused; only trust a PowerShell
    # process that started before the slot did.
    if (-not (Test-SlotAlive $slot.pid $slot.since)) { return "Pane $($slot.slot) is not running (stale); restart tai" }
    try { Set-Content (Join-Path $stateDir "slot$($slot.slot).close") (Get-Date).ToString('o') -ErrorAction Stop }
    catch { return "Could not close: $($_.Exception.Message)" }
    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($slot.pid)" -ErrorAction SilentlyContinue)
    if ($kids.Count -eq 0) { return "Nothing running in pane $($slot.slot); try again" }
    $exitFlag = Join-Path $stateDir "slot$($slot.slot).exit"
    $closePane = (Get-PaneCount) -gt 1
    if ($closePane) { Set-Content $exitFlag (Get-Date).ToString('o') }
    $failed = $false
    foreach ($k in $kids) {
        & taskkill.exe /PID $k.ProcessId /T /F *> $null
        if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $k.ProcessId -ErrorAction SilentlyContinue)) { $failed = $true }
    }
    if ($failed) { Remove-Item $exitFlag -Force -ErrorAction SilentlyContinue; return "Could not stop $($project.name)" }
    if ($closePane) { return "Closed $($project.name) and pane $($slot.slot)" }
    return "Closed $($project.name) (pane $($slot.slot))"
}

# Projects grouped by agent (claude, codex, agy) so each agent's info sits together; list order within a group is kept.
function Get-SortedProjects {
    $all = @(Get-Projects)
    $keyed = @()
    for ($i = 0; $i -lt $all.Count; $i++) {
        $keyed += [pscustomobject]@{ p = $all[$i]; a = [array]::IndexOf($script:agents, (Get-Agent $all[$i])); i = $i }
    }
    @($keyed | Sort-Object a, i | ForEach-Object { $_.p })
}

# Shift+Up/Down: swap the project with its neighbour in the same agent group and save the new list order.
function Move-ProjectOrder($projects, $cursor, $delta) {
    $to = $cursor + $delta
    if ($to -lt 0 -or $to -ge $projects.Count) { return $false }
    if ((Get-Agent $projects[$to]) -ne (Get-Agent $projects[$cursor])) { return $false }
    $all = @(Get-Projects)
    $a = -1; $b = -1
    for ($i = 0; $i -lt $all.Count; $i++) {
        $k = Get-NormPath $all[$i].path
        if ($k -eq (Get-NormPath $projects[$cursor].path)) { $a = $i }
        elseif ($k -eq (Get-NormPath $projects[$to].path)) { $b = $i }
    }
    if ($a -lt 0 -or $b -lt 0 -or $a -eq $b) { return $false }
    $t = $all[$a]; $all[$a] = $all[$b]; $all[$b] = $t
    Save-Projects $all
    return $true
}

function Draw($projects, $cursor, $message) {
    Refresh-RepoInfo $projects
    $slots = Get-Slots
    $statuses = Get-Statuses
    $hooks = Get-Hooks
    $shells = Get-ShellCounts $slots
    $width = [Console]::WindowWidth - 1
    $height = [Console]::WindowHeight - 1
    $lines = @()   # each: text, fg, bg

    $u = $null
    try { if (Test-Path $usageFile) { $u = Get-Content $usageFile -Raw -ErrorAction Stop | ConvertFrom-Json } } catch { $u = $null }
    # Usage rows shown under each agent's heading: Claude's from usage.json, Codex's from its session logs,
    # agy's lowest model quota from its status line.
    function UsageLinesFor($agent) {
        $out = @()
        switch ($agent) {
            'claude' {
                if ($u) {
                    $out += , @(((UsageLine "$($icon.hourly) 5h" $u.five_hour) + (ResetLine $u.five_hour)), (UsageColor $u.five_hour), $null)
                    $out += , @(((UsageLine "$($icon.weekly) 7d" $u.seven_day) + (ResetLine $u.seven_day)), (UsageColor $u.seven_day), $null)
                } else {
                    $out += , @('5h/7d usage shown after', 'DarkGray', $null)
                    $out += , @('the first reply in a pane', 'DarkGray', $null)
                }
            }
            'codex' {
                $cu = Get-CodexUsage
                if ($cu) {
                    foreach ($w in $cu) {
                        $ic = if ($w.label -eq '5h') { $icon.hourly } else { $icon.weekly }
                        $out += , @(((UsageLine "$ic $($w.label)" $w) + (ResetLine $w)), (UsageColor $w), $null)
                    }
                } else {
                    $out += , @('no usage yet', 'DarkGray', $null)
                }
            }
            'agy' {
                # One line per model: the lowest remaining quota any agy pane reports for it (shown as used).
                $perModel = [ordered]@{}
                foreach ($s in $statuses.Values) {
                    if ($s.agent -ne 'agy') { continue }
                    foreach ($mq in @($s.quotas)) {
                        if ($null -eq $mq -or $null -eq $mq.left) { continue }
                        if (-not $perModel.Contains($mq.name) -or $mq.left -lt $perModel[$mq.name]) { $perModel[$mq.name] = [double]$mq.left }
                    }
                }
                foreach ($name in $perModel.Keys) {
                    $q = $perModel[$name]
                    $nice = ($name -replace '-weekly$', ' 7d' -replace '-(\d+h)$', ' $1')   # "3p-5h" -> "3p 5h", "gemini-weekly" -> "gemini 7d"
                    $short = if ($nice.Length -gt 10) { $nice.Substring(0, 9) + '~' } else { $nice }
                    # Same bar as Claude/Codex: percent used (agy reports what is left).
                    $w = [pscustomobject]@{ used_percentage = [math]::Max(0, [math]::Min(100, 100 - $q)) }
                    $out += , @((UsageLine ('{0,-10}' -f $short) $w), (UsageColor $w), $null)
                }
                if (-not $perModel.Count) { $out += , @('no quota yet', 'DarkGray', $null) }
            }
        }
        return , $out
    }
    # Bottom block: one headed section per agent.
    $usageBlock = @()
    foreach ($a in 'claude', 'codex', 'agy') {
        $usageBlock += , @("-- $a --", 'Cyan', $null)
        foreach ($ul in (UsageLinesFor $a)) { $usageBlock += , $ul }
    }

    # Reserve room for the detail block and key help; scroll the project list to fit.
    $detailHeight = 9 + $usageBlock.Count   # separator, path, model/hint, message (4), usage block, keys section (5)
    $listHeight = [math]::Max(3, $height + 1 - $lines.Count - $detailHeight)
    # Open projects take three rows (model and effort, then context and compaction), so scroll by rows.
    function IsGroupStart($i) { $i -eq 0 -or (Get-Agent $projects[$i]) -ne (Get-Agent $projects[$i - 1]) }
    # Claude always has model/context rows; other agents only once they report a model (agy status line, Codex hooks).
    function HasInfo($i) {
        $key = Get-NormPath $projects[$i].path
        $s = $slots[$key]
        if (-not $s) { return $false }
        $a = Get-Agent $(if ($s.agent) { $s } else { $projects[$i] })
        if ($a -eq 'claude') { return $true }
        $t = $statuses[$key]
        return [bool]($t -and $t.agent -eq $a -and $t.model)
    }
    function RowHeight($i) {
        $rows = if (HasInfo $i) { 4 } else { 2 }   # main row, optional model/context rows, repo row
        if (IsGroupStart $i) { $rows += 1 }   # agent heading
        $rows
    }
    $top = $cursor
    $used = if ($projects.Count) { RowHeight $cursor } else { 0 }
    while ($top -gt 0 -and ($used + (RowHeight ($top - 1))) -le $listHeight) { $top--; $used += RowHeight $top }
    $rowsLeft = $listHeight

    for ($i = $top; $i -lt $projects.Count; $i++) {
        # The first visible row always gets its heading, even mid-group (RowHeight only counts group starts).
        $extra = if ($i -eq $top -and -not (IsGroupStart $i)) { 1 } else { 0 }
        if ($rowsLeft -lt ((RowHeight $i) + $extra)) { break }
        $rowsLeft -= (RowHeight $i) + $extra
        $p = $projects[$i]
        if ((IsGroupStart $i) -or $i -eq $top) {
            $lines += , @("-- $((Get-Agent $p)) --", 'Cyan', $null)
        }
        $key = Get-NormPath $p.path
        $slot = $slots[$key]
        $st = $statuses[$key]
        $state = 'closed'; $slotText = ''; $fg = 'DarkGray'; $mtime = $null
        $agent = Get-Agent $p
        if ($slot -and $slot.agent) { $agent = Get-Agent $slot }
        if ($slot) {
            $slotText = "[$($slot.slot)]"
            $state = 'starting'; $fg = 'Green'
            if ($st -and [datetime]$st.updated -ge [datetime]$slot.since) {
                $mtime = $null
                if ($st.transcript -and (Test-Path $st.transcript)) { $mtime = (Get-Item $st.transcript).LastWriteTime }
                if ($mtime -and ((Get-Date) - $mtime).TotalSeconds -lt $busySeconds) { $state = 'working'; $fg = 'Yellow' }
                elseif ($mtime) { $state = 'idle ' + (Age $mtime) }
                else { $state = 'idle' }
            }
            # agy's status line reports its own activity (agy-statusline.ps1).
            if ($agent -ne 'claude' -and $st -and $st.agent -eq $agent -and $st.activity -and [datetime]$st.updated -ge [datetime]$slot.since) {
                switch ($st.activity) {
                    'working' { $state = 'working'; $fg = 'Yellow' }
                    'waiting' { $state = '! waiting'; $fg = 'Magenta' }
                    'idle'    { $state = 'idle ' + (Age ([datetime]$st.updated)); $fg = 'Green' }
                }
            }
            # Hooks know exactly when Claude is working, waiting on you, or finished; prefer them.
            $hk = $hooks[$key]
            if ($hk -and [datetime]$hk.updated -ge [datetime]$slot.since) {
                switch ($hk.status) {
                    'working' { $state = 'working'; $fg = 'Yellow' }
                    'waiting' {
                        # No hook fires when you answer a prompt; a transcript write after it means Claude resumed.
                        $resumed = $mtime -and ($mtime -gt ([datetime]$hk.updated).AddSeconds(2))
                        if ($resumed) { $state = 'working'; $fg = 'Yellow' } else { $state = '! waiting'; $fg = 'Magenta' }
                    }
                    'done'    { $state = 'done ' + (Age ([datetime]$hk.updated)); $fg = 'Cyan' }
                }
            }
        }
        $pointer = if ($i -eq $cursor) { '>' } else { ' ' }
        $shown = if ($p.name.Length -gt 12) { $p.name.Substring(0, 11) + '~' } else { $p.name }
        # An agent that reports nothing (agy/Codex without their hooks set up) just shows running.
        if ($slot -and $agent -ne 'claude' -and $state -eq 'starting') { $state = 'running'; $fg = 'Green' }
        $tag = if ($agent -eq 'claude') { '' } else { " ($agent)" }
        # Agents without a model/context block have no third row for the shell count, so it goes on the main row.
        $subN = Get-SubCount $p $slot
        $rowShells = if ($slot -and -not (HasInfo $i) -and $shells[[int]$slot.slot]) { " $($icon.shell) $($shells[[int]$slot.slot]) sh" } else { '' }
        # Sub-agents sit beside the shell count: on the third row when there is one, else on the main row.
        $subText = if ($subN) { "  $($icon.sub) $subN" } else { '' }
        if (-not (HasInfo $i)) { $rowShells += $subText }
        $text = '{0} {1,-12} {2,-3} {3}{4}{5}' -f $pointer, $shown, $slotText, $state, $tag, $rowShells
        # Selected row is white on blue (dark magenta when it needs you) so it stays readable.
        $bg = if ($i -ne $cursor) { $null } elseif ($fg -eq 'Magenta') { 'DarkMagenta' } else { 'DarkBlue' }
        $lines += , @($text, $(if ($i -eq $cursor) { 'White' } else { $fg }), $bg)
        if (HasInfo $i) {
            $m = "$($icon.model) " + $(if ($st -and $st.model) { [string]$st.model } else { '--' })
            if ($st -and $st.effort) { $m += "  $($icon.effort) $($st.effort)" }
            $lines += , @("    $m", 'Gray', $bg)
            # Codex has no ctx in its state file: take it from the project's newest rollout log.
            $cv = if ($st -and $null -ne $st.ctx) { $st.ctx } elseif ($agent -eq 'codex') { [void](Get-CodexUsage); $script:codexCtxByDir[(Get-NormPath $p.path)] } else { $null }
            $c = "$($icon.ctx) " + $(if ($null -ne $cv) { '{0:N0}%' -f $cv } else { '--' })
            $sh = if ($shells[[int]$slot.slot]) { "  $($icon.shell) $($shells[[int]$slot.slot]) sh" } else { '' }
            $sh += $subText
            if ($agent -eq 'claude') {
                $k = "$($icon.compact) " + $(if ($st -and $null -ne $st.compact) { '~{0:N0}%' -f $st.compact } else { '--' })
                $lines += , @("    $c  $k$sh", 'Gray', $bg)
            } else {
                $lines += , @("    $c$sh", 'Gray', $bg)   # quota is shown under the agent heading
            }
        }
        $repo = Get-RepoLine $p.path
        $lines += , @($(if ($repo) { "    $repo" } else { '' }), $(if ($i -eq $cursor) { 'Gray' } else { 'DarkGray' }), $bg)   # dim grey is unreadable on the highlight
    }
    if ($projects.Count -eq 0) { $lines += , @('(no projects - press A)', 'DarkGray', $null) }

    # Fixed bottom block (detail, message, usage, keys). Built first so the project list is cut to fit
    # above it and can never push the status line off the last row.
    $bottom = @()
    $bottom += , @(('-' * [math]::Min($width, 30)), 'DarkGray', $null)
    if ($projects.Count) {
        $p = $projects[$cursor]
        $st = $statuses[(Get-NormPath $p.path)]
        $bottom += , @($p.path, 'Gray', $null)
        if ($st -and $slots.ContainsKey((Get-NormPath $p.path)) -and (HasInfo $cursor) -and (Get-Agent $p) -eq 'claude') {
            $ctx = if ($null -ne $st.ctx) { '{0:N0}%' -f $st.ctx } else { '--' }
            $cost = if ($null -ne $st.cost) { '${0:N2}' -f $st.cost } else { '--' }
            $bottom += , @("$($icon.model) $($st.model)  $($icon.ctx) $ctx  $cost", 'Gray', $null)
        } else {
            $bottom += , @('Enter: open in a free pane', 'Gray', $null)
        }
    }
    $bottom += , @($message, 'Yellow', $null)
    foreach ($ul in $usageBlock) { $bottom += , $ul }
    # One status line on the last row: keys, then the git/compact symbol legend (cut off by width if needed).
    $bottom += , @('-- keys --', 'Cyan', $null)
    $bottom += , @('Enter open  M move  R sync  X close', 'Gray', $null)
    $bottom += , @('D del A add G agent F diff W tree', 'Gray', $null)
    $bottom += , @("Shift+Up/Down reorder  T toast $(if (Test-Path $script:toastOff) { 'off' } else { 'on' })", 'Gray', $null)
    $bottom += , @("$($icon.changed)n changed $($icon.ahead)push $($icon.behind)pull $($icon.wtree)wt=worktree", 'DarkGray', $null)
    $bottom += , @("$($icon.compact)=compacts at", 'DarkGray', $null)
    $room = [math]::Max(0, $height + 1 - $bottom.Count)
    $lines = @($lines | Select-Object -First $room)
    while ($lines.Count -lt $room) { $lines += , @('', 'Gray', $null) }
    foreach ($b in $bottom) { $lines += , $b }

    # Repaint only the lines that changed since the last frame (less flicker, far less console I/O).
    $row = 0
    foreach ($l in ($lines | Select-Object -First ($height + 1))) {
        $text = [string]$l[0]
        if ($text.Length -gt $width) { $text = $text.Substring(0, $width) }
        $text = $text.PadRight($width)
        $sig = "$($l[1])|$($l[2])|$text"
        # The bottom block is always rewritten: anything that scrolls or scribbles on the console would otherwise
        # leave it stale while the cache believes it is still on screen.
        if ($row -ge $room -or $script:frameCache[$row] -ne $sig) {
            $script:frameCache[$row] = $sig
            [Console]::SetCursorPosition(0, $row)
            if ($l[2]) { Write-Host $text -ForegroundColor $l[1] -BackgroundColor $l[2] -NoNewline }
            else { Write-Host $text -ForegroundColor $l[1] -NoNewline }
        }
        $row++
    }
    [Console]::SetCursorPosition(0, 0)
}
$script:frameCache = @{}
function Clear-Host { $script:frameCache = @{}; [Console]::Clear() }   # a cleared screen must be fully repainted

# Projects that were open (in pane order) are remembered in state\open.json so the next tai start
# reopens them. The list is saved once it has been stable for a few seconds, so closing the whole
# window (panes and dashboard die together) doesn't record an empty list.
$openFile = Join-Path $stateDir 'open.json'
function Get-OpenNow {
    $slots = Get-Slots
    $byNum = @{}
    foreach ($s in $slots.Values) { $byNum[[int]$s.slot] = $s.path }
    $order = @(Get-Layout (Get-PaneCount)) + @($byNum.Keys | Sort-Object)
    $paths = @()
    foreach ($n in $order) { if ($byNum.ContainsKey([int]$n) -and $paths -notcontains $byNum[[int]$n]) { $paths += $byNum[[int]$n] } }
    return , $paths
}

Clear-Host
$cursor = 0
Write-Boot 'dashboard: started'
Update-InstalledAgents
Write-Boot 'dashboard: CLIs scanned'
$message = "CLIs found: $($script:installedAgents -join ', ')"
$restore = New-Object System.Collections.Generic.Queue[string]
try {
    # PS 5.1 hands a JSON array back as one object, so the outer foreach gets the array and the inner one its strings.
    $saved = Get-Content $openFile -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($item in $saved) { foreach ($path in $item) { $restore.Enqueue([string]$path) } }
} catch { }
if ($restore.Count) { $message = "Reopening $($restore.Count) project(s)" }
$lastRestore = [datetime]::MinValue
$lastOpenCheck = [datetime]::MinValue
$savedOpen = $null
$pendingOpen = $null
$pendingSince = [datetime]::MinValue
$lastDraw = [datetime]::MinValue
$lastPaneCheck = [datetime]::MinValue
$dirty = $true
$follow = $null
$lastSize = ''
while ($true) {
    Set-Content $alive (Get-Date).ToString('o')
    $projects = @(Get-SortedProjects)
    if ($follow) {
        # $follow is a project name or a normalised path; a plain loop, since calling a script function from a Predicate delegate is unreliable.
        for ($i = 0; $i -lt $projects.Count; $i++) {
            if ($projects[$i].name -eq $follow -or (Get-NormPath $projects[$i].path) -eq $follow) { $cursor = $i; break }
        }
        $follow = $null
    }
    if ($cursor -ge $projects.Count) { $cursor = [math]::Max(0, $projects.Count - 1) }

    # Pane windows that went away (closed with X or by hand): drop them from the layout.
    if (((Get-Date) - $lastPaneCheck).TotalSeconds -ge 0.5) {
        $lastPaneCheck = Get-Date
        foreach ($dead in @(Get-DeadPanes)) {
            if (Remove-Pane $dead) {
                # Every close: reshape for the open panes, then read every place back so the layout matches the screen.
                $reshaped = Optimize-Layout
                $message = if (Sync-Layout) { if ($reshaped) { "Pane $dead closed, panes reshaped" } else { "Pane $dead closed, layout re-read" } } else { "Pane $dead closed (press R to re-read the layout)" }
                [void](Focus-Dashboard)
                $dirty = $true
            }
            else { Remove-Item (Join-Path $stateDir "slot$dead.pane") -Force -ErrorAction SilentlyContinue }   # last pane: slot.ps1 rewrites it
        }
    }

    # Reopen last session's projects in one go: the assignments are written first, every split goes into a
    # single wt command line, and the panes start in parallel.
    if ($restore.Count) {
        Write-Boot 'restore: begin'
        $skipped = 0; $opened = 0
        while ($restore.Count) {
            $path = $restore.Dequeue()
            $want = @($projects | Where-Object { (Get-NormPath $_.path) -eq (Get-NormPath $path) })
            if (-not $want.Count) { $skipped++; continue }
            # One wt call per pane: focus steps for a later split inside the same command line as the earlier
            # splits landed on the wrong pane (3 stacked + 1 tall), so each split gets to finish first.
            $batch = New-Object System.Collections.Generic.List[string]
            $result = Open-Project $want[0] (Get-Slots) $batch
            if ($result -like 'Opening *') { $opened++ } else { $message = $result }
            if ($batch.Count) { Invoke-Wt $batch -Wait; Start-Sleep -Milliseconds 700 }
        }
        Write-Boot "restore: wt batch started ($opened opened, $skipped skipped)"
        if ($opened -or $skipped) { $message = "Reopened $opened project(s)" + $(if ($skipped) { ", $skipped no longer in the list" } else { '' }) }
        $dirty = $true
        # Done: land on the dashboard; the restored panes stay open beside it.
        Start-Sleep -Milliseconds 800
        [void](Focus-Dashboard)
        Write-Boot 'restore: focus back on dashboard'
    }
    elseif (-not $restore.Count -and ((Get-Date) - $lastOpenCheck).TotalSeconds -ge 2) {
        $lastOpenCheck = Get-Date
        $now = Get-OpenNow
        $json = ConvertTo-Json -InputObject @($now) -Compress
        if ($json -ne $savedOpen) {
            if ($json -ne $pendingOpen) { $pendingOpen = $json; $pendingSince = Get-Date }
            elseif (((Get-Date) - $pendingSince).TotalSeconds -ge 4) {
                Set-Content $openFile $json -Encoding utf8
                $savedOpen = $json
            }
        }
    }

    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        $dirty = $true
        $script:keyRedraw = $true
        $message = ''
        switch ($key.Key) {
            'UpArrow' {
                if ($key.Modifiers -band [ConsoleModifiers]::Shift) {
                    if ($projects.Count) {
                        # The two swap places in the sorted list, so the cursor moves with the project before the redraw.
                        if (Move-ProjectOrder $projects $cursor -1) { $cursor-- } else { $message = 'Already first in its group' }
                    }
                }
                elseif ($projects.Count) { $cursor = ($cursor - 1 + $projects.Count) % $projects.Count }
            }
            'DownArrow' {
                if ($key.Modifiers -band [ConsoleModifiers]::Shift) {
                    if ($projects.Count) {
                        if (Move-ProjectOrder $projects $cursor 1) { $cursor++ } else { $message = 'Already last in its group' }
                    }
                }
                elseif ($projects.Count) { $cursor = ($cursor + 1) % $projects.Count }
            }
            'Enter' {
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    $slots = Get-Slots
                    # First open of a project with no saved agent: ask once, then remember the choice in projects.json.
                    if (-not $slots.ContainsKey((Get-NormPath $p.path)) -and $script:agents -notcontains $p.agent) {
                        $choices = @($script:installedAgents)
                        $idx = 0
                        # Only one CLI installed: nothing to ask.
                        while ($choices.Count -gt 1) {
                            Clear-Host
                            Write-Host "Which CLI should '$($p.name)' use?" -ForegroundColor Cyan
                            for ($n = 0; $n -lt $choices.Count; $n++) {
                                if ($n -eq $idx) { Write-Host "> $($n + 1)  $($choices[$n])" -ForegroundColor Black -BackgroundColor Gray }
                                else { Write-Host "  $($n + 1)  $($choices[$n])" }
                            }
                            Write-Host "Up/Down + Enter, or 1-$($choices.Count). Esc cancels"
                            $pick = [Console]::ReadKey($true)
                            if ($pick.Key -eq 'UpArrow') { $idx = ($idx - 1 + $choices.Count) % $choices.Count; continue }
                            if ($pick.Key -eq 'DownArrow') { $idx = ($idx + 1) % $choices.Count; continue }
                            if ($pick.Key -eq 'Enter') { break }
                            $idx = [int]($pick.KeyChar.ToString() -replace '\D', '0') - 1
                            break
                        }
                        Clear-Host
                        if ($idx -lt 0 -or $idx -ge $choices.Count) { $message = 'Cancelled'; continue }
                        $p | Add-Member -NotePropertyName agent -NotePropertyValue $choices[$idx] -Force
                        Save-Projects $projects
                        $follow = $p.name
                    }
                    $message = Open-Project $p (Get-Slots)
                }
            }
            'A' {
                Clear-Host
                $path = Read-Host 'Folder path to add or create (blank cancels)'
                if ($path) {
                    try {
                        $path = $path.Trim('"')
                        # A folder that doesn't exist yet can be created on the spot.
                        if (-not (Test-Path $path)) {
                            $answer = Read-Host "'$path' does not exist. Create it (y/N)"
                            if ($answer -notmatch '^[yY]') { throw 'Cancelled' }
                            New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
                        }
                        $projects = @(Add-Projects $projects @($path.Trim('"')) $null)
                        Save-Projects $projects
                        $follow = $projects[$projects.Count - 1].name
                    } catch { $message = $_.Exception.Message }
                }
                Clear-Host
            }
            'G' {
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    if ((Get-Slots).ContainsKey((Get-NormPath $p.path))) { $message = "Close $($p.name) first (X) to change its agent" }
                    else {
                        $list = @($script:installedAgents)
                        $next = $list[([array]::IndexOf($list, (Get-Agent $p)) + 1) % $list.Count]
                        $p | Add-Member -NotePropertyName agent -NotePropertyValue $next -Force
                        Save-Projects $projects
                        $message = "$($p.name) will run $next"
                        $follow = $p.name   # the project moves to another group; keep the cursor on it
                    }
                }
            }
            'M' {
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    $slot = (Get-Slots)[(Get-NormPath $p.path)]
                    if (-not $slot) { $message = "$($p.name) is not open" }
                    elseif ((Get-PaneCount) -lt 2) { $message = 'Only one pane open' }
                    else {
                        Draw $projects $cursor 'Move which way? arrows, Esc cancels'
                        $dir = [Console]::ReadKey($true).Key
                        if ($dir -match '^(Left|Right|Up|Down)Arrow$') {
                            Draw $projects $cursor 'Moving...'
                            $message = Move-Pane ([int]$slot.slot) ($dir -replace 'Arrow$', '')
                        }
                    }
                }
            }
            'F' {
                # Diff of the selected project in its own tab, so the dashboard stays as is; git pages it (q closes the tab).
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    Invoke-Wt "new-tab $script:wtProfile --title `"diff $($p.name)`" -d `"$($p.path)`" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\diffview.ps1`" -Path `"$($p.path)`""
                    $message = "Diff of $($p.name) opened in a new tab"
                }
            }
            'T' {
                if (Test-Path $script:toastOff) { Remove-Item $script:toastOff -Force -ErrorAction SilentlyContinue; $message = 'Toasts on' }
                else { Set-Content $script:toastOff (Get-Date).ToString('o'); $message = 'Toasts off' }
            }
            'W' {
                # New git worktree on a new branch, added to the project list as its own project.
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    Clear-Host
                    $branch = (Read-Host "New branch for a worktree of '$($p.name)' (blank cancels)").Trim()
                    if ($branch) {
                        $safe = $branch -replace '[^\w.-]', '-'
                        $dir = (Split-Path $p.path -Parent) + '\' + (Split-Path $p.path -Leaf) + '-' + $safe
                        $out = & git -C $p.path worktree add -b $branch $dir 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            try {
                                $projects = @(Add-Projects $projects @($dir) $null)
                                Save-Projects $projects
                                $follow = $projects[$projects.Count - 1].name
                                $message = "Worktree $safe added"
                            } catch { $message = $_.Exception.Message }
                        } else { $message = ([string]($out | Select-Object -Last 1)) }
                    }
                    Clear-Host
                }
            }
            'R' {
                Draw $projects $cursor 'Re-reading layout...'
                $message = if (Sync-Layout) { 'Layout re-read' } else { 'Could not read the layout' }
            }
            'X' {
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    $slots = Get-Slots
                    if ($slots.ContainsKey((Get-NormPath $p.path))) {
                        Clear-Host
                        $answer = Read-Host "Close '$($p.name)' and its pane? A reply in progress is cut off (y/N)"
                        if ($answer -match '^[yY]') { $message = Close-Project $p $slots }
                        Clear-Host
                    } else { $message = "$($p.name) is not open" }
                }
            }
            'D' {
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    Clear-Host
                    $answer = Read-Host "Remove '$($p.name)' from the list? Folder is kept (y/N)"
                    if ($answer -match '^[yY]') {
                        Save-Projects @($projects | Where-Object { $_.name -ne $p.name })
                    }
                    Clear-Host
                }
            }
        }
    }

    # Window resized: wipe leftovers and redraw at the new size right away.
    $size = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
    if ($size -ne $lastSize) { $lastSize = $size; Clear-Host; $dirty = $true }

    if ($dirty -or ((Get-Date) - $lastDraw).TotalSeconds -ge 2) {
        $projects = @(Get-SortedProjects)
        if ($cursor -ge $projects.Count) { $cursor = [math]::Max(0, $projects.Count - 1) }
        if (-not $script:keyRedraw) { try { Notify-Waiting $projects } catch { } }
        try { Draw $projects $cursor $message }
        catch { Start-Sleep -Milliseconds 200 }   # transient read error; next tick redraws
        $script:keyRedraw = $false
        $lastDraw = Get-Date
        $dirty = $false
    } else {
        Start-Sleep -Milliseconds 80
    }
}
