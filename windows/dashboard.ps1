# Always-open left pane: account usage plus every project. Move with Up/Down,
# Enter focuses the project's pane, or opens it in the first free pane.
. (Join-Path $PSScriptRoot 'lib.ps1')

Protect-Tai   # higher priority + resident memory for the dashboard and its terminal window
$stateDir = Join-Path $PSScriptRoot 'state'
$usageFile = Join-Path $PSScriptRoot 'usage.json'
$alive = Join-Path $stateDir 'dashboard.alive'
Remove-Item (Join-Path $stateDir 'dashboard.launching') -Force -ErrorAction SilentlyContinue   # tai.ps1's start-up marker
$maxSlots = $script:maxPanes   # from lib.ps1 (TAI_MAX_PANES)
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
    deleg   = [string][char]0x21C4   # two arrows (a running `tai delegate`)
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
$script:codexMtByDir = @{}   # per project folder: last write of its newest rollout log (stands in for Claude's transcript)
$script:codexByHome = @{}   # per CODEX_HOME folder: @{ stamp; usage; ctx; mt }
$script:rolloutCache = @{}  # per rollout log: @{ stamp; cwdKey; ctx; lim } extracted values, reused while the file is unchanged
# Usage and per-project context of one Codex home (default ~/.codex); each account's folder is scanned and cached separately.
function Get-CodexUsage($codexHome) {
    if (-not $codexHome) { $codexHome = Join-Path $env:USERPROFILE '.codex' }
    $hk = $codexHome.ToLower()
    $c0 = $script:codexByHome[$hk]
    if ($c0 -and ((Get-Date) - $c0.stamp).TotalSeconds -lt 30) { $script:codexCtxByDir = $c0.ctx; $script:codexMtByDir = $c0.mt; return $c0.usage }
    $script:codexUsage = $null
    $script:codexCtxByDir = @{}
    $script:codexMtByDir = @{}
    $mtByDir = @{}
    try {
        $root = Join-Path $codexHome 'sessions'
        # Logs sit in YYYY\MM\DD folders; look at the newest day folders only (up to 7, stopping at 20 files) so years of
        # history are not listed on every refresh. Falls back to the full scan when the layout is not as expected.
        $cand = @()
        $days = 0
        :scan foreach ($y in @(Get-ChildItem $root -Directory -ErrorAction Stop | Where-Object { $_.Name -match '^\d{4}$' } | Sort-Object Name -Descending)) {
            foreach ($mo in @(Get-ChildItem $y.FullName -Directory | Sort-Object Name -Descending)) {
                foreach ($d in @(Get-ChildItem $mo.FullName -Directory | Sort-Object Name -Descending)) {
                    $cand += @(Get-ChildItem $d.FullName -Filter 'rollout-*.jsonl' -File)
                    $days++
                    if ($days -ge 7 -or $cand.Count -ge 20) { break scan }
                }
            }
        }
        if (-not $cand.Count) { $cand = @(Get-ChildItem $root -Recurse -Filter 'rollout-*.jsonl' -ErrorAction Stop) }
        $files = @($cand | Sort-Object LastWriteTime -Descending | Select-Object -First 20)
        $byDir = @{}
        $gotLimits = $false
        $script:codexUsage = $null
        foreach ($f in $files) {
            # A rollout log that has not changed since the last scan gives the same answers: reuse what was extracted
            # from it instead of reading its 400 KB tail and running the regexes again.
            $rstamp = '{0}|{1}' -f $f.LastWriteTimeUtc.Ticks, $f.Length
            $rc = $script:rolloutCache[$f.FullName]
            if (-not $rc -or $rc.stamp -ne $rstamp) {
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
                $txt = [Text.Encoding]::UTF8.GetString($buf)
                $cwd = [regex]::Match([Text.Encoding]::UTF8.GetString($hbuf), '"cwd":"((?:[^"\\]|\\.)*)"')
                $c = [regex]::Matches($txt, '"last_token_usage":\{[^}]*?"total_tokens":(\d+)\},"model_context_window":(\d+)')
                $rc = @{ stamp = $rstamp; cwdKey = $null; ctx = $null; lim = $null }
                if ($cwd.Success) {
                    $rc.cwdKey = Get-NormPath ($cwd.Groups[1].Value -replace '\\\\', '\')
                    if ($c.Count -and [double]$c[$c.Count - 1].Groups[2].Value -gt 0) {
                        $cg = $c[$c.Count - 1].Groups
                        $rc.ctx = [math]::Min(100, [math]::Round(100 * [double]$cg[1].Value / [double]$cg[2].Value))
                    }
                }
                $m = [regex]::Matches($txt, '"rate_limits":\{.*?"primary":\{"used_percent":([\d.]+),"window_minutes":(\d+),"resets_at":(\d+)\},"secondary":(?:null|\{"used_percent":([\d.]+),"window_minutes":(\d+),"resets_at":(\d+)\})')
                if ($m.Count) {
                    $lg = $m[$m.Count - 1].Groups
                    $rc.lim = @{ v = @($null, $lg[1].Value, $lg[2].Value, $lg[3].Value, $lg[4].Value, $lg[5].Value, $lg[6].Value); hasSec = $lg[4].Success }
                }
                $script:rolloutCache[$f.FullName] = $rc
            }
            # Context per project folder: newest log wins (files are newest first).
            if ($rc.cwdKey -and -not $mtByDir.ContainsKey($rc.cwdKey)) { $mtByDir[$rc.cwdKey] = $f.LastWriteTime }
            if ($rc.cwdKey -and $null -ne $rc.ctx -and -not $byDir.ContainsKey($rc.cwdKey)) { $byDir[$rc.cwdKey] = $rc.ctx }
            if ($script:codexUsage -and $gotLimits) { continue }
            if ($rc.lim) {
                $l = $rc.lim.v
                # A window whose reset time has passed describes an old period: don't show it as current.
                $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $hasSec = $rc.lim.hasSec
                if ([long]$l[3] -lt $nowUnix -and (-not $hasSec -or [long]$l[6] -lt $nowUnix)) { continue }
                # Free plans have one 30-day window and no secondary; label each window by its length.
                function WinLabel($min) { $min = [int]$min; if ($min -ge 1440) { '{0}d' -f [math]::Round($min / 1440) } else { '{0}h' -f [math]::Round($min / 60) } }
                $wins = @([pscustomobject]@{ label = (WinLabel $l[2]); used_percentage = [double]$l[1]; resets_at = [long]$l[3] })
                if ($hasSec) { $wins += [pscustomobject]@{ label = (WinLabel $l[5]); used_percentage = [double]$l[4]; resets_at = [long]$l[6] } }
                $script:codexUsage = $wins
                $gotLimits = $true
            }
        }
        $script:codexCtxByDir = $byDir
        $script:codexMtByDir = $mtByDir
    } catch { }
    $script:codexByHome[$hk] = @{ stamp = Get-Date; usage = $script:codexUsage; ctx = $script:codexCtxByDir; mt = $script:codexMtByDir }
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
    # One rev-parse for toplevel + git dir, one status for branch, upstream distance and changes, one worktree list.
    $rp = @(git -C $path rev-parse --show-toplevel --git-dir 2>$null)
    if ($LASTEXITCODE -eq 0 -and $rp.Count -ge 2 -and $rp[0]) {
        $top = [string]$rp[0]; $gitDir = [string]$rp[1]
        $count = 0
        foreach ($l in (git -C $path worktree list --porcelain 2>$null)) { if ($l -like 'worktree *') { $count++ } }
        $changed = 0; $new = 0
        $branch = $null; $oid = ''; $ahead = $null; $behind = $null
        foreach ($l in (git --no-optional-locks -C $path status --porcelain=v2 --branch 2>$null)) {
            if ($l.StartsWith('# branch.head ')) { $branch = $l.Substring(14) }
            elseif ($l.StartsWith('# branch.oid ')) { $oid = $l.Substring(13) }
            elseif ($l.StartsWith('# branch.ab ')) {
                # "+<ahead> -<behind>"; the line is absent when no upstream is set (both stay null).
                $ab = $l.Substring(12) -split '\s+'
                $ahead = [int]($ab[0].TrimStart('+')); $behind = [int]($ab[1].TrimStart('-'))
            }
            elseif ($l.StartsWith('? ')) { $new++ }
            elseif ($l.Length -gt 0 -and $l[0] -ne '#') { $changed++ }
        }
        if (-not $branch -or $branch -eq '(detached)') { $branch = 'detached ' + $oid.Substring(0, [math]::Min(7, $oid.Length)) }
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
    # A lookup stuck for over a minute (network, auth prompt) would block every other project's lookup: drop it, keep the old text.
    if ($c.job -and $c.job.State -eq 'Running' -and ((Get-Date) - $c.time).TotalSeconds -gt 60) {
        Stop-Job $c.job -ErrorAction SilentlyContinue
        Remove-Job $c.job -Force -ErrorAction SilentlyContinue
        $c.job = $null
        $c.time = Get-Date
    }
    if ($c.job -and $c.job.State -ne 'Running') {
        $out = @(Receive-Job $c.job -ErrorAction SilentlyContinue)
        Remove-Job $c.job -Force
        $c.job = $null
        $c.time = Get-Date
        $f = if ($out.Count) { ([string]$out[0]).Split("`t") } else { @() }
        if ($f.Count -ge 4) { $c.text = 'issues {0}  PRs {1}' -f $f[2], $f[3] }
        elseif ($f.Count -eq 1 -and $f[0] -eq 'NOREPO') { $c.text = 'no GitHub repo' }
        else { $c.time = (Get-Date).AddSeconds(-240) }   # a failed lookup (network, auth, load) retries in a minute and keeps the old text
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
            if ($LASTEXITCODE -ne 0 -or -not $nwo) {
                # Only a folder with no github.com remote is "no repo"; anything else is a failed lookup to retry.
                $url = git remote get-url origin 2>$null
                if (-not $url -or $url -notmatch 'github\.com') { 'NOREPO' }
                return
            }
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
        # Never-loaded projects first, then the stalest one. Taking the first stale project in list order starved
        # the later ones: the early projects went stale again (10 s) before a later one ever got its first lookup.
        $pick = $null; $oldest = $null; $fresh = 0
        foreach ($p in $projects) {
            $c = $gitCache[(Get-NormPath $p.path)]
            if (-not $c) { $null = Get-GitInfo $p.path; $fresh++; if ($fresh -ge 3) { break }; continue }   # up to 3 first lookups per frame
            if (((Get-Date) - $c.time).TotalSeconds -ge 10 -and (-not $oldest -or $c.time -lt $oldest)) { $oldest = $c.time; $pick = $p }
        }
        if ($pick -and -not $fresh) { $null = Get-GitInfo $pick.path }
    }
    foreach ($p in $projects) {
        $c = $ghCache[(Get-NormPath $p.path)]
        if ($c -and $c.job) { $null = Get-GhStats $p.path -NoStart; continue }
        if (-not $c -or ((Get-Date) - $c.time).TotalSeconds -ge 300) { if ($gitCache[(Get-NormPath $p.path)].info) { $null = Get-GhStats $p.path; break } }
    }
}

# Parsed JSON of a state file, re-read only when its size or write time changed. $f is the FileInfo from a directory
# listing. Throws on an unreadable file (mid-write), which callers already skip. Entries of deleted files are dropped.
$script:jsonCache = @{}
function Read-JsonCached($f) {
    $stamp = '{0}|{1}' -f $f.LastWriteTimeUtc.Ticks, $f.Length
    $c = $script:jsonCache[$f.FullName]
    if ($c -and $c.stamp -eq $stamp) { return $c.obj }
    $obj = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
    $script:jsonCache[$f.FullName] = @{ stamp = $stamp; obj = $obj }
    return $obj
}
function Clear-JsonCacheOrphans {
    foreach ($k in @($script:jsonCache.Keys)) { if (-not [IO.File]::Exists($k)) { $script:jsonCache.Remove($k) } }
}

# Housekeeping, run at start and then hourly: leftover temp files from writers that were killed mid-write (older than
# an hour, so a write in progress is never touched), and per-project state of projects not used for a week
# (status, hook and sub-agent files; they are recreated on the next activity). Slot, open_* and settings files stay.
$script:lastSweep = [datetime]::MinValue
function Clear-StaleState {
    $now = Get-Date
    foreach ($dir in @($stateDir, $PSScriptRoot)) {
        foreach ($f in @(Get-ChildItem $dir -Filter '*.tmp' -File -ErrorAction SilentlyContinue)) {
            if (($now - $f.LastWriteTime).TotalHours -ge 1) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($f in @(Get-ChildItem $stateDir -File -ErrorAction SilentlyContinue)) {
        if (($now - $f.LastWriteTime).TotalDays -lt 7) { continue }
        $n = $f.Name
        if ($n -like 'hook_*.json' -or $n -like 'subs_*.txt' -or ($n -match '_[0-9A-F]{8}\.json$' -and $n -notlike 'slot*' -and $n -notlike 'open_*')) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Clear-JsonCacheOrphans
    $script:lastSweep = $now
}

# Panes in use, keyed by normalized project path. Includes panes still starting up.
function Get-Slots {
    $slots = @{}
    # A file can be mid-write or deleted between listing and reading; skip it and retry next refresh.
    foreach ($f in Get-ChildItem $stateDir -Filter 'slot*.json' -ErrorAction SilentlyContinue) {
        try {
            $s = Read-JsonCached $f
            # Pane window closed without exiting Claude: its file is stale. (Files from older panes have no pid.)
            if ($s.pid -and -not (Test-SlotAlive $s.pid $s.since)) {
                # The wrapper is gone; if it was killed from outside, its CLI is still running in the pane. Stop it.
                [void](Stop-OrphanedSlotChildren $s.pid $s.since)
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; continue
            }
            $slots[(Get-NormPath $s.path)] = $s
        } catch { continue }
    }
    foreach ($f in Get-ChildItem $stateDir -Filter 'slot*.assign' -ErrorAction SilentlyContinue) {
        try {
            $s = Read-JsonCached $f
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
            $s = Read-JsonCached $f
            $statuses[(Get-NormPath $s.dir)] = $s
        } catch { continue }
    }
    return $statuses
}

# Reasoning effort from a Codex home's config.toml (hooks don't carry it); cached 30 s.
$script:codexEffort = @{}
function Get-CodexEffort($codexHome) {
    if (-not $codexHome) { $codexHome = Join-Path $env:USERPROFILE '.codex' }
    $hk = $codexHome.ToLower()
    $e = $script:codexEffort[$hk]
    if ($e -and ((Get-Date) - $e.stamp).TotalSeconds -lt 30) { return $e.value }
    $v = $null
    try {
        # Top level only: the text before the first [table] header (a [profiles.x] table has its own value).
        $toml = (Get-Content (Join-Path $codexHome 'config.toml') -Raw -ErrorAction Stop) -split '(?m)^\s*\[', 2
        $m = [regex]::Match($toml[0], '(?m)^\s*model_reasoning_effort\s*=\s*"([^"]+)"')
        if ($m.Success) { $v = $m.Groups[1].Value }
    } catch { }
    $script:codexEffort[$hk] = @{ stamp = Get-Date; value = $v }
    return $v
}

# agy's status line only writes when agy redraws it: a "working" report that has gone quiet for 3 minutes is stale
# (the pane stopped or was closed without going idle), so it counts as idle.
function ToDate($v) { try { return [datetime]$v } catch { return [datetime]::MinValue } }

function Get-EffActivity($st) {
    $a = [string]$st.activity
    if ($a -eq 'working' -and $st.updated -and ((Get-Date) - (ToDate $st.updated)).TotalSeconds -gt 180) { return 'idle' }
    return $a
}

# Open agents across all projects by state (same sources as the rows: hooks first, then agy's status line, then the
# Claude transcript's last write). Returns open/working/waiting/idle counts and the same per CLI.
function Get-AgentCounts($slots, $statuses, $hooks, $projects) {
    $c = [ordered]@{ open = 0; working = 0; waiting = 0; idle = 0; by = [ordered]@{} }
    foreach ($key in $slots.Keys) {
        $slot = $slots[$key]
        $agent = if ($slot.agent) { Get-Agent $slot } else { 'claude' }
        $since = ToDate $slot.since
        $st = $statuses[$key]; $hk = $hooks[$key]
        $state = 'idle'
        $mtime = $null
        if ($st -and (ToDate $st.updated) -ge $since) {
            if ($st.transcript) { try { $tmt = [IO.File]::GetLastWriteTime([string]$st.transcript); if ($tmt.Year -gt 1700) { $mtime = $tmt } } catch { } }   # a missing file reads as year 1601
            if ($mtime -and ((Get-Date) - $mtime).TotalSeconds -lt $busySeconds) { $state = 'working' }
            if ($agent -ne 'claude' -and $st.agent -eq $agent -and $st.activity) {
                $state = switch (Get-EffActivity $st) { 'working' { 'working' } 'waiting' { 'waiting' } default { 'idle' } }
            }
        }
        if ($agent -eq 'codex' -and -not $mtime) {
            # The rollout times are per Codex home, so load this project's own account home first (cached).
            $pr = @($projects) | Where-Object { (Get-NormPath $_.path) -eq $key } | Select-Object -First 1
            if ($pr) { [void](Get-CodexUsage (ProjectAcctDir $pr 'codex')) }
            $mtime = $script:codexMtByDir[$key]
        }
        if ($hk -and (ToDate $hk.updated) -ge $since) {
            switch ($hk.status) {
                'working' { $state = 'working' }
                'waiting' { $state = if ($mtime -and ($mtime -gt (ToDate $hk.updated).AddSeconds(2))) { 'working' } else { 'waiting' } }
                'done'    { $state = 'idle' }
            }
        }
        $c.open++; $c[$state]++
        if (-not $c.by.Contains($agent)) { $c.by[$agent] = 0 }
        $c.by[$agent]++
    }
    return $c
}

# Latest hook report per project directory (working / waiting / done), written by hook.ps1.
function Get-Hooks {
    $hooks = @{}
    foreach ($f in Get-ChildItem $stateDir -Filter 'hook_*.json' -ErrorAction SilentlyContinue) {
        try {
            $h = Read-JsonCached $f
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
function Notify-Waiting($projects, $slots, $hooks) {
    if (-not $slots) { $slots = Get-Slots }
    if (-not $hooks) { $hooks = Get-Hooks }
    foreach ($p in $projects) {
        $key = Get-NormPath $p.path
        $slot = $slots[$key]; $hk = $hooks[$key]
        if (-not $slot -or -not $hk -or $hk.status -ne 'waiting') { $script:notified.Remove($key); continue }
        if ((ToDate $hk.updated) -lt (ToDate $slot.since)) { continue }
        $stamp = [string]$hk.updated
        if ($script:notified[$key] -eq $stamp) { continue }
        $script:notified[$key] = $stamp
        if ($script:notifySeeded -and -not (Test-Path $script:toastOff)) { Send-Toast "$($p.name) needs you" 'Waiting for input in tai' }
    }
    $script:notifySeeded = $true
}

# Running `tai delegate` hand-offs of a project: delegate.ps1 keeps <project>\.tai\running-<target>.lock (pid + start time)
# while the target works. A lock whose process is gone, or that is older than 2 hours, is ignored. Text like "codex 0:42".
$script:delegCache = @{}
function Get-DelegationText($path) {
    # The directory listing, lock reads and process lookups are cached for 3 s per project (the timer text moves with the draw tick).
    $ck = Get-NormPath $path
    $dc = $script:delegCache[$ck]
    if ($dc -and ((Get-Date) - $dc.stamp).TotalSeconds -lt 3) { return $dc.text }
    $text = Get-DelegationTextRaw $path
    $script:delegCache[$ck] = @{ stamp = Get-Date; text = $text }
    return $text
}
function Get-DelegationTextRaw($path) {
    $out = @()
    try {
        $dir = Join-Path $path '.tai'
        if (-not [IO.Directory]::Exists($dir)) { return '' }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'running-*.lock' -File -ErrorAction SilentlyContinue)) {
            $l = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            if (-not $l.pid -or -not (Get-Process -Id ([int]$l.pid) -ErrorAction SilentlyContinue)) { continue }
            $secs = ((Get-Date) - [datetime]$l.since).TotalSeconds
            if ($secs -lt 0 -or $secs -gt 7200) { continue }
            $target = $f.BaseName -replace '^running-', ''
            $out += ('{0} {1}:{2:00}' -f $target, [int][math]::Floor($secs / 60), [int]($secs % 60))
        }
    } catch { }
    if ($out.Count) { return "  $($icon.deleg) " + ($out -join ', ') }
    return ''
}

# Sub-agents running inside a project's session (SubagentStart/SubagentStop hooks, see hook.ps1).
# Entries from before the pane started, or older than half an hour (a stop that never came), are ignored.
function Get-SubCount($project, $slot) {
    if (-not $slot) { return 0 }
    $file = Join-Path $stateDir ('subs_' + (Get-StateKey $project.path) + '.txt')
    if (-not [IO.File]::Exists($file)) { return 0 }
    $n = 0
    try {
        $since = ToDate $slot.since
        $now = Get-Date
        foreach ($line in [IO.File]::ReadAllLines($file)) {
            $f = $line -split "`t"
            if ($f.Count -lt 3) { continue }
            $t = ToDate $f[2]
            if ($t -ge $since -and ($now - $t).TotalMinutes -lt 30) { $n++ }
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
function Get-ShellPids($kids, $roots) {
    # $kids: parent pid -> its child process records (built once per snapshot), so each lookup is direct.
    $cliIds = @($roots)
    foreach ($r in @($roots)) {
        foreach ($k in $kids[[int]$r]) { if ($k.Name -notmatch '^(bash|powershell|pwsh|conhost)\.exe$') { $cliIds += [int]$k.ProcessId } }
    }
    $ids = @()
    foreach ($c in $cliIds) {
        foreach ($k in $kids[[int]$c]) {
            if ($k.Name -match '^(bash|powershell|pwsh)\.exe$' -and $k.CommandLine -notmatch 'statusline\.ps1|hook\.ps1') { $ids += $k.ProcessId }
        }
    }
    return $ids
}
function Get-ShellCounts($slots) {
    # A redraw caused by a keypress never waits for the slow snapshot; the next timed redraw refreshes it.
    if ($script:keyRedraw -or ((Get-Date) - $script:shellStamp).TotalSeconds -lt 12) { return $script:shellCache }
    # Nothing to count without a pane process: skip the snapshot entirely.
    $withPid = @($slots.Values | Where-Object { $_.pid })
    if (-not $withPid.Count) { $script:shellCache = @{}; $script:shellStamp = Get-Date; return $script:shellCache }
    $counts = @{}
    try {
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop)
        # Parent pid -> children, built once so the per-pane lookups below are direct.
        $kids = @{}
        foreach ($pr in $all) {
            $pp = [int]$pr.ParentProcessId
            if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }
            [void]$kids[$pp].Add($pr)
        }
        foreach ($s in $withPid) {
            # Whatever CLI runs in the pane (claude, codex, agy) is a child of the slot's PowerShell; node-based
            # ones can have a wrapper process in between, so non-shell children of the CLI count as part of it too.
            $roots = @()
            foreach ($k in $kids[[int]$s.pid]) { if ($k.Name -ne 'conhost.exe') { $roots += [int]$k.ProcessId } }
            $ids = @{}
            foreach ($id in (Get-ShellPids $kids $roots)) { $ids[[int]$id] = 1 }
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
                foreach ($id in (Get-ShellPids $kids @($sess | ForEach-Object { $_.ProcessId }))) { $counts[$bySlot[$best]][[int]$id] = 1 }
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
    # The only pane was closed by hand: split a new first pane off the dashboard.
    if (Test-NoPanes) {
        $first = [int](Get-Content (Join-Path $stateDir 'nopanes') -Raw -ErrorAction SilentlyContinue)
        if ($first -lt 1) { $first = 1 }
        $assignFile = Join-Path $stateDir "slot$first.assign"
        [pscustomobject]@{ name = $project.name; path = $project.path; agent = (Get-Agent $project) } |
            ConvertTo-Json | Set-Content "$assignFile.tmp" -Encoding utf8
        Move-Item "$assignFile.tmp" $assignFile -Force
        New-FirstPane $first $batch
        return "Opening $($project.name) in pane $first"
    }
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
$script:sortedCache = $null
function Get-SortedProjects {
    # projects.json is re-read and re-sorted only when the file changed (size / write time).
    $stamp = $null
    try { $fi = New-Object IO.FileInfo $script:configPath; if ($fi.Exists) { $stamp = '{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length } } catch { }
    if ($stamp -and $script:sortedCache -and $script:sortedCache.stamp -eq $stamp) { return $script:sortedCache.list }
    $list = @(Get-SortedProjectsRaw)
    if ($stamp) { $script:sortedCache = @{ stamp = $stamp; list = $list } }
    return $list
}
function Get-SortedProjectsRaw {
    $all = @(Get-Projects)
    # Bucket by agent rank, keeping list order inside a bucket (replaces a repeated array += and a sort).
    $buckets = @{}
    foreach ($p in $all) {
        $a = [array]::IndexOf($script:agents, (Get-Agent $p))
        if (-not $buckets.ContainsKey($a)) { $buckets[$a] = New-Object System.Collections.ArrayList }
        [void]$buckets[$a].Add($p)
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($a in ($buckets.Keys | Sort-Object)) { $out.AddRange($buckets[$a]) }
    @($out)
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

# P: commit everything, push the branch and optionally open a PR (gh pr create --fill). Runs in the dashboard pane.
function Publish-Project($p) {
    $env:GIT_TERMINAL_PROMPT = '0'   # a missing credential fails fast instead of hanging the dashboard
    $path = $p.path
    # Capture first, then read the exit code: `| Select-Object -First 1` ends the pipeline early, so $LASTEXITCODE could
    # still hold a failure from an earlier git call (e.g. the dashboard's upstream lookup) and fake a "not a repo".
    $head = @(& git -C $path rev-parse --abbrev-ref HEAD 2>&1)
    if ($LASTEXITCODE -ne 0) { return "$($p.name): git said '$([string]($head | Select-Object -First 1))'" }
    $branch = [string]($head | Select-Object -First 1)
    if ($branch -eq 'HEAD') { return "$($p.name) has a detached HEAD; check out a branch first" }
    Write-Host "$($p.name) on branch '$branch'" -ForegroundColor Cyan
    $changed = @(& git -C $path status --porcelain)
    $changed | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" }
    if ($changed.Count -gt 15) { Write-Host "  ... and $($changed.Count - 15) more" }
    if ($branch -match '^(main|master)$') {
        if ((Read-Host "You are on '$branch'. Continue (y/N)") -notmatch '^[yY]') { return 'Cancelled' }
    }
    if ($changed.Count) {
        $msg = (Read-Host 'Commit message (blank cancels)').Trim()
        if (-not $msg) { return 'Cancelled' }
        $f = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($f, $msg, (New-Object Text.UTF8Encoding($false)))
            $out = & git -C $path add -A 2>&1
            if ($LASTEXITCODE -ne 0) { return "git add failed: $([string]($out | Select-Object -Last 1))" }
            $out = & git -C $path commit -F $f 2>&1
        } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        if ($LASTEXITCODE -ne 0) { return [string]($out | Select-Object -Last 1) }
        Write-Host 'Committed.' -ForegroundColor Green
    } elseif ((Read-Host 'Nothing to commit. Push anyway (y/N)') -notmatch '^[yY]') { return 'Nothing to commit' }
    $out = & git -C $path push -u origin HEAD 2>&1
    $out | Select-Object -Last 6 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { [void](Read-Host 'Push failed. Enter to return'); return 'Push failed' }
    $result = "Pushed $branch"
    if ((Get-Command gh -ErrorAction SilentlyContinue) -and $branch -notmatch '^(main|master)$' -and (Read-Host 'Open a pull request (y/N)') -match '^[yY]') {
        Push-Location $path
        try { $pr = & gh pr create --fill 2>&1 } finally { Pop-Location }
        $pr | Select-Object -Last 4 | ForEach-Object { Write-Host "  $_" }
        $result = if ($LASTEXITCODE -eq 0) { "PR opened: $([string]($pr | Select-Object -Last 1))" } else { "Pushed $branch; gh pr create failed" }
    }
    [void](Read-Host 'Enter to return')
    return $result
}

# V: the selected Claude pane's latest reply, read from the tail of its transcript (cached until the file changes).
$script:previewOn = Join-Path $stateDir 'preview.on'
$script:previewCache = @{}
function Get-Preview($transcript) {
    try {
        $fi = Get-Item $transcript -ErrorAction Stop
        $sig = "$($fi.LastWriteTimeUtc.Ticks)|$($fi.Length)"
        $c = $script:previewCache[$transcript]
        if ($c -and $c.sig -eq $sig) { return $c.val }
        # Read the last 256 KB; when no reply text is in it (big tool results can fill it), widen to 1 MB, then 4 MB.
        $tool = $null; $text = $null
        foreach ($cap in 262144, 1048576, 4194304) {
            $fs = [IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
            try {
                $total = $fs.Length
                $n = [int][math]::Min($total, $cap)
                [void]$fs.Seek(-[long]$n, 'End')
                $buf = New-Object byte[] $n
                $got = $fs.Read($buf, 0, $n)
                $rows = [Text.Encoding]::UTF8.GetString($buf, 0, $got) -split "`n"
            } finally { $fs.Dispose() }
            $first = if ($n -lt $total) { 1 } else { 0 }   # the first row of a partial read is cut off
            for ($i = $rows.Count - 1; $i -ge $first -and -not $text; $i--) {
                if (-not $rows[$i].Trim()) { continue }
                try { $o = $rows[$i] | ConvertFrom-Json } catch { continue }
                if ($o.type -ne 'assistant') { continue }
                foreach ($part in @($o.message.content)) {
                    if ($part.type -eq 'text' -and $part.text) { $text = [string]$part.text }
                    elseif ($part.type -eq 'tool_use' -and -not $tool -and -not $text) { $tool = [string]$part.name }
                }
            }
            if ($text -or $n -ge $total) { break }
        }
        $val = [pscustomobject]@{ tool = $tool; text = $text }
        $script:previewCache[$transcript] = @{ sig = $sig; val = $val }
        return $val
    } catch { return $null }
}

# Wrap text to the pane width, at most $max rows (last one ends in ~ when cut).
function Wrap-Text($text, $w, $max) {
    $t = ($text -replace '\s+', ' ').Trim()
    $rows = @()
    while ($t.Length -gt 0 -and $rows.Count -lt $max) {
        if ($t.Length -le $w) { $rows += $t; $t = ''; break }
        $cut = $t.LastIndexOf(' ', $w - 1, $w)
        if ($cut -lt 1) { $cut = $w }
        $rows += $t.Substring(0, $cut).TrimEnd()
        $t = $t.Substring($cut).TrimStart()
    }
    if ($t.Length -gt 0 -and $rows.Count) { $rows[$rows.Count - 1] = $rows[$rows.Count - 1].TrimEnd('~') + '~' }
    return , $rows
}

# Packs whole items (never split mid-item) onto rows no wider than $w, separated by two spaces.
function Pack-Items($items, $w) {
    $rows = @(); $cur = ''
    foreach ($it in $items) {
        if ($cur -and ($cur.Length + 2 + $it.Length) -gt $w) { $rows += $cur; $cur = $it }
        elseif ($cur) { $cur += '  ' + $it }
        else { $cur = $it }
    }
    if ($cur) { $rows += $cur }
    return , $rows
}

# /: incremental find. Typing moves the cursor to the first project whose name contains the text; Tab / Down
# go to the next match, Up to the previous, Enter keeps the spot, Esc goes back. Nothing is hidden or saved.
function Find-Project($projects, $cursor) {
    $start = $cursor; $at = $cursor; $q = ''
    function Match-From($from, $step) {
        for ($n = 0; $n -lt $projects.Count; $n++) {
            $j = (($from + $n * $step) % $projects.Count + $projects.Count) % $projects.Count
            if ($projects[$j].name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $j }
        }
        return -1
    }
    while ($true) {
        $note = if ($q -and (Match-From $start 1) -lt 0) { '  (no match)' } else { '' }
        Draw $projects $at "/$q$note   Enter keep, Esc cancel, Tab next"
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Escape' { return $start }
            'Enter' { return $at }
            'Backspace' { if ($q.Length) { $q = $q.Substring(0, $q.Length - 1) }; $m = Match-From $start 1; $at = if ($m -ge 0) { $m } else { $start } }
            { $_ -eq 'Tab' -or $_ -eq 'DownArrow' } { if ($q) { $m = Match-From ($at + 1) 1; if ($m -ge 0) { $at = $m } } }
            'UpArrow' { if ($q) { $m = Match-From ($at - 1) -1; if ($m -ge 0) { $at = $m } } }
            default {
                if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) {
                    $q += $k.KeyChar
                    $m = Match-From $start 1
                    $at = if ($m -ge 0) { $m } else { $start }
                }
            }
        }
    }
}

# Config folder of the project's account for an agent, or $null when that agent has no accounts configured.
function ProjectAcctDir($p, $agent) {
    if (-not @(Get-AgentAccounts $agent).Count) { return $null }
    $dir = Get-AccountDir $agent (Get-ProjectAccount $p $agent)
    if ($dir) { return $dir } else { return $null }
}

function Draw($projects, $cursor, $message) {
    Refresh-RepoInfo $projects
    # A redraw caused by a key (cursor move) reuses the data read a moment ago: only the highlight changed, and
    # re-reading every state file per key press is what made the highlighter lag.
    $snap = $script:drawSnap
    if ($script:keyRedraw -and $snap -and ((Get-Date) - $snap.time).TotalSeconds -lt 1.5) {
        $slots = $snap.slots; $statuses = $snap.statuses; $hooks = $snap.hooks; $shells = $snap.shells
    } else {
        $slots = Get-Slots
        $statuses = Get-Statuses
        $hooks = Get-Hooks
        $shells = Get-ShellCounts $slots
        $script:drawSnap = @{ time = Get-Date; slots = $slots; statuses = $statuses; hooks = $hooks; shells = $shells }
    }
    $width = [Console]::WindowWidth - 1
    $height = [Console]::WindowHeight - 1
    $lines = @()   # each: text, fg, bg

    # Which account's usage to show per agent: the highlighted project's account when it uses that agent, else the
    # agent's first (default) account. $acctName is '' when the agent has no accounts configured.
    $sel = if ($projects.Count) { $projects[$cursor] } else { $null }
    $acctName = @{}; $acctDir = @{}
    foreach ($a in 'claude', 'codex') {
        $acctName[$a] = ''; $acctDir[$a] = $null
        if (-not @(Get-AgentAccounts $a).Count) { continue }
        $src = if ($sel -and (Get-Agent $sel) -eq $a) { $sel } else { $projects | Where-Object { (Get-Agent $_) -eq $a } | Select-Object -First 1 }
        $acctName[$a] = if ($src) { Get-ProjectAccount $src $a } else { @(Get-AgentAccounts $a)[0] }
        $acctDir[$a] = Get-AccountDir $a $acctName[$a]
    }
    $uFile = $usageFile
    if ($acctDir['claude'] -and -not (Test-DefaultAccountDir 'claude' $acctDir['claude'])) {
        $uFile = Join-Path $PSScriptRoot ('usage-' + ((Split-Path $acctDir['claude'].TrimEnd('/', '\') -Leaf).ToLower() -replace '[^a-z0-9]', '_') + '.json')
    }
    $u = $null
    if ($script:keyRedraw -and $script:usageSnap -and $script:usageSnap.file -eq $uFile -and ((Get-Date) - $script:usageSnap.time).TotalSeconds -lt 1.5) { $u = $script:usageSnap.data }
    else {
        try { if (Test-Path $uFile) { $u = Get-Content $uFile -Raw -ErrorAction Stop | ConvertFrom-Json } } catch { $u = $null }
        $script:usageSnap = @{ file = $uFile; time = Get-Date; data = $u }
    }
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
                $cu = Get-CodexUsage $acctDir['codex']
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
        $hd = if ($acctName[$a] -and @(Get-AgentAccounts $a).Count -gt 1) { "-- $a @$($acctName[$a]) --" } else { "-- $a --" }
        $usageBlock += , @($hd, 'Cyan', $null)
        foreach ($ul in (UsageLinesFor $a)) { $usageBlock += , $ul }
    }
    # Summary of all open agents, in its own section below the per-agent usage and above the keys.
    $agentsBlock = @()
    $ac =Get-AgentCounts $slots $statuses $hooks $projects
    if ($ac.open) {
        $per = ($ac.by.Keys | ForEach-Object { "$($ac.by[$_]) $_" }) -join ', '
        $acColor = if ($ac.waiting) { 'Magenta' } elseif ($ac.working) { 'Yellow' } else { 'Gray' }
        $acRows = Pack-Items @("agents: $($ac.open) open ($per)", "$($ac.working) working,", "$($ac.waiting) waiting,", "$($ac.idle) idle") $width
        $agentsBlock += , @('-- agents --', 'Cyan', $null)
        foreach ($r in $acRows) { $agentsBlock += , @($r, $acColor, $null) }
    }
    # Key help, wrapped to the window width (whole shortcuts per row).
    $keyItems = @('Enter open', 'M move', 'R sync', 'X close', 'D del', 'A add', 'G agent', 'U account', 'F diff', 'W tree', 'H hooks',
        'Shift+Up/Down reorder', "T toast $(if (Test-Path $script:toastOff) { 'off' } else { 'on' })", 'P push/PR', 'S agents', '/ find',
        "V preview $(if (Test-Path $script:previewOn) { 'on' } else { 'off' })")
    $keyRows = Pack-Items $keyItems $width
    $legendRows = Pack-Items @("$($icon.changed)n changed", "$($icon.ahead)push", "$($icon.behind)pull", "$($icon.wtree)wt=worktree", "$($icon.compact)=compacts at") $width

    # Reserve room for the detail block and key help; scroll the project list to fit.
    # Preview rows (V): header plus up to 4 wrapped lines of the selected pane's latest reply.
    $previewRows = @()
    if ((Test-Path $script:previewOn) -and $projects.Count) {
        $pp = $projects[$cursor]
        $pst = $statuses[(Get-NormPath $pp.path)]
        $pagent = Get-Agent $pp
        if (-not $slots.ContainsKey((Get-NormPath $pp.path))) { $previewRows += , @('-- preview: not open --', 'DarkGray', $null) }
        elseif ($pagent -ne 'claude') { $previewRows += , @("-- preview: claude only --", 'DarkGray', $null) }
        else {
            $pv = if ($pst -and $pst.transcript -and (Test-Path $pst.transcript)) { Get-Preview $pst.transcript } else { $null }
            $head = '-- last reply --'
            if ($pv -and $pv.tool) { $head = "-- running $($pv.tool) --" }
            $previewRows += , @($head, 'Cyan', $null)
            if ($pv -and $pv.text) { foreach ($r in (Wrap-Text $pv.text ([math]::Max(10, $width - 2)) 8)) { $previewRows += , @("  $r", 'Gray', $null) } }
            else { $previewRows += , @('  (nothing yet)', 'DarkGray', $null) }
        }
    }
    $detailHeight = 4 + $usageBlock.Count + $agentsBlock.Count +$previewRows.Count + 1 + $keyRows.Count + $legendRows.Count   # separator, path, model/hint, message, usage block, preview, keys header + wrapped keys + legend
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
        $rows = if (HasInfo $i) { 3 } else { 1 }   # main row, optional model/context rows
        if (Get-RepoLine $projects[$i].path) { $rows += 1 }   # repo row, only for git folders
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
            if ($st -and (ToDate $st.updated) -ge (ToDate $slot.since)) {
                $mtime = $null
                if ($st.transcript) { try { $tmt = [IO.File]::GetLastWriteTime([string]$st.transcript); if ($tmt.Year -gt 1700) { $mtime = $tmt } } catch { } }   # a missing file reads as year 1601
                if ($mtime -and ((Get-Date) - $mtime).TotalSeconds -lt $busySeconds) { $state = 'working'; $fg = 'Yellow' }
                elseif ($mtime) { $state = 'idle ' + (Age $mtime) }
                else { $state = 'idle' }
            }
            # agy's status line reports its own activity (agy-statusline.ps1).
            if ($agent -ne 'claude' -and $st -and $st.agent -eq $agent -and $st.activity -and (ToDate $st.updated) -ge (ToDate $slot.since)) {
                switch (Get-EffActivity $st) {
                    'working' { $state = 'working'; $fg = 'Yellow' }
                    'waiting' { $state = '! waiting'; $fg = 'Magenta' }
                    'done'    { $state = 'done ' + (Age $(if ($st.activity_at) { ToDate $st.activity_at } else { ToDate $st.updated })); $fg = 'Cyan' }
                    'idle'    { $state = 'idle ' + (Age (ToDate $st.updated)); $fg = 'Green' }
                }
            }
            # Hooks know exactly when Claude is working, waiting on you, or finished; prefer them.
            $hk = $hooks[$key]
            if ($hk -and (ToDate $hk.updated) -ge (ToDate $slot.since)) {
                switch ($hk.status) {
                    'working' { $state = 'working'; $fg = 'Yellow' }
                    'waiting' {
                        # No hook fires when you answer a prompt; a transcript write after it means Claude resumed.
                        # Codex has no transcript: its newest rollout log write plays that part.
                        $wm = if ($mtime) { $mtime } elseif ($agent -eq 'codex') { [void](Get-CodexUsage (ProjectAcctDir $p 'codex')); $script:codexMtByDir[$key] } else { $null }
                        $resumed = $wm -and ($wm -gt (ToDate $hk.updated).AddSeconds(2))
                        if ($resumed) { $state = 'working'; $fg = 'Yellow' } else { $state = '! waiting'; $fg = 'Magenta' }
                    }
                    'done'    { $state = 'done ' + (Age (ToDate $hk.updated)); $fg = 'Cyan' }
                }
            }
        }
        $pointer = if ($i -eq $cursor) { '>' } else { ' ' }
        $shown = if ($p.name.Length -gt 12) { $p.name.Substring(0, 11) + '~' } else { $p.name }
        # An agent that reports nothing (agy/Codex without their hooks set up) just shows running.
        if ($slot -and $agent -ne 'claude' -and $state -eq 'starting') { $state = 'running'; $fg = 'Green' }
        $tag = if ($agent -eq 'claude') { '' } else { " ($agent)" }
        # Account name, only for agents that have more than one account in accounts.json.
        if (@(Get-AgentAccounts $agent).Count -gt 1) { $tag += " @$(Get-ProjectAccount $p $agent)" }
        # Agents without a model/context block have no third row for the shell count, so it goes on the main row.
        $subN = Get-SubCount $p $slot
        $rowShells = if ($slot -and -not (HasInfo $i) -and $shells[[int]$slot.slot]) { " $($icon.shell) $($shells[[int]$slot.slot]) sh" } else { '' }
        # Sub-agents sit beside the shell count: on the third row when there is one, else on the main row.
        $subText = if ($subN) { "  $($icon.sub) $subN" } else { '' }
        if (-not (HasInfo $i)) { $rowShells += $subText }
        $text = '{0} {1,-12} {2,-3} {3}{4}{5}' -f $pointer, $shown, $slotText, $state, $tag, $rowShells
        if ($slot) { $text += Get-DelegationText $p.path }   # a delegation runs from an open agent, so only open rows can have one
        # Selected row is white on blue (dark magenta when it needs you) so it stays readable.
        $bg = if ($i -ne $cursor) { $null } elseif ($fg -eq 'Magenta') { 'DarkMagenta' } else { 'DarkBlue' }
        $lines += , @($text, $(if ($i -eq $cursor) { 'White' } else { $fg }), $bg)
        if (HasInfo $i) {
            $m = "$($icon.model) " + $(if ($st -and $st.model) { [string]$st.model } else { '--' })
            $eff = if ($st -and $st.effort) { [string]$st.effort } elseif ($agent -eq 'codex') { Get-CodexEffort (ProjectAcctDir $p 'codex') } else { $null }
            if ($eff) { $m += "  $($icon.effort) $eff" }
            $lines += , @("    $m", 'Gray', $bg)
            # Codex has no ctx in its state file: take it from the project's newest rollout log.
            $cv = if ($st -and $null -ne $st.ctx) { $st.ctx } elseif ($agent -eq 'codex') { [void](Get-CodexUsage (ProjectAcctDir $p 'codex')); $script:codexCtxByDir[(Get-NormPath $p.path)] } else { $null }
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
        if ($repo) { $lines += , @("    $repo", $(if ($i -eq $cursor) { 'Gray' } else { 'DarkGray' }), $bg) }   # no git repo: no row (dim grey is unreadable on the highlight)
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
        # Login behind this project's account: real email/plan, not just the label from accounts.json.
        $selAgent = Get-Agent $p
        $selSlot = $slots[(Get-NormPath $p.path)]
        if ($selSlot -and $selSlot.agent) { $selAgent = Get-Agent $selSlot }
        $accNames = @(Get-AgentAccounts $selAgent)
        if ($accNames.Count) {
            $acc = Get-ProjectAccount $p $selAgent
            $who = Get-AccountIdentity $selAgent $acc
            $color = 'Gray'
            if ($who -eq 'not logged in') { $who += ' (the CLI will ask to sign in)'; $color = 'Yellow' }
            else {
                # Two accounts of one CLI that are the same login are almost always a setup mistake.
                foreach ($other in $accNames) {
                    if ($other -ne $acc -and (Get-AccountIdentity $selAgent $other) -eq (Get-AccountIdentity $selAgent $acc) -and $who -ne 'checking...') { $who += "  = same as '$other'!"; $color = 'Yellow'; break }
                }
            }
            $bottom += , @("$selAgent @${acc}: $who", $color, $null)
        }
    }
    $bottom += , @($message, 'Yellow', $null)
    foreach ($pr in $previewRows) { $bottom += , $pr }
    foreach ($ul in $usageBlock) { $bottom += , $ul }
    foreach ($al in $agentsBlock) { $bottom += , $al }
    # One status line on the last row: keys, then the git/compact symbol legend (cut off by width if needed).
    $bottom += , @('-- keys --', 'Cyan', $null)
    foreach ($r in $keyRows) { $bottom += , @($r, 'Gray', $null) }
    foreach ($r in $legendRows) { $bottom += , @($r, 'DarkGray', $null) }
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
$generated = @(Initialize-GeneratedConfigs)
if ($generated.Count) { $message = "Hook files ready in windows\generated ($($generated.Count)); see README" }
$hookPending = @(Get-HookPending)
if ($hookPending.Count) { $message = "Press H to install status hooks for: $($hookPending -join ', ')" }
$lastRestore = [datetime]::MinValue
$lastOpenCheck = [datetime]::MinValue
$savedOpen = $null
$pendingOpen = $null
$pendingSince = [datetime]::MinValue
$lastDraw = [datetime]::MinValue
$lastPaneCheck = [datetime]::MinValue
$dirty = $true
$follow = $null
$lastFocusCheck = [datetime]::MinValue
$lastFocusTitle = ''
$lastSize = ''
while ($true) {
  # One bad tick (a half-read file, a failed wt call) must not kill the dashboard: log it and carry on.
  try {
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
        $closedNow = @()
        foreach ($dead in @(Get-DeadPanes)) {
            # A hand-closed pane can leave its CLI running; stop it before Remove-Pane deletes the slot file that names the wrapper.
            try {
                $deadJob = Get-Content (Join-Path $stateDir "slot$dead.json") -Raw -ErrorAction Stop | ConvertFrom-Json
                [void](Stop-OrphanedSlotChildren $deadJob.pid $deadJob.since)
            } catch { }
            if (Remove-Pane $dead) { $closedNow += $dead }
            else {
                # Last pane closed by hand: nobody is left to rewrite its heartbeat, so forget its files and let the
                # next Enter split a fresh pane off the dashboard (New-FirstPane).
                foreach ($ext in 'pane', 'assign', 'json', 'close', 'exit') { Remove-Item (Join-Path $stateDir "slot$dead.$ext") -Force -ErrorAction SilentlyContinue }
                if ((Get-PaneCount) -lt 2) {
                    Set-Content (Join-Path $stateDir 'nopanes') $dead
                    $message = "Pane $dead closed; the next project opens a new pane"
                    $dirty = $true
                }
            }
        }
        if ($closedNow.Count) {
            # Once per batch of closes: reshape for the open panes, then read every place back so the layout matches the screen.
            $label = $closedNow -join ', '
            $reshaped = Optimize-Layout
            $message = if (Sync-Layout) { if ($reshaped) { "Pane $label closed, panes reshaped" } else { "Pane $label closed, layout re-read" } } else { "Pane $label closed (press R to re-read the layout)" }
            [void](Focus-Dashboard)
            $dirty = $true
        }
    }

    # Focus moved to a pane: put the highlight on that pane's project. The window title follows the focused pane;
    # only a change of title moves the cursor, so arrow keys on the dashboard are never fought.
    if (((Get-Date) - $lastFocusCheck).TotalSeconds -ge 0.7 -and -not $restore.Count) {
        $lastFocusCheck = Get-Date
        try {
            $ft = Get-FocusedTitle
            if ($ft -and $ft -ne $lastFocusTitle) {
                $lastFocusTitle = $ft
                if ($ft -notmatch '^dashboard') {
                    $n = $null
                    if ($ft -match '^pane (\d)$') { $n = [int]$Matches[1] } else { $byName = Get-SlotNames; if ($null -ne $byName[$ft]) { $n = [int]$byName[$ft] } }
                    if ($n) {
                        $sf = Join-Path $stateDir "slot$n.json"
                        if (-not (Test-Path $sf)) { $sf = Join-Path $stateDir "slot$n.assign" }
                        $sp = Get-Content $sf -Raw -ErrorAction Stop | ConvertFrom-Json
                        $np = Get-NormPath $sp.path
                        for ($i = 0; $i -lt $projects.Count; $i++) {
                            if ((Get-NormPath $projects[$i].path) -eq $np) { if ($cursor -ne $i) { $cursor = $i; $dirty = $true }; break }
                        }
                    }
                }
            }
        } catch { }
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
                # Held-key repeats queue up: fold the plain Up/Down presses already waiting into one move and draw once.
                if (-not ($key.Modifiers -band [ConsoleModifiers]::Shift) -and $projects.Count) {
                    $steps = -1
                    while ([Console]::KeyAvailable) {
                        $nk = [Console]::ReadKey($true)
                        if ($nk.Modifiers -band [ConsoleModifiers]::Shift) { break }
                        if ($nk.Key -eq 'UpArrow') { $steps-- } elseif ($nk.Key -eq 'DownArrow') { $steps++ } else { break }
                    }
                    $cursor = (($cursor + $steps) % $projects.Count + $projects.Count) % $projects.Count
                }
                elseif ($key.Modifiers -band [ConsoleModifiers]::Shift) {
                    if ($projects.Count) {
                        # The two swap places in the sorted list, so the cursor moves with the project before the redraw.
                        if (Move-ProjectOrder $projects $cursor -1) { $cursor-- } else { $message = 'Already first in its group' }
                    }
                }
                elseif ($projects.Count) { $cursor = ($cursor - 1 + $projects.Count) % $projects.Count }
            }
            'DownArrow' {
                if (-not ($key.Modifiers -band [ConsoleModifiers]::Shift) -and $projects.Count) {
                    $steps = 1
                    while ([Console]::KeyAvailable) {
                        $nk = [Console]::ReadKey($true)
                        if ($nk.Modifiers -band [ConsoleModifiers]::Shift) { break }
                        if ($nk.Key -eq 'UpArrow') { $steps-- } elseif ($nk.Key -eq 'DownArrow') { $steps++ } else { break }
                    }
                    $cursor = (($cursor + $steps) % $projects.Count + $projects.Count) % $projects.Count
                }
                elseif ($key.Modifiers -band [ConsoleModifiers]::Shift) {
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
            'U' {
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    $agent = Get-Agent $p
                    $names = @(Get-AgentAccounts $agent)
                    if ((Get-Slots).ContainsKey((Get-NormPath $p.path))) { $message = "Close $($p.name) first (X) to change its account" }
                    elseif ($names.Count -lt 2) { $message = "No accounts for $agent in accounts.json (see accounts.example.json)" }
                    else {
                        $next = $names[([array]::IndexOf($names, (Get-ProjectAccount $p $agent)) + 1) % $names.Count]
                        Set-ProjectAccount $p.path $agent $next
                        $projects = @(Get-Projects)
                        $message = "$($p.name) will use $agent account '$next'"
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
                    # wt treats ';' as a command separator; '\;' passes a literal one through (a folder name may contain it).
                    $wtName = $p.name -replace ';', '\;'; $wtPath = $p.path -replace ';', '\;'
                    Invoke-Wt "new-tab $script:wtProfile --title `"diff $wtName`" -d `"$wtPath`" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\diffview.ps1`" -Path `"$wtPath`""
                    $message = "Diff of $($p.name) opened in a new tab"
                }
            }
            'T' {
                if (Test-Path $script:toastOff) { Remove-Item $script:toastOff -Force -ErrorAction SilentlyContinue; $message = 'Toasts on' }
                else { Set-Content $script:toastOff (Get-Date).ToString('o'); $message = 'Toasts off' }
            }
            'S' {
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    $agent = Get-Agent $p
                    if ($agent -notin 'claude', 'codex', 'agy') { $message = "$agent has no agents screen" }
                    else {
                        $acct = Get-ProjectAccount $p $agent
                        $acctArg = ''
                        if ($acct) { $acctArg = " -Account `"$acct`"" }
                        $wtName = $p.name -replace ';', '\;'; $wtPath = $p.path -replace ';', '\;'
                        Invoke-Wt "new-tab $script:wtProfile --title `"agents $wtName`" -d `"$wtPath`" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\agentsview.ps1`" -Path `"$wtPath`" -Agent $agent$acctArg"
                        $message = "$agent agents for $($p.name) opened in a new tab"
                    }
                }
            }
            'P' {
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    Clear-Host
                    $message = Publish-Project $p
                    Clear-Host
                }
            }
            'H' {
                # Opt-in: copy tai's status hooks into the CLIs' own configs (backup + merge, asks per CLI).
                $targets = @((Get-HookTargets).Keys | Where-Object { Test-AgentInstalled $_ })
                Clear-Host
                $message = if ($targets.Count) { Install-AgentHooks $targets } else { 'No CLI with hook support is installed' }
                Clear-Host
            }
            'V' {
                if (Test-Path $script:previewOn) { Remove-Item $script:previewOn -Force -ErrorAction SilentlyContinue; $message = 'Preview off' }
                else { Set-Content $script:previewOn (Get-Date).ToString('o'); $message = 'Preview on' }
            }
            { $_ -eq 'Oem2' -or $_ -eq 'Divide' } {
                if ($projects.Count -gt 1) { $cursor = Find-Project $projects $cursor }
            }
            'W' {
                # Git worktree of a branch, listed as its own project right below the project it came from.
                # A new branch gets a new worktree; an existing branch reuses its worktree (or gets one if it has none).
                if ($projects.Count) {
                    $p = $projects[$cursor]
                    Clear-Host
                    $branch = (Read-Host "Branch for a worktree of '$($p.name)' (new or existing, blank cancels)").Trim()
                    if ($branch) {
                        $safe = $branch -replace '[^\w.-]', '-'
                        $dir = (Split-Path $p.path -Parent) + '\' + (Split-Path $p.path -Leaf) + '-' + $safe
                        # Worktree that already has this branch checked out (git worktree list --porcelain: "worktree <path>" then "branch refs/heads/<name>").
                        $existing = $null
                        $wtPath = $null
                        foreach ($l in (git -C $p.path worktree list --porcelain 2>$null)) {
                            if ($l -like 'worktree *') { $wtPath = $l.Substring(9) }
                            elseif ($l -eq "branch refs/heads/$branch") { $existing = $wtPath }
                        }
                        $ok = $true
                        $out = $null
                        if ($existing) { $dir = $existing.Replace('/', '\') }
                        else {
                            $null = & git -C $p.path show-ref --verify --quiet "refs/heads/$branch" 2>&1
                            if ($LASTEXITCODE -eq 0) { $out = & git -C $p.path worktree add $dir $branch 2>&1 }
                            else { $out = & git -C $p.path worktree add -b $branch $dir 2>&1 }
                            $ok = ($LASTEXITCODE -eq 0)
                        }
                        if ($ok) {
                            try {
                                $listed = @($projects | Where-Object { (Get-NormPath $_.path) -eq (Get-NormPath $dir) }) | Select-Object -First 1
                                if ($listed) {
                                    $follow = $listed.name
                                    $message = "Branch $branch is already listed as $($listed.name)"
                                } else {
                                    $projects = @(Add-Projects $projects @($dir) $null)
                                    $new = $projects[$projects.Count - 1]
                                    # Same CLI as the project it came from (the list is grouped by CLI), and placed right below it.
                                    if ($p.agent) { $new | Add-Member -NotePropertyName agent -NotePropertyValue $p.agent -Force }
                                    $rest = @($projects | Select-Object -First ($projects.Count - 1))
                                    $at = 0
                                    for ($i = 0; $i -lt $rest.Count; $i++) { if ($rest[$i].name -eq $p.name) { $at = $i + 1; break } }
                                    $projects = @($rest | Select-Object -First $at) + $new + @($rest | Select-Object -Skip $at)
                                    Save-Projects $projects
                                    $follow = $new.name
                                    $message = if ($existing) { "Existing worktree of $branch added" } else { "Worktree $safe added" }
                                }
                            } catch { $message = $_.Exception.Message }
                        } else { $message = ([string]($out | Select-Object -Last 1)) }
                    }
                    Clear-Host
                }
            }
            'R' {
                Draw $projects $cursor 'Re-reading layout...'
                $message = if (Sync-Layout) { 'Layout re-read' } else { 'Could not read the layout' }
                [void](Focus-Dashboard)   # Sync-Layout leaves focus on the last pane it probed
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
                    if ((Get-Slots).ContainsKey((Get-NormPath $p.path))) {
                        $message = "$($p.name) is open; close it with X first"
                    } else {
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
    }

    # Window resized: wipe leftovers and redraw at the new size right away.
    $size = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
    if ($size -ne $lastSize) { $lastSize = $size; Clear-Host; $dirty = $true }

    if ($dirty -or ((Get-Date) - $lastDraw).TotalSeconds -ge 3) {
        if (((Get-Date) - $script:lastSweep).TotalHours -ge 1) { try { Clear-StaleState } catch { $script:lastSweep = Get-Date } }
        $projects = @(Get-SortedProjects)
        if ($cursor -ge $projects.Count) { $cursor = [math]::Max(0, $projects.Count - 1) }
        $wasKeyRedraw = $script:keyRedraw
        $drawn = $false
        try { Draw $projects $cursor $message; $drawn = $true }
        catch { Start-Sleep -Milliseconds 200 }   # transient read error; next tick redraws
        # Reuse the state Draw just read instead of listing and parsing every state file a second time.
        if (-not $wasKeyRedraw) {
            try {
                $sn = $script:drawSnap
                if ($drawn -and $sn) { Notify-Waiting $projects $sn.slots $sn.hooks } else { Notify-Waiting $projects }
            } catch { }
        }
        $script:keyRedraw = $false
        $lastDraw = Get-Date
        $dirty = $false
    } else {
        Start-Sleep -Milliseconds 80
    }
  } catch {
    Write-Boot "dashboard loop error: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    $dirty = $true
    Start-Sleep -Milliseconds 300
  }
}
