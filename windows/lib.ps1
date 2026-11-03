# Shared project-list helpers, dot-sourced by tai.ps1 and dashboard.ps1.
# TAI_CONF (a folder) points both the Windows and Linux versions at one shared projects.json.
$script:configPath = if ($env:TAI_CONF) { Join-Path $env:TAI_CONF 'projects.json' } else { Join-Path $PSScriptRoot 'projects.json' }
$script:registryPath = Join-Path (Split-Path $PSScriptRoot) 'agents.json'   # per-CLI facts shared with linux/
$script:libRoot = $PSScriptRoot
$script:stateRoot = Join-Path $PSScriptRoot 'state'
$script:wtProfile = '-p terminal_ai'   # profile with the smaller font; see setup-profile.ps1
$script:psCmd = 'powershell.exe -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File'

# Fills in this checkout's folder in every tracked windows\*.example.json hook/settings template and writes the result
# to windows\generated\ (git-ignored), so nothing has to be edited by hand before copying it into a CLI's own config.
# Existing generated files are left alone (they may have been edited); delete one to regenerate it. Returns the names created.
function Initialize-GeneratedConfigs {
    $made = @()
    try {
        $outDir = Join-Path $script:libRoot 'generated'
        $repoRoot = (Split-Path $script:libRoot -Parent) -replace '\\', '/'
        foreach ($f in Get-ChildItem -LiteralPath $script:libRoot -Filter '*.example.json' -File) {
            # The project list is not a hook template, and slot.ps1 already makes claude-settings.json itself.
            if ($f.Name -in 'projects.example.json', 'claude-settings.example.json') { continue }
            $target = Join-Path $outDir ($f.Name -replace '\.example\.json$', '.json')
            if (Test-Path -LiteralPath $target) { continue }
            New-Item -ItemType Directory -Force $outDir | Out-Null
            $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8).Replace('C:/path/to/terminal_ai', $repoRoot)
            $tmp = "$target.$PID.tmp"
            [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
            Move-Item -LiteralPath $tmp -Destination $target -Force
            $made += ($f.Name -replace '\.example\.json$', '.json')
        }
    } catch { }
    $made   # emitted item by item; callers wrap the call in @(...)
}

# ---- Opt-in install of the generated hook files into each CLI's own config (dashboard key H) ----
# Targets: where the CLI reads hooks, the generated file to take them from, and whether to merge into an existing file
# ('merge') or own the whole file ('own'). Schemas for qwen/cursor/copilot come from docs and are unconfirmed.
function Get-HookTargets {
    $h = $env:USERPROFILE
    [ordered]@{
        codex   = @{ file = (Join-Path $h '.codex\hooks.json');          src = 'codex-hooks.json';   mode = 'merge'
                     note = 'Codex also needs [features] hooks = true in ~/.codex/config.toml and trusting the hooks on first run.' }
        qwen    = @{ file = (Join-Path $h '.qwen\settings.json');        src = 'qwen-settings.json'; mode = 'merge'; note = '' }
        cursor  = @{ file = (Join-Path $h '.cursor\hooks.json');         src = 'cursor-hooks.json';  mode = 'merge'; note = '' }
        copilot = @{ file = (Join-Path $h '.copilot\hooks\tai.json');    src = 'copilot-hooks.json'; mode = 'own';   note = '' }
    }
}

function Get-HookAnswers {
    $f = Join-Path $script:stateRoot 'hooks-install.json'
    $r = @{}
    try { $o = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json; foreach ($n in $o.PSObject.Properties) { $r[$n.Name] = [string]$n.Value } } catch { }
    $r
}

function Save-HookAnswers($answers) {
    $f = Join-Path $script:stateRoot 'hooks-install.json'
    New-Item -ItemType Directory -Force $script:stateRoot | Out-Null
    $tmp = "$f.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($answers | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $f -Force
}

# CLIs that are installed, have a hook target and have not been answered yet.
function Get-HookPending {
    $ans = Get-HookAnswers
    @((Get-HookTargets).Keys | Where-Object { $ans.ContainsKey($_) -eq $false -and (Test-AgentInstalled $_) })
}

# Adds our hook entries to an existing config object without touching anything else. An event that already points at this
# checkout's hook.ps1 is left alone, so running it twice changes nothing. Returns the number of entries added.
function Merge-HookConfig($cfg, $gen, $marker) {
    $added = 0
    if (-not $cfg.PSObject.Properties['hooks']) { $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    foreach ($ev in $gen.hooks.PSObject.Properties) {
        $have = @(if ($cfg.hooks.PSObject.Properties[$ev.Name]) { $cfg.hooks.($ev.Name) })   # @() keeps a single entry an array
        if ((ConvertTo-Json $have -Depth 10 -Compress) -like "*$marker*") { continue }
        $merged = $have + @($ev.Value)
        if ($cfg.hooks.PSObject.Properties[$ev.Name]) { $cfg.hooks.($ev.Name) = $merged }
        else { $cfg.hooks | Add-Member -NotePropertyName $ev.Name -NotePropertyValue $merged }
        $added++
    }
    foreach ($top in $gen.PSObject.Properties) {   # other top-level keys (e.g. "version") only if the user has none
        if ($top.Name -ne 'hooks' -and -not $cfg.PSObject.Properties[$top.Name]) { $cfg | Add-Member -NotePropertyName $top.Name -NotePropertyValue $top.Value }
    }
    $added
}

# Asks, then installs, for each CLI in $names. Returns a one-line summary. The user's file is copied to *.tai-backup first.
function Install-AgentHooks($names) {
    $targets = Get-HookTargets
    $ans = Get-HookAnswers
    $marker = ((Split-Path $script:libRoot -Parent) -replace '\\', '/') + '/windows/hook.ps1'
    Initialize-GeneratedConfigs | Out-Null
    $done = @(); $skipped = @(); $failed = @()
    foreach ($n in $names) {
        $t = $targets[$n]
        if (-not $t) { continue }
        $gensrc = Join-Path $script:libRoot ('generated\' + $t.src)
        $what = if (Test-Path -LiteralPath $t.file) { "$(if ($t.mode -eq 'own') { 'replace' } else { 'merge into' }) $($t.file) (backup kept)" } else { "create $($t.file)" }
        Write-Host ''
        Write-Host "${n}: $what" -ForegroundColor Cyan
        if ((Read-Host 'Install tai status hooks (y/N)') -notmatch '^[yY]') { $ans[$n] = 'declined'; $skipped += $n; continue }
        try {
            $gen = [IO.File]::ReadAllText($gensrc, [Text.Encoding]::UTF8) | ConvertFrom-Json
            New-Item -ItemType Directory -Force (Split-Path $t.file -Parent) | Out-Null
            $exists = Test-Path -LiteralPath $t.file
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
            $write = $true
            if ($t.mode -eq 'own' -or -not $exists) {
                $text = [IO.File]::ReadAllText($gensrc, [Text.Encoding]::UTF8)
                if ($exists) {
                    if ([IO.File]::ReadAllText($t.file, [Text.Encoding]::UTF8) -ceq $text) { $write = $false }   # already identical
                    else { Copy-Item -LiteralPath $t.file -Destination "$($t.file).tai-backup-$stamp" }
                }
            } else {
                $cfg = [IO.File]::ReadAllText($t.file, [Text.Encoding]::UTF8) | ConvertFrom-Json   # throws on invalid JSON: file untouched
                if (-not $cfg) { throw 'config is empty or not a JSON object' }
                $added = Merge-HookConfig $cfg $gen $marker
                if ($added -gt 0) {
                    Copy-Item -LiteralPath $t.file -Destination "$($t.file).tai-backup-$stamp"   # backup only when the file changes
                    $text = $cfg | ConvertTo-Json -Depth 20
                } else { $write = $false }   # already installed
            }
            if ($write) {
                $tmp = "$($t.file).$PID.tmp"
                [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
                Move-Item -LiteralPath $tmp -Destination $t.file -Force
            }
            $ans[$n] = 'installed'; $done += $n
            if ($t.note) { Write-Host $t.note -ForegroundColor Yellow }
        } catch {
            $failed += $n
            Write-Host "${n}: not installed - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Save-HookAnswers $ans
    $parts = @()
    if ($done.Count) { $parts += "installed: $($done -join ', ')" }
    if ($skipped.Count) { $parts += "skipped: $($skipped -join ', ')" }
    if ($failed.Count) { $parts += "failed: $($failed -join ', ')" }
    if ($failed.Count -or ($done | Where-Object { $targets[$_].note })) { Read-Host 'Press Enter to continue' | Out-Null }
    if ($parts.Count) { 'Hooks ' + ($parts -join '; ') } else { 'Hooks: nothing to do' }
}

# Boot timeline in state\boot.log (tai.ps1 starts it fresh at every launch): shows where start-up time goes.
function Write-Boot($what) {
    try { Add-Content (Join-Path $script:stateRoot 'boot.log') ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $what) } catch { }
}

# ---- Pane layout ----------------------------------------------------------------
# The workspace grows as projects are opened (pane N is created when the Nth project opens):
#   1 pane : dashboard | 1
#   2 panes: dashboard | 1 | 2                     (side by side)
#   3 panes: dashboard | 1 | 2 over 3              (one large, two helpers)
#   4 panes: dashboard | 1 over 4 | 2 over 3       (2x2)
# wt moves focus in layout-tree order, which differs per pane count; index 0 is the dashboard.
$script:paneOrder = @{
    1 = @(0, 1)
    2 = @(0, 1, 2)
    3 = @(0, 1, 2, 3)
    4 = @(0, 1, 4, 2, 3)
}
# Beyond 4 panes (and on windows of other shapes) each new pane halves the biggest pane along
# its longer side, as long as both halves stay at least $minCols x $minRows cells. The window
# decides how many panes fit. Rectangles (x, y, w, h as fractions of the whole window) of each
# place in the focus order are kept in state\rects.json; the dashboard is the left 20%.
$script:maxPanes = 9
$script:minCols = 55
$script:minRows = 24
$script:cells = $null   # (columns, rows) of the whole window; measured from the dashboard when null
$script:firstRect = @(0.2, 0.0, 0.8, 1.0)

# Monitor work area in character cells: the cell size in pixels comes from this Windows Terminal window
# (its pixel size / its $winCols x $winRows cells). $null when the window or monitor can't be read.
function Get-MonitorCells($winCols, $winRows) {
    try {
        if (-not ('TaiWin' -as [type])) {
            Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Drawing; using System.Windows.Forms;
public static class TaiWin {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    public static int[] Info(IntPtr h) {
        RECT r; if (!GetWindowRect(h, out r)) return null;
        Rectangle wa = Screen.FromHandle(h).WorkingArea;
        return new int[] { r.R - r.L, r.B - r.T, wa.Width, wa.Height };
    }
}
'@
        }
        $id = $PID
        for ($i = 0; $i -lt 8 -and $id; $i++) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
            if (-not $p) { return $null }
            if ($p.Name -eq 'WindowsTerminal.exe') {
                $h = (Get-Process -Id $id).MainWindowHandle
                if ($h -eq [IntPtr]::Zero) { return $null }
                $v = [TaiWin]::Info($h)
                if (-not $v -or $v[0] -lt 100 -or $v[1] -lt 100) { return $null }
                return @([int]($v[2] / ($v[0] / $winCols)), [int]($v[3] / ($v[1] / $winRows)))
            }
            $id = $p.ParentProcessId
        }
    } catch { }
    return $null
}

# Whole-window size in character cells. The dashboard is 20% of the width.
function Get-WindowCells {
    if ($script:cells) { return $script:cells }
    $file = Join-Path $script:stateRoot 'cells.json'
    # With one pane the dashboard is exactly 20% wide, so that is the only time the estimate is reliable.
    # Later the user may resize the dashboard pane, which would inflate it and let too many panes open.
    if ((Get-PaneCount) -gt 1) {
        try {
            $saved = Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json
            $out = @(); foreach ($x in $saved) { $out += [int]$x }   # PS 5.1 hands the array over as one object
            if ($out.Count -eq 2) { return $out }
        } catch { }
    }
    $c = 240; $r = 60
    try {
        $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
        if ($w -gt 10 -and $h -gt 5) { $c = [int]($w / 0.2); $r = $h }
    } catch { }
    if ((Get-PaneCount) -le 1) {
        # Size the layout for the whole monitor, as if the window were maximised.
        # Compiling the Win32 helper costs about a second, so remember the result per initial window size
        # (same monitor, font and maximised window give the same dashboard size). cells.cache.json survives launches.
        $cacheFile = Join-Path $script:stateRoot 'cells.cache.json'
        $key = "$c x $r"
        $m = $null
        try {
            $cache = Get-Content $cacheFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($cache.key -eq $key) { $m = @([int]$cache.cells[0], [int]$cache.cells[1]) }
        } catch { }
        if (-not $m) {
            $m = Get-MonitorCells $c $r
            if ($m) { try { ConvertTo-Json -InputObject ([pscustomobject]@{ key = $key; cells = @($m[0], $m[1]) }) -Compress | Set-Content $cacheFile } catch { } }
        }
        if ($m) { $c = $m[0]; $r = $m[1] }
        try { New-Item -ItemType Directory -Force $script:stateRoot | Out-Null; ConvertTo-Json -InputObject @($c, $r) -Compress | Set-Content $file } catch { }
    }
    return @($c, $r)
}

function Get-Rects($count) {
    $rects = @()
    try {
        $parsed = Get-Content (Join-Path $script:stateRoot 'rects.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($r in $parsed) { $rects += , @($r | ForEach-Object { [double]$_ }) }
    } catch { $rects = @() }
    if ($rects.Count -eq $count) { return , $rects }
    # No usable record (dashboard restarted by hand): rebuild it by replaying the splits.
    $rects = @(, $script:firstRect)
    while ($rects.Count -lt $count) {
        $plan = Get-NextSplit $rects
        if (-not $plan) { break }
        $rects = $plan.rects
    }
    return , $rects
}

function Save-Rects($rects) {
    New-Item -ItemType Directory -Force $script:stateRoot | Out-Null
    ConvertTo-Json -InputObject @($rects) -Compress | Set-Content (Join-Path $script:stateRoot 'rects.json')
}

# The two halves of rectangle $r: '-V' = side by side (left, right), '-H' = stacked (top, bottom).
function Split-Rect($r, $dir) {
    if ($dir -eq '-V') { return @{ a = @($r[0], $r[1], ($r[2] / 2), $r[3]); b = @(($r[0] + $r[2] / 2), $r[1], ($r[2] / 2), $r[3]) } }
    return @{ a = @($r[0], $r[1], $r[2], ($r[3] / 2)); b = @($r[0], ($r[1] + $r[3] / 2), $r[2], ($r[3] / 2)) }
}

# Whether a pane of $w x $h cells can be split in $dir and leave both halves at least minCols x minRows.
function Test-SplitFits($w, $h, $dir) {
    if ($dir -eq '-V') { return ($w / 2 -ge $script:minCols) -and ($h -ge $script:minRows) }
    return ($h / 2 -ge $script:minRows) -and ($w -ge $script:minCols)
}

# The rectangles after splitting the one at index $idx; its two halves take its place. Assign the result directly.
function Get-SplitRects($rects, $idx, $dir) {
    $halves = Split-Rect $rects[$idx] $dir
    $new = @()
    for ($i = 0; $i -lt $rects.Count; $i++) {
        if ($i -eq $idx) { $new += , $halves.a; $new += , $halves.b } else { $new += , $rects[$i] }
    }
    return , $new
}

# Which pane to split next and how, or $null when the window has no room. Returns
# @{ at = place (1-based); dir = '-V'|'-H'; rects = the rectangles after the split }.
function Get-NextSplit($rects) {
    if ($rects.Count -ge $script:maxPanes) { return $null }
    $cells = Get-WindowCells
    # Fixed shapes for 2-4 panes whatever the window size: 2 = side by side, 3 = one tall + two stacked,
    # 4 = 2x2. Each step is (place to split, direction); a step that would break the minimum size ends it.
    # The pane to split is chosen from the real rectangles, not a fixed place number: after panes were closed
    # the places no longer sit where a fresh launch puts them.
    if ($rects.Count -le 3) {
        $at = 1; $dir = '-V'
        if ($rects.Count -eq 2) {
            if ([math]::Abs($rects[0][0] - $rects[1][0]) -gt 0.001) {
                # Side by side: stack the right-hand pane.
                $at = if ($rects[1][0] -gt $rects[0][0]) { 2 } else { 1 }; $dir = '-H'
            } else { $at = 2 }   # Stacked: the lower one goes side by side
        } elseif ($rects.Count -eq 3) {
            # Split the biggest pane (the tall one) into two stacked panes -> 2x2; on a tie the later place.
            $at = 1
            for ($i = 1; $i -lt 3; $i++) { if ($rects[$i][2] * $rects[$i][3] -ge $rects[$at - 1][2] * $rects[$at - 1][3] - 1e-9) { $at = $i + 1 } }
            $dir = if ($rects[$at - 1][3] -ge 0.99) { '-H' } else { '-V' }
        }
        $r = $rects[$at - 1]
        if (-not (Test-SplitFits ($r[2] * $cells[0]) ($r[3] * $cells[1]) $dir)) { return $null }
        $new = Get-SplitRects $rects ($at - 1) $dir
        return @{ at = $at; dir = $dir; rects = $new }
    }
    $cand = for ($i = 0; $i -lt $rects.Count; $i++) {
        $r = $rects[$i]
        [pscustomobject]@{ idx = $i; w = $r[2] * $cells[0]; h = $r[3] * $cells[1]; area = $r[2] * $r[3] }
    }
    # Biggest first; on a tie the later place, so the third pane splits the second.
    foreach ($c in ($cand | Sort-Object @{ e = 'area'; Descending = $true }, @{ e = 'idx'; Descending = $true })) {
        # Prefer side by side (tall panes keep the most reply visible): a pane at least as many columns as rows
        # splits that way, even though a cell is about twice as tall as wide.
        $order = if ($c.w -ge $c.h) { @('-V', '-H') } else { @('-H', '-V') }
        foreach ($dir in $order) {
            if (-not (Test-SplitFits $c.w $c.h $dir)) { continue }
            $new = Get-SplitRects $rects $c.idx $dir
            return @{ at = $c.idx + 1; dir = $dir; rects = $new }
        }
    }
    return $null
}

# wt arguments that start the slot script in a pane (used by tai.ps1 and New-Pane).
function New-SlotArgs($n) {
    "$script:wtProfile --title `"pane $n`" -d `"$script:libRoot`" $script:psCmd `"$script:libRoot\slot.ps1`" -Slot $n"
}

function Get-PaneCount {
    $f = Join-Path $script:stateRoot 'panes.count'
    try { $n = [int](Get-Content $f -Raw -ErrorAction Stop) } catch { return 1 }
    if ($n -lt 1) { return 1 }
    if ($n -gt $script:maxPanes) { return $script:maxPanes }
    return $n
}

# Which slot sits at each place in the focus order (index 0 = place 1). Starts as the
# default order and changes when panes are swapped; saved in state\layout.json.
function Get-Layout($count) {
    $default = if ($script:paneOrder.ContainsKey([int]$count)) { @($script:paneOrder[[int]$count] | Select-Object -Skip 1) } else { @(1..$count) }
    try { $parsed = Get-Content (Join-Path $script:stateRoot 'layout.json') -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { return $default }
    # PS 5.1 hands a JSON array back as one object; unwrap it by enumerating explicitly.
    $saved = @()
    foreach ($s in $parsed) { $saved += $s }
    # Slot numbers may have gaps (a middle pane was closed), so only check they are distinct and in range.
    $ok = ($saved.Count -eq $count) -and (@($saved | Select-Object -Unique).Count -eq $count) -and
          (@($saved | Where-Object { $_ -lt 1 -or $_ -gt $script:maxPanes }).Count -eq 0)
    if ($ok) { return @($saved | ForEach-Object { [int]$_ }) }
    return $default
}

function Save-Layout($slots) {
    New-Item -ItemType Directory -Force $script:stateRoot | Out-Null
    ConvertTo-Json -InputObject @($slots) -Compress | Set-Content (Join-Path $script:stateRoot 'layout.json')
}

# Steps that land on the pane at this place in the focus order.
function Get-PlaceSteps($place) {
    @('move-focus first') + @(1..$place | ForEach-Object { 'move-focus nextInOrder' })
}

function Get-FocusSteps($slot, $count) {
    $pos = [array]::IndexOf((Get-Layout $count), [int]$slot) + 1
    if ($pos -lt 1) { $pos = 1 }
    Get-PlaceSteps $pos
}

# Run wt subcommands (joined with ' ; ') against the tai window.
function Invoke-Wt($steps, [switch]$Wait) {
    Start-Process wt.exe -ArgumentList ('-w tai ' + (@($steps) -join ' ; ')) -WindowStyle Hidden -Wait:$Wait
}

function Focus-Slot($n) {
    Invoke-Wt (Get-FocusSteps $n (Get-PaneCount))
}

# Split a new pane N off the layout; wt focuses the new pane.
function New-Pane($n, $batch = $null) {
    $how = Get-NextSplit (Get-Rects (Get-PaneCount))
    if (-not $how) { return $false }
    $steps = @(Get-PlaceSteps $how.at) + "split-pane $($how.dir) -s 0.5 $(New-SlotArgs $n)"
    New-Item -ItemType Directory -Force $script:stateRoot | Out-Null
    Save-Rects $how.rects
    # The new pane lands right after the one it was split from.
    $count = Get-PaneCount
    $old = @(Get-Layout $count)
    Save-Layout (@($old | Select-Object -First $how.at) + [int]$n + @($old | Select-Object -Skip $how.at))
    Set-Content (Join-Path $script:stateRoot 'panes.count') ($count + 1)   # $n is the slot number, which can exceed the count
    # Stub heartbeat (pid 0): slot.ps1 overwrites it once the pane is up; if the pane is closed first, Get-DeadPanes still notices.
    [pscustomobject]@{ slot = [int]$n; pid = 0; since = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $script:stateRoot "slot$n.pane") -Encoding utf8
    # With a $batch list the steps are only collected; the caller runs them all in one wt call (see Start-PaneBatch).
    if ($null -ne $batch) { $batch.AddRange([string[]]$steps) }
    else { Invoke-Wt $steps }
    return $true
}

# The only slot pane was closed by hand, so the dashboard fills the window again: the next project splits a pane
# off the dashboard exactly like a fresh start (flag file 'nopanes', set by the dashboard's dead-pane handler).
function Test-NoPanes { Test-Path (Join-Path $script:stateRoot 'nopanes') }

function New-FirstPane($n, $batch = $null) {
    $stateRoot = $script:stateRoot
    Save-Layout @([int]$n)
    Set-Content (Join-Path $stateRoot 'panes.count') 1
    Save-Rects @(, $script:firstRect)
    Remove-Item (Join-Path $stateRoot 'nopanes') -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ slot = [int]$n; pid = 0; since = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $stateRoot "slot$n.pane") -Encoding utf8
    $steps = @('move-focus first', "split-pane -V -s 0.8 $(New-SlotArgs $n)")
    if ($null -ne $batch) { $batch.AddRange([string[]]$steps) } else { Invoke-Wt $steps }
}

# Run the collected New-Pane steps as one wt command line (one process start instead of one per pane).
function Start-PaneBatch($batch) {
    if ($batch.Count) { Invoke-Wt $batch }
}

# ---- Closing a pane -------------------------------------------------------------
# The rectangles (focus order) come from halving splits, so they determine wt's split tree: at
# every node the first group of rectangles fills exactly one half of the node's region.
function Get-Bounds($rects, $lo, $hi) {
    $x0 = 9.0; $y0 = 9.0; $x1 = 0.0; $y1 = 0.0
    for ($i = $lo; $i -le $hi; $i++) {
        $r = $rects[$i]
        if ($r[0] -lt $x0) { $x0 = $r[0] }
        if ($r[1] -lt $y0) { $y0 = $r[1] }
        if ($r[0] + $r[2] -gt $x1) { $x1 = $r[0] + $r[2] }
        if ($r[1] + $r[3] -gt $y1) { $y1 = $r[1] + $r[3] }
    }
    return @($x0, $y0, ($x1 - $x0), ($y1 - $y0))
}

function Get-AreaSum($rects, $lo, $hi) {
    $sum = 0.0
    for ($i = $lo; $i -le $hi; $i++) { $sum += $rects[$i][2] * $rects[$i][3] }
    return $sum
}

# Split tree of rects[lo..hi]: @{ leaf = index } or @{ dir; a; b }. $null if they do not tile by halving.
function Get-SplitTree($rects, $lo, $hi) {
    if ($lo -eq $hi) { return @{ leaf = $lo } }
    $eps = 1e-6
    $b = Get-Bounds $rects $lo $hi
    for ($k = $lo; $k -lt $hi; $k++) {
        $a = Get-Bounds $rects $lo $k
        if ([math]::Abs($a[0] - $b[0]) -gt $eps -or [math]::Abs($a[1] - $b[1]) -gt $eps) { continue }
        $dir = $null
        if ([math]::Abs($a[2] - $b[2] / 2) -lt $eps -and [math]::Abs($a[3] - $b[3]) -lt $eps) { $dir = '-V' }
        elseif ([math]::Abs($a[3] - $b[3] / 2) -lt $eps -and [math]::Abs($a[2] - $b[2]) -lt $eps) { $dir = '-H' }
        if (-not $dir) { continue }
        $halfArea = $b[2] * $b[3] / 2
        if ([math]::Abs((Get-AreaSum $rects $lo $k) - $halfArea) -gt $eps -or [math]::Abs((Get-AreaSum $rects ($k + 1) $hi) - $halfArea) -gt $eps) { continue }
        $left = Get-SplitTree $rects $lo $k
        $right = Get-SplitTree $rects ($k + 1) $hi
        if (-not $left -or -not $right) { return $null }
        return @{ dir = $dir; a = $left; b = $right }
    }
    return $null
}

# The tree without leaf $idx: its sibling takes the parent's place. $null when nothing is left.
function Remove-TreeLeaf($t, $idx) {
    if ($t.ContainsKey('leaf')) { if ($t.leaf -eq $idx) { return $null } else { return $t } }
    $a = Remove-TreeLeaf $t.a $idx
    $b = Remove-TreeLeaf $t.b $idx
    if ($null -eq $a) { return $b }
    if ($null -eq $b) { return $a }
    return @{ dir = $t.dir; a = $a; b = $b }
}

# Rectangles of the tree's leaves in focus order, each node halving its region.
function Add-TreeRects($t, $r, $out) {
    if ($t.ContainsKey('leaf')) { [void]$out.Add($r); return }
    $halves = Split-Rect $r $t.dir
    Add-TreeRects $t.a $halves.a $out
    Add-TreeRects $t.b $halves.b $out
}

# Rectangles after the pane at $place (1-based) closes and its sibling grows into the gap, or $null
# when the rectangles are not a halving tree. Assign the result directly (it is an array of arrays).
function Remove-RectPlace($rects, $place) {
    if ($rects.Count -lt 2 -or $place -lt 1 -or $place -gt $rects.Count) { return $null }
    $tree = Get-SplitTree $rects 0 ($rects.Count - 1)
    if (-not $tree) { return $null }
    $tree = Remove-TreeLeaf $tree ($place - 1)
    $out = New-Object System.Collections.ArrayList
    Add-TreeRects $tree (Get-Bounds $rects 0 ($rects.Count - 1)) $out
    $new = @()
    foreach ($r in $out) { $new += , $r }
    return , $new
}

# Forget the pane holding $slot after its window closed: layout, rectangles, count and its state files.
# Never removes the last pane. Returns $true when the layout changed.
function Remove-Pane($slot) {
    $count = Get-PaneCount
    if ($count -lt 2) { return $false }
    $layout = @(Get-Layout $count)
    $place = [array]::IndexOf($layout, [int]$slot) + 1
    if ($place -lt 1) { return $false }
    $rects = Get-Rects $count
    $new = $null
    if ($rects.Count -eq $count) { $new = Remove-RectPlace $rects $place }
    Save-Layout @($layout | Where-Object { $_ -ne [int]$slot })
    Set-Content (Join-Path $script:stateRoot 'panes.count') ($count - 1)
    # Without a usable record Get-Rects rebuilds the rectangles by replaying the splits.
    if ($new) { Save-Rects $new } else { Remove-Item (Join-Path $script:stateRoot 'rects.json') -Force -ErrorAction SilentlyContinue }
    foreach ($ext in 'pane', 'assign', 'json', 'close', 'exit') {
        Remove-Item (Join-Path $script:stateRoot "slot$slot.$ext") -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# Two panes stacked on top of each other waste the width of the window: put them side by side instead.
# wt cannot rotate a split, but move-pane to a new tab and back re-splits the pane along the long side
# (in a test window the moved pane landed on the left; focus order follows the left-to-right order, so the saved
# rectangles stay valid and Sync-Layout reads back which slot is where). Returns $true when it changed anything.
function Optimize-Layout {
    if ((Get-PaneCount) -ne 2) { return $false }
    $rects = Get-Rects 2
    if ($rects.Count -ne 2 -or [math]::Abs($rects[0][0] - $rects[1][0]) -gt 0.001) { return $false }   # already side by side
    $b = Get-Bounds $rects 0 1
    $cells = Get-WindowCells
    if ($b[2] * $cells[0] / 2 -lt $script:minCols) { return $false }
    $steps = @(Get-PlaceSteps 2) + 'move-pane -t 1'
    Invoke-Wt $steps -Wait
    Start-Sleep -Milliseconds 500
    Invoke-Wt 'move-pane -t 0' -Wait
    Start-Sleep -Milliseconds 300
    $left = @($b[0], $b[1], ($b[2] / 2), $b[3])
    $right = @(($b[0] + $b[2] / 2), $b[1], ($b[2] / 2), $b[3])
    Save-Rects @($left, $right)
    return $true
}

# Slots whose pane window is gone: slot.ps1 records its pid in slotN.pane when it starts.
function Get-DeadPanes {
    $dead = @()
    foreach ($f in Get-ChildItem $script:stateRoot -Filter 'slot*.pane' -ErrorAction SilentlyContinue) {
        try { $p = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        if (-not $p.pid) {
            # Stub written by New-Pane before wt starts the pane: dead only if the pane never came up (closed during startup).
            try { if (((Get-Date) - [datetime]$p.since).TotalSeconds -gt 20) { $dead += [int]$p.slot } } catch { $dead += [int]$p.slot }
            continue
        }
        if (-not (Test-SlotAlive $p.pid $p.since)) { $dead += [int]$p.slot }
    }
    return $dead
}

# Project name -> slot for the running panes (a pane's title is its project name). $null for a name used twice.
function Get-SlotNames {
    $names = @{}
    foreach ($f in Get-ChildItem $script:stateRoot -Filter 'slot*.json' -ErrorAction SilentlyContinue) {
        try { $s = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        if (-not $s.name) { continue }
        if ($names.ContainsKey([string]$s.name)) { $names[[string]$s.name] = $null } else { $names[[string]$s.name] = [int]$s.slot }
    }
    return $names
}

# Title of the focused pane (the window title follows it), or $null.
function Get-FocusedTitle {
    $names = Get-SlotNames
    $w = Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match '^(dashboard|pane \d)' -or $names.ContainsKey($_.MainWindowTitle) } | Select-Object -First 1
    if ($w) { return $w.MainWindowTitle }
    return $null
}

# Measure which slot really sits at each place by focusing each place and reading the title.
# Also repairs the layout after panes were moved by hand. Returns $false if a probe failed.
function Sync-Layout($only = $null) {
    $count = Get-PaneCount
    # With $only (places), just those are probed; the others keep their saved slot.
    $found = @(Get-Layout $count)
    $probe = if ($only) { @($only) } else { @(1..$count) }
    foreach ($place in $probe) {
        Invoke-Wt (Get-PlaceSteps $place) -Wait
        Start-Sleep -Milliseconds 500
        $t = Get-FocusedTitle
        $byName = Get-SlotNames
        if ($t -match '^pane (\d)$') { $found[$place - 1] = [int]$Matches[1] }
        elseif ($t -and $null -ne $byName[$t]) { $found[$place - 1] = [int]$byName[$t] }
        else { return $false }
    }
    $ok = (@($found | Select-Object -Unique).Count -eq $count) -and (@($found | Where-Object { $_ -lt 1 -or $_ -gt $script:maxPanes }).Count -eq 0)
    if (-not $ok) { return $false }
    Save-Layout $found
    return $true
}

# Put focus back on the dashboard (Sync-Layout leaves it on the last probed pane). `move-focus first`
# alone is unreliable with 2+ panes, so step with nextInOrder until the window title says dashboard.
function Focus-Dashboard {
    $count = Get-PaneCount
    for ($i = 0; $i -le $count + 1; $i++) {
        $t = Get-FocusedTitle
        if ($t -match '^dashboard') { return $true }
        Invoke-Wt 'move-focus nextInOrder' -Wait
        Start-Sleep -Milliseconds 150
    }
    return $false
}

# Swap the pane holding $slot with its neighbour in $dir (Left/Right/Up/Down); the running
# Claude sessions move with their panes. Returns a message.
function Move-Pane($slot, $dir) {
    $count = Get-PaneCount
    $layout = @(Get-Layout $count)
    $place = [array]::IndexOf($layout, [int]$slot) + 1
    if ($place -lt 1) { return "Pane $slot is not in the layout" }
    # Neighbour = the pane touching this one's edge in that direction with the most overlap.
    $rects = Get-Rects $count
    if ($rects.Count -ne $count) { return 'Window layout is out of step with the panes (press R)' }
    $me = $rects[$place - 1]
    $eps = 0.001
    $best = 0; $bestOverlap = 0
    for ($j = 1; $j -le $rects.Count; $j++) {
        if ($j -eq $place) { continue }
        $o = $rects[$j - 1]
        $touch = switch ($dir) {
            'Left'  { [math]::Abs(($o[0] + $o[2]) - $me[0]) -lt $eps }
            'Right' { [math]::Abs($o[0] - ($me[0] + $me[2])) -lt $eps }
            'Up'    { [math]::Abs(($o[1] + $o[3]) - $me[1]) -lt $eps }
            'Down'  { [math]::Abs($o[1] - ($me[1] + $me[3])) -lt $eps }
        }
        if (-not $touch) { continue }
        $overlap = if ($dir -eq 'Left' -or $dir -eq 'Right') {
            [math]::Min($o[1] + $o[3], $me[1] + $me[3]) - [math]::Max($o[1], $me[1])
        } else {
            [math]::Min($o[0] + $o[2], $me[0] + $me[2]) - [math]::Max($o[0], $me[0])
        }
        if ($overlap -gt $eps -and $overlap -gt $bestOverlap + $eps) { $best = $j; $bestOverlap = $overlap }
    }
    if (-not $best) { return "No pane to the $($dir.ToLower())" }
    $steps = @(Get-PlaceSteps $place) + "swap-pane $($dir.ToLower())"
    # swap-pane exchanges exactly those two places, so record that instead of probing (press R if it ever drifts).
    $swapped = @($layout)
    $swapped[$place - 1] = $layout[$best - 1]
    $swapped[$best - 1] = $layout[$place - 1]
    Save-Layout $swapped
    # Swap, then focus the moved pane (now at the neighbour's place) in a single wt call.
    $steps = $steps + @(Get-PlaceSteps $best)
    Invoke-Wt $steps
    return "Moved pane $slot $($dir.ToLower())"
}

# A project's path is a plain string, or {"windows": "...", "linux": "..."} so one projects.json serves both OSes.
# A plain string is only visible on the OS it belongs to; entries for the other OS are hidden, never deleted.
function Test-WinPath($p) { ($p -is [string]) -and ($p -match '^([A-Za-z]:|\\\\)') }

function Read-ProjectsRaw {
    if (-not (Test-Path -LiteralPath $script:configPath)) { return @() }
    # UTF-8 explicitly (Get-Content defaults to ANSI on PS 5.1 and would corrupt non-ASCII names). A read that
    # collides with a save, or a half-written file, falls back to the last text that parsed.
    $parsed = $null
    foreach ($try in 1..3) {
        try {
            $raw = [IO.File]::ReadAllText($script:configPath, [Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
            $parsed = ConvertFrom-Json $raw
            $script:lastGoodProjectsRaw = $raw
            break
        } catch { Start-Sleep -Milliseconds 40 }
    }
    if ($null -eq $parsed) {
        if (-not $script:lastGoodProjectsRaw) { return @() }
        $parsed = ConvertFrom-Json $script:lastGoodProjectsRaw
    }
    # PS 5.1 emits a JSON array as one object; unwrap it by enumerating explicitly.
    $list = @()
    foreach ($p in $parsed) { $list += $p }
    return $list
}

# Returns the projects that have a Windows path, with .path as a plain string.
function Get-Projects {
    $list = @()
    foreach ($p in (Read-ProjectsRaw)) {
        if ($p.path -is [string]) {
            if (-not (Test-WinPath $p.path)) { continue }
        } else {
            $w = $p.path.windows
            if (-not (Test-WinPath $w)) { continue }
            $p | Add-Member -NotePropertyName _pathObj -NotePropertyValue $p.path -Force
            $p.path = $w
        }
        $list += $p
    }
    return $list
}

# Per-CLI facts (executable, args, resume/fresh args, env) shared with linux/ in agents.json at the repo root.
function Get-Registry {
    if (-not $script:registry) {
        try { $script:registry = Get-Content $script:registryPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $script:registry = [pscustomobject]@{} }
    }
    return $script:registry
}
$script:agents = @((Get-Registry).PSObject.Properties.Name)
if (-not $script:agents.Count) { $script:agents = @('claude', 'codex', 'agy', 'opencode', 'cursor', 'copilot', 'qwen') }

# Executable behind an agent name (Cursor's CLI is called "agent").
function Get-AgentExe($name) {
    $e = (Get-Registry).$name.exe
    if ($e) { return [string]$e }
    return $name
}

# Arguments for launching an agent: the registry's always-on args plus the 'resume' or 'fresh' extras.
function Get-AgentArgs($name, $mode, $projName) {
    $r = (Get-Registry).$name
    $out = @()
    if ($r) {
        foreach ($a in @($r.args) + @($r.$mode)) { if ($a) { $out += ([string]$a).Replace('{name}', $projName) } }
    }
    return $out
}

# Extra flag that makes Claude read the dashboard's settings file (empty for the other CLIs).
function Get-AgentSettingsFlag($name) { [string](Get-Registry).$name.settingsFlag }

function Set-AgentEnv($name) {
    $r = (Get-Registry).$name
    if ($r -and $r.env) { foreach ($p in $r.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process') } }
}

function Clear-AgentEnv {
    foreach ($n in $script:agents) {
        $r = (Get-Registry).$n
        if ($r -and $r.env) { foreach ($p in $r.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, $null, 'Process') } }
        if ($r -and $r.configEnv) { [Environment]::SetEnvironmentVariable([string]$r.configEnv, $null, 'Process') }
    }
}

# ---- Accounts -------------------------------------------------------------------------------------------------
# accounts.json (repo root, git-ignored; see accounts.example.json) lists named accounts per CLI as config folders:
#   { "claude": { "personal": "~/.claude", "work": "~/.claude-work" } }
# The first one is the default. A CLI keeps its login inside its config folder, and agents.json's "configEnv" names the
# variable that moves it (CLAUDE_CONFIG_DIR, CODEX_HOME), so a pane on another account just gets another folder.
$script:accountsPath = Join-Path (Split-Path $PSScriptRoot) 'accounts.json'

# Account names of an agent, in file order (empty when the agent has no accounts or no configEnv).
function Get-AgentAccounts($agent) {
    if (-not (Get-Registry).$agent.configEnv) { return @() }
    try {
        $a = (Get-Content $script:accountsPath -Raw -ErrorAction Stop | ConvertFrom-Json).$agent
        if ($a) { return @($a.PSObject.Properties.Name) }
    } catch { }
    return @()
}

# The project's account for an agent: its saved choice when that account still exists, else the first account.
function Get-ProjectAccount($project, $agent) {
    $names = @(Get-AgentAccounts $agent)
    if (-not $names.Count) { return '' }
    $saved = $project.accounts.$agent
    if ($saved -and $names -contains $saved) { return [string]$saved }
    return $names[0]
}

function Get-AccountDir($agent, $account) {
    try {
        $d = [string](Get-Content $script:accountsPath -Raw -ErrorAction Stop | ConvertFrom-Json).$agent.$account
        if ($d) { return [Environment]::ExpandEnvironmentVariables($d.Replace('~', $HOME)) }
    } catch { }
    return $null
}

function Test-DefaultAccountDir($agent, $dir) {
    $d = [string](Get-Registry).$agent.defaultDir
    if (-not $d) { return $false }
    $d = $d.Replace('~', $HOME)
    return (Get-NormPath $d) -eq (Get-NormPath $dir)
}

# Who an account is logged in as: 'email (plan)', 'not logged in', or 'checking...' while a lookup runs.
# Claude is asked through `claude auth status` in a background job (cached 10 min); Codex is read from auth.json
# (only the email and plan claims of the id token are used, never the tokens themselves).
$script:identityCache = @{}
function Get-AccountIdentity($agent, $account) {
    $dir = Get-AccountDir $agent $account
    if (-not $dir) { return '' }
    if ($agent -eq 'codex') {
        try {
            $auth = Join-Path $dir 'auth.json'
            if (-not (Test-Path -LiteralPath $auth)) { return 'not logged in' }
            $p = ((Get-Content -LiteralPath $auth -Raw | ConvertFrom-Json).tokens.id_token.Split('.')[1]).Replace('-', '+').Replace('_', '/')
            while ($p.Length % 4) { $p += '=' }
            $c = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
            $plan = $c.'https://api.openai.com/auth'.chatgpt_plan_type
            if (-not $c.email) { return 'not logged in' }
            return $(if ($plan) { "$($c.email) ($plan)" } else { [string]$c.email })
        } catch { return 'not logged in' }
    }
    if ($agent -ne 'claude') { return '' }
    $key = "$agent|$dir"
    $c = $script:identityCache[$key]
    if (-not $c) { $c = @{ time = [datetime]::MinValue; text = $null; job = $null }; $script:identityCache[$key] = $c }
    if ($c.job -and $c.job.State -ne 'Running') {
        $out = (@(Receive-Job $c.job -ErrorAction SilentlyContinue) -join "`n")
        Remove-Job $c.job -Force
        $c.job = $null
        $c.time = Get-Date
        try {
            $s = $out | ConvertFrom-Json
            $c.text = if ($s.loggedIn -and $s.email) { if ($s.subscriptionType) { "$($s.email) ($($s.subscriptionType))" } else { [string]$s.email } } else { 'not logged in' }
        } catch { $c.text = 'login unknown (claude auth status failed)' }
    } elseif ($c.job -and ((Get-Date) - $c.time).TotalSeconds -gt 30) {
        Stop-Job $c.job -ErrorAction SilentlyContinue; Remove-Job $c.job -Force -ErrorAction SilentlyContinue; $c.job = $null
    }
    if (-not $c.job -and ((Get-Date) - $c.time).TotalSeconds -ge 600) {
        $c.time = Get-Date
        $useDir = if (Test-DefaultAccountDir $agent $dir) { '' } else { $dir }
        $c.job = Start-Job -ArgumentList $useDir -ScriptBlock {
            param($d)
            if ($d) { $env:CLAUDE_CONFIG_DIR = $d }
            claude auth status 2>$null
        }
    }
    if ($c.text) { return $c.text }
    return 'checking...'
}

# Points the agent's config variable at the account's folder (created on first use). Codex also gets the dashboard's
# hooks copied in once; Claude needs nothing because slot.ps1 passes its hooks with --settings.
function Set-AgentAccountEnv($agent, $account) {
    if (-not $account) { return }
    $var = [string](Get-Registry).$agent.configEnv
    $dir = Get-AccountDir $agent $account
    if (-not $var -or -not $dir) { return }
    # The CLI's own default folder: leave the variable unset (Claude keeps its config next to ~/.claude, not inside it).
    if (Test-DefaultAccountDir $agent $dir) { return }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if ($agent -eq 'codex') {
            foreach ($f in 'hooks.json', 'config.toml') {
                $src = Join-Path (Join-Path $HOME '.codex') $f
                if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dir }
            }
        }
    }
    [Environment]::SetEnvironmentVariable($var, $dir, 'Process')
}

# Saves the project's account for one agent (projects.json: "accounts": { "claude": "work" }).
function Set-ProjectAccount($path, $agent, $account) {
    $projects = @(Get-Projects)
    $p = $projects | Where-Object { (Get-NormPath $_.path) -eq (Get-NormPath $path) } | Select-Object -First 1
    if (-not $p) { return }
    $map = [ordered]@{}
    if ($p.accounts) { foreach ($x in $p.accounts.PSObject.Properties) { $map[$x.Name] = $x.Value } }
    $map[$agent] = $account
    $p | Add-Member -NotePropertyName accounts -NotePropertyValue ([pscustomobject]$map) -Force
    Save-Projects $projects
}

# ---- Keeping tai responsive -----------------------------------------------------------------------------------
$script:limitsPath = Join-Path (Split-Path $PSScriptRoot) 'limits.json'

# Keeps tai's own UI responsive when the PC is busy: the dashboard and its Windows Terminal window (plus that
# window's per-pane OpenConsole hosts) get a higher scheduling priority, and the dashboard's memory is kept
# resident so Windows does not page it out under RAM pressure. Agents keep Normal priority (they are not
# touched). Optional "tai" entry in limits.json: { "tai": { "priority": "High", "terminal": "AboveNormal", "minRamMb": 100 } }
# (priority / terminal: Idle, BelowNormal, Normal, AboveNormal, High; "off": true disables all of it).
# Windows cannot reserve CPU or RAM for a process, so this only makes tai win when processes compete.
function Protect-Tai {
    try {
        $c = $null
        try { $c = (Get-Content $script:limitsPath -Raw -ErrorAction Stop | ConvertFrom-Json).tai } catch { }
        if ($c -and $c.off) { return }
        $dash = if ($c -and $c.priority) { [string]$c.priority } else { 'High' }
        $term = if ($c -and $c.terminal) { [string]$c.terminal } else { 'AboveNormal' }
        $minMb = if ($c -and $null -ne $c.minRamMb) { [int]$c.minRamMb } else { 100 }
        $me = [Diagnostics.Process]::GetCurrentProcess()
        try { $me.PriorityClass = $dash } catch { }
        if ($minMb -gt 0) {
            try {
                $me.MaxWorkingSet = [IntPtr](2GB)   # raised first: the minimum may not exceed the maximum
                $me.MinWorkingSet = [IntPtr]($minMb * 1MB)
            } catch { }
        }
        # Windows Terminal hosting this dashboard: found by walking up the parent chain.
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop)
        $wt = $null; $id = $PID; $hops = 0
        while ($id -and $hops -lt 8) {
            $p = $all | Where-Object { $_.ProcessId -eq $id } | Select-Object -First 1
            if (-not $p) { break }
            if ($p.Name -eq 'WindowsTerminal.exe') { $wt = $p.ProcessId; break }
            $id = $p.ParentProcessId; $hops++
        }
        if ($wt) {
            $ids = @($wt) + @($all | Where-Object { $_.ParentProcessId -eq $wt -and $_.Name -eq 'OpenConsole.exe' } | ForEach-Object { $_.ProcessId })
            foreach ($i in $ids) { try { (Get-Process -Id $i -ErrorAction Stop).PriorityClass = $term } catch { } }
        }
    } catch { }
}

# The known CLIs that are installed right now (all of them when none is found, so the menus never end up empty).
# Called once when the dashboard starts; the chooser and the G key use $script:installedAgents.
function Update-InstalledAgents {
    $found = @($script:agents | Where-Object { Get-Command (Get-AgentExe $_) -ErrorAction SilentlyContinue })
    $script:installedAgents = if ($found.Count) { $found } else { $script:agents }
    # Panes read this instead of searching PATH again (Test-AgentInstalled).
    try { ConvertTo-Json -InputObject @($found) -Compress | Set-Content (Join-Path $script:stateRoot 'installed.json') } catch { }
}

# Fast check used by slot.ps1: the dashboard's scan result when it is there, else a PATH search.
function Test-AgentInstalled($name) {
    try {
        $saved = Get-Content (Join-Path $script:stateRoot 'installed.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($a in $saved) { foreach ($x in $a) { if ($x -eq $name) { return $true } } }
        if (@($saved).Count) { return $false }
    } catch { }
    return [bool](Get-Command (Get-AgentExe $name) -ErrorAction SilentlyContinue)
}
$script:installedAgents = $script:agents

# Which CLI a project runs; projects saved before agents existed use Claude.
function Get-Agent($project) {
    if ($project.agent -and $script:agents -contains $project.agent) { return [string]$project.agent }
    return 'claude'
}

function Save-Projects($projects) {
    $out = @()
    foreach ($p in @($projects)) {
        $o = [ordered]@{}
        foreach ($prop in $p.PSObject.Properties) { if ($prop.Name -ne '_pathObj') { $o[$prop.Name] = $prop.Value } }
        if ($p.PSObject.Properties['_pathObj']) {
            $po = $p._pathObj
            $po | Add-Member -NotePropertyName windows -NotePropertyValue $p.path -Force
            $o['path'] = $po
        }
        $out += [pscustomobject]$o
    }
    # Keep the entries that belong to the other OS (hidden by Get-Projects) exactly as they are, at their
    # place in the file: this OS's projects fill the remaining places in order, any extra ones go last.
    $merged = @()
    $vi = 0
    foreach ($p in (Read-ProjectsRaw)) {
        $visible = if ($p.path -is [string]) { Test-WinPath $p.path } else { Test-WinPath $p.path.windows }
        if (-not $visible) { $merged += $p }
        elseif ($vi -lt $out.Count) { $merged += $out[$vi]; $vi++ }
    }
    while ($vi -lt $out.Count) { $merged += $out[$vi]; $vi++ }
    $json = ConvertTo-Json -InputObject $merged -Depth 5
    # BOM-less so jq on Linux can read the same file.
    # Temp file + replace, so a reader never sees a half-written projects.json.
    $tmp = "$($script:configPath).tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $script:configPath -Force
}

# Saves a new CLI for the project at $path (re-reads the file, so it is safe from a pane while the dashboard runs).
function Set-ProjectAgent($path, $agent) {
    $projects = @(Get-Projects)
    $p = $projects | Where-Object { (Get-NormPath $_.path) -eq (Get-NormPath $path) } | Select-Object -First 1
    if (-not $p) { return }
    $p | Add-Member -NotePropertyName agent -NotePropertyValue $agent -Force
    Save-Projects $projects
}

function Add-Projects($projects, $paths, $customName) {
    foreach ($arg in $paths) {
        $path = (Resolve-Path $arg -ErrorAction Stop).Path
        # Split-Path -Leaf returns the root itself for a drive root such as D:\, so detect that first.
        $projName = if ($customName) { $customName }
                    elseif ($path -match '^[A-Za-z]:\\?$') { ($path.Substring(0, 1) + '_drive').ToLower() }
                    else { Split-Path $path -Leaf }
        if ($projects | Where-Object { $_.name -eq $projName }) { throw "A project named '$projName' already exists." }
        $dup = @($projects) | Where-Object { $_ -and (Get-NormPath $_.path) -eq (Get-NormPath $path) } | Select-Object -First 1
        if ($dup) { throw "That folder is already listed as '$($dup.name)'." }
        $projects = @($projects) + [pscustomobject]@{ name = $projName; path = $path }
        Write-Host "Added $projName -> $path"
    }
    return $projects
}

function Get-NormPath($path) { $path.Replace('/', '\').TrimEnd('\').ToLower() }

# File-name-safe key for a project directory: readable prefix plus a hash, so C:\a-b and C:\a_b differ.
function Get-StateKey($dir) {
    $norm = Get-NormPath $dir
    $md5 = [Security.Cryptography.MD5]::Create()
    $hash = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))) -replace '-', '').Substring(0, 8)
    ($norm -replace '[^a-z0-9]', '_') + '_' + $hash
}

# True when the process id belongs to a live PowerShell that started before $since.
function Test-SlotAlive($slotPid, $since) {
    if (-not $slotPid) { return $false }
    $p = Get-Process -Id $slotPid -ErrorAction SilentlyContinue
    if (-not $p -or $p.ProcessName -ne 'powershell') { return $false }
    if ($since -and $p.StartTime -gt [datetime]$since) { return $false }
    return $true
}

# A slot wrapper that was killed from outside leaves its CLI running, orphaned, in the pane. Its parent pid
# still points at the dead wrapper, so stop those processes (and their trees). If Windows has reused the
# pid, only children created before the new process started count, so an unrelated process is never touched.
# Returns how many orphans were stopped.
function Stop-OrphanedSlotChildren($slotPid, $since) {
    # $since (when the wrapper started) is required: Windows never rewrites a stale parent pid, so without it an
    # unrelated old process could look like a child of a pid that was recycled.
    if (-not $slotPid -or -not $since) { return 0 }
    try { $sinceDt = [datetime]$since } catch { return 0 }
    $reused = Get-Process -Id $slotPid -ErrorAction SilentlyContinue
    $reusedStart = $null
    if ($reused) { try { $reusedStart = $reused.StartTime } catch { return 0 } }   # protected process: leave it alone
    $count = 0
    foreach ($k in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$([int]$slotPid)" -ErrorAction SilentlyContinue)) {
        if ($k.CreationDate -lt $sinceDt.AddSeconds(-2)) { continue }
        if ($reusedStart -and $k.CreationDate -ge $reusedStart) { continue }
        & taskkill.exe /PID $k.ProcessId /T /F *> $null
        if ($LASTEXITCODE -eq 0) { $count++ }
    }
    return $count
}
