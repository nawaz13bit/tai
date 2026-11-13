# tai delegate: one agent hands a task to another CLI, which runs headless (one-shot) in the same project folder.
# The task goes in <project>\.tai\task-<target>.md, the answer comes back in <project>\.tai\reply-<target>.md (and on stdout).
# Usage (from an agent's shell, or by hand):
#   (target gemini is accepted as an alias of agy)
#   delegate.cmd <target> "<task>" [-Project <dir>] [-Summary "<what has been done>"] [-Files a.txt,b.txt] [-Edit] [-TimeoutSec 600]
#   delegate.cmd -History [-Project <dir>]       list past delegations of the project
# Read-only by default; -Edit lets the target change files (use a worktree if the caller is editing too).
# Exit code: 0 done, 1 failed or refused, 2 timed out, 3 target out of quota (remembered until its reset; send the step elsewhere).
param(
    [Parameter(Position = 0)][string]$Target,
    [Parameter(Position = 1)][string]$Task,
    [string]$Project,
    [string]$Summary,
    [string[]]$Files,
    [string[]]$Allow,   # commands the target may run without asking, in the target's own rule syntax (claude: "Bash(git status)", agy: "command(git status)")
    [switch]$AllowWide,   # accept an -Allow rule that allows (almost) everything
    [switch]$Edit,
    [switch]$IgnoreQuota,   # try a target even though an earlier run found it out of quota
    [switch]$Worktree,   # run in a new git worktree (own branch, own .tai), so several delegations - even to the same target - can run in parallel without touching each other's files
    [int]$TimeoutSec = 600,
    [switch]$History
)

. (Join-Path $PSScriptRoot 'lib.ps1')

# Limits (characters / counts).
$maxTask = 4000
$maxSummary = 3000
$maxReply = 20000
$maxChanged = 30
$keepRuns = 50
$keepDays = 30
$junk = '\\(node_modules|\.git|\.tai|bin|obj|dist|build|__pycache__|\.venv|venv|target)(\\|$)'

function Stop-Delegate($msg, $code = 1) {
    [Console]::Error.WriteLine("tai delegate: $msg")
    exit $code
}

# Written through a temp file and renamed, so a reader never sees half a file.
function Write-Atomic($path, $text) {
    $tmp = "$path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Limit-Text($text, $max) {
    if ($null -eq $text) { return '' }
    if ($text.Length -le $max) { return $text }
    return $text.Substring(0, $max) + "`n[cut at $max characters]"
}

function Quote-Arg($a) {
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

$dir = if ($Project) { $Project } elseif ($env:TAI_PROJECT_DIR) { $env:TAI_PROJECT_DIR } else { (Get-Location).Path }
if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Stop-Delegate "folder not found: $dir" }
$dir = (Resolve-Path -LiteralPath $dir).Path

# A rule that allows (almost) everything is as bad as skipping permissions, so it needs -AllowWide.
# Wide: a bare tool name (Bash), a lone wildcard, a regex that matches anything, or a shell/interpreter that can run anything.
function Test-WideRule($rule) {
    $r = ([string]$rule).Trim()
    if (-not $r) { return $false }
    $inner = if ($r -match '^[^(]+\((.*)\)$') { $Matches[1].Trim() } else { $null }
    if ($null -eq $inner) { return $true }                                    # no argument part: the whole tool
    if ($inner -match '^(regex:)?(\.\*|\*+|\^?\.\*\$?|:\*)?$') { return $true }  # empty, *, .*, regex:.*
    if ($inner -match '^(regex:)?\^?(sh|bash|zsh|cmd|powershell|pwsh|python3?|node|ruby|perl|env|sudo|npx)(\.exe)?(\s|:|\\|\.|\*|\$|$)') { return $true }  # a shell or interpreter, with any arguments
    return $false
}
$wide = @($Allow | Where-Object { $_ -and (Test-WideRule $_) })
if ($wide.Count -and -not $AllowWide) {
    Stop-Delegate ("-Allow rule too wide: " + ($wide -join ', ') + ". It would let the target run almost anything. Give the exact command (for example Bash(npm test)), or add -AllowWide if you really mean it.")
}

# ---- Quota memory: a target that ran out is skipped until its reset (machine-wide, so every project benefits) ------
$quotaDir = Join-Path $script:libRoot 'generated'
function Get-QuotaHold($t) {
    $f = Join-Path $quotaDir "quota-$t.json"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $until = [datetime](Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).until
        if ($until -gt (Get-Date)) { return $until }
    } catch { }
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    return $null
}
# Error text of the CLIs when the plan is used up (taken from user reports, not official docs; widen as new wordings show up).
$quotaRx = "hit your (session|usage) limit|usage limit reached|usage_limit_reached|quota reached|RESOURCE_EXHAUSTED|Resource has been exhausted|rate limit(ed| reached| exceeded)|(HTTP|code|status)[ :]+429"
# When the message says when it resets ("Try again at Apr 30th, 2026 11:21 AM", "Resets in 1h00m00s"), use that; otherwise 60 minutes.
function Get-QuotaReset($text) {
    $now = Get-Date
    if ($text -match 'Resets? in\s+(?:(\d+)d)?\s*(?:(\d+)h)?\s*(?:(\d+)m)?') {
        $mins = 1440 * [int]('0' + $Matches[1]) + 60 * [int]('0' + $Matches[2]) + [int]('0' + $Matches[3])
        if ($mins -gt 0) { return $now.AddMinutes($mins + 1) }
    }
    if ($text -match 'Try again at\s+([A-Za-z]{3,9}\s+\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})?,?\s*(\d{1,2}:\d{2}\s*[AP]M)?') {
        $s = ("$($Matches[1]) $($Matches[2]) $($Matches[3])").Trim()
        $d = [datetime]::MinValue
        if ([datetime]::TryParse($s, [ref]$d) -and $d -gt $now -and $d -lt $now.AddDays(10)) { return $d }
    }
    return $now.AddMinutes(60)
}
if ($Target -and $Task -and -not $History) {
    $q = $Target.ToLower(); if ($q -eq 'gemini') { $q = 'agy' }
    if (-not $IgnoreQuota) {
        $hold = Get-QuotaHold $q
        if ($hold) {
            [Console]::Error.WriteLine("tai delegate: quota - $q ran out earlier; skipped until $($hold.ToString('yyyy-MM-dd HH:mm')). Send this step to another target, or add -IgnoreQuota to try anyway.")
            Write-Output "Delegation quota. $q is out of quota until about $($hold.ToString('yyyy-MM-dd HH:mm')). Send this step to another target."
            exit 3
        }
    }
}

$origDir = $dir
$wtNote = ''
if ($Worktree -and -not $History -and $Target -and $Task) {
    $tg = $Target.ToLower(); if ($tg -eq 'gemini') { $tg = 'agy' }
    # Same checks as below, done first so a refused delegation leaves no worktree behind.
    if (-not (Get-Registry).$tg.headless -or -not (Test-AgentInstalled $tg) -or $env:TAI_DELEGATE_DEPTH) { Stop-Delegate "'$tg' cannot be delegated to here (not headless, not installed, or depth limit)" }
    $top = (& git -C $dir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) { Stop-Delegate '-Worktree needs a git project' }
    $stamp0 = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + (Get-Random -Maximum 1000)
    $branch = "tai-$tg-$stamp0"
    $wtDir = Join-Path (Split-Path $dir -Parent) ((Split-Path $dir -Leaf) + "-$branch")
    $out = & git -C $dir worktree add -b $branch $wtDir 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Delegate "could not create worktree: $out" }
    $dir = (Resolve-Path -LiteralPath $wtDir).Path
    $wtNote = "Worktree: $dir (branch $branch) - review it, then merge the branch or remove it with: git worktree remove `"$dir`""
}
$tai = Join-Path $dir '.tai'
$histDir = Join-Path $tai 'history'
$histLog = Join-Path $histDir 'delegations.jsonl'

# ---- History listing ------------------------------------------------------------------------------------------
if ($History) {
    if (-not (Test-Path -LiteralPath $histLog)) { Write-Output 'No delegations yet.'; exit 0 }
    $rows = @(Get-Content -LiteralPath $histLog -Encoding UTF8 | Where-Object { $_.Trim() })
    foreach ($line in ($rows | Select-Object -Last 20 | ForEach-Object { $_ })) {
        try { $r = $line | ConvertFrom-Json } catch { continue }
        $first = ([string]$r.task -split "`n")[0]
        if ($first.Length -gt 70) { $first = $first.Substring(0, 69) + '~' }
        Write-Output ('{0}  {1}->{2}  {3,-9} {4,4}s  {5}   [{6}]' -f ([datetime]$r.time).ToString('yyyy-MM-dd HH:mm'), $r.from, $r.target, $r.status, $r.seconds, $first, $r.reply)
    }
    exit 0
}

# ---- Checks ---------------------------------------------------------------------------------------------------
if (-not $Target -or -not $Task) { Stop-Delegate 'usage: delegate.cmd <target> "<task>" [-Project dir] [-Summary text] [-Files a,b] [-Edit] [-TimeoutSec n]  |  -History' }
$Target = $Target.ToLower()
if ($Target -eq 'gemini') { $Target = 'agy' }   # gemini and agy are the same CLI
$cfg = (Get-Registry).$Target.headless
if (-not $cfg) {
    $ok = @($script:agents | Where-Object { (Get-Registry).$_.headless }) -join ', '
    Stop-Delegate "'$Target' cannot run headless here. Targets: $ok"
}
if (-not (Test-AgentInstalled $Target)) { Stop-Delegate "'$Target' is not installed (not on PATH)" }
$depth = 0
[void][int]::TryParse([string]$env:TAI_DELEGATE_DEPTH, [ref]$depth)
if ($depth -ge 1) { Stop-Delegate 'a delegated agent cannot delegate again (depth limit 1)' }

New-Item -ItemType Directory -Force $histDir | Out-Null
# A git project: keep .tai out of status locally without touching the project's .gitignore.
$gitDir = Join-Path $origDir '.git'
if (Test-Path -LiteralPath $gitDir -PathType Container) {
    try {
        $exDir = Join-Path $gitDir 'info'
        New-Item -ItemType Directory -Force $exDir | Out-Null
        $ex = Join-Path $exDir 'exclude'
        $have = if (Test-Path -LiteralPath $ex) { @(Get-Content -LiteralPath $ex) } else { @() }
        if ($have -notcontains '.tai/') { Add-Content -LiteralPath $ex -Value '.tai/' -Encoding utf8 }
    } catch { }
}

# One delegation per target at a time: a second one would overwrite the first one's files.
$lock = Join-Path $tai "running-$Target.lock"
if (Test-Path -LiteralPath $lock) {
    $old = $null
    try { $old = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json } catch { }
    $alive = $old -and $old.pid -and (Get-Process -Id ([int]$old.pid) -ErrorAction SilentlyContinue) -and (((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalSeconds -lt ($TimeoutSec + 120))
    if ($alive) { Stop-Delegate "a delegation to $Target is already running in this project" }
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
}
Write-Atomic $lock ([pscustomobject]@{ pid = $PID; since = (Get-Date).ToString('o') } | ConvertTo-Json)

$from = if ($env:TAI_AGENT) { $env:TAI_AGENT } else { 'user' }
$mode = if ($Edit) { 'edit' } else { 'read-only' }
$taskFile = Join-Path $tai "task-$Target.md"
$replyFile = Join-Path $tai "reply-$Target.md"
$setFile = Join-Path $tai "run-$Target.settings.json"
$t0 = Get-Date
$status = 'failed'
$reason = ''
$body = ''
$changed = @()

try {
    # ---- Task file --------------------------------------------------------------------------------------------
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# Task for $Target")
    [void]$md.AppendLine("From: $from | Mode: $mode | $($t0.ToString('yyyy-MM-dd HH:mm'))")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## Task')
    [void]$md.AppendLine((Limit-Text $Task $maxTask))
    if ($Summary) {
        [void]$md.AppendLine('')
        [void]$md.AppendLine('## Context from the agent that asked')
        [void]$md.AppendLine((Limit-Text $Summary $maxSummary))
    }
    # -File mode passes "-Files a,b" as one string, so split on commas here.
    $fileList = @($Files | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First $maxChanged)
    if ($fileList.Count) {
        [void]$md.AppendLine('')
        [void]$md.AppendLine('## Files to look at')
        foreach ($f in $fileList) { [void]$md.AppendLine("- $f") }
    }
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## How to answer')
    [void]$md.AppendLine('Your final message goes straight back to the agent that asked, so make it a self-contained answer (findings, decisions, file names). Keep it short.')
    if ($Edit) { [void]$md.AppendLine('You may change files in this folder if the task needs it; list every file you changed.') }
    else { [void]$md.AppendLine('Read-only: do not create, change or delete files.') }
    Write-Atomic $taskFile $md.ToString()
    Remove-Item -LiteralPath $replyFile -Force -ErrorAction SilentlyContinue   # a leftover reply must never pass for the new one

    # ---- Launch -----------------------------------------------------------------------------------------------
    Clear-AgentEnv
    Set-AgentEnv $Target
    $proj = @(Get-Projects) | Where-Object { (Get-NormPath $_.path) -eq (Get-NormPath $origDir) } | Select-Object -First 1
    $account = if ($proj) { Get-ProjectAccount $proj $Target } else { '' }
    Set-AgentAccountEnv $Target $account
    $env:TAI_DELEGATE_DEPTH = [string]($depth + 1)
    $env:TAI_PROJECT_DIR = $dir
    $env:TAI_AGENT = $Target

    $prompt = "Read .tai/task-$Target.md in the current folder and carry out the task described there. Your final message is returned to the agent that asked."
    # Permissions the target cannot ask for in headless mode: pre-approved rules from -Allow (claude flag, agy per-run settings file).
    $extra = @()
    $rules = @(@($cfg.defaultAllow) + @($Allow) | Where-Object { $_ })   # defaultAllow: harmless read-only commands, so it works on machines without a broad allow rule
    # agy only understands an exact command or "regex:..."; a glob like command(git status*) or command(git status:*) never matches, so turn globs into regex.
    if ($cfg.settingsFlag) {
        $rules = @($rules | ForEach-Object {
            if ($_ -match '^(\w+)\((?!regex:)(.*)\)$' -and $Matches[2] -match '\*') {
                $tool = $Matches[1]; $pat = $Matches[2] -replace ':\*$', ' *'
                $re = (($pat -split '\*' | ForEach-Object { [regex]::Escape($_) }) -join '.*')
                "$tool(regex:$re)"
            } else { $_ }
        })
    }
    if ($cfg.allowFlag -and $rules.Count) { $extra += $cfg.allowFlag; $extra += ($rules -join ',') }
    if ($cfg.settingsFlag) {
        $deny = if ($Edit) { @() } else { @($cfg.readonlyDeny | Where-Object { $_ }) }
        if ($rules.Count -or $deny.Count) {
            $set = [ordered]@{ permissions = [ordered]@{ allow = @($rules); deny = @($deny) } }
            Write-Atomic $setFile ($set | ConvertTo-Json -Depth 5)
            $extra += $cfg.settingsFlag; $extra += $setFile
        }
    }
    $argv = @($cfg.args) + $(if ($Edit) { @($cfg.edit) } else { @($cfg.readonly) }) + $extra + @($cfg.prompt) + @($prompt)
    $argLine = (@($argv | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { Quote-Arg ([string]$_) })) -join ' '
    $exe = (Get-Command (Get-AgentExe $Target) -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

    $outFile = Join-Path $tai "run-$Target.out"
    $errFile = Join-Path $tai "run-$Target.err"
    $inFile = Join-Path $tai "run-$Target.in"
    [IO.File]::WriteAllText($inFile, '')   # empty stdin: a headless CLI must never wait for typing
    $proc = Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $dir -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile -RedirectStandardInput $inFile
    $null = $proc.Handle   # PS 5.1: without touching the handle, ExitCode comes back empty for redirected processes
    if ($proc.WaitForExit($TimeoutSec * 1000)) {
        $proc.WaitForExit()
        $raw = if (Test-Path -LiteralPath $outFile) { [IO.File]::ReadAllText($outFile) } else { '' }
        $body = $raw.Trim()
        $errText = if (Test-Path -LiteralPath $errFile) { [IO.File]::ReadAllText($errFile) } else { '' }
        # Out of quota: the CLI failed, or answered with only a short limit message (a long real answer may merely mention quotas).
        if (($proc.ExitCode -ne 0 -and ("$body`n$errText" -match $quotaRx)) -or ($body.Length -lt 400 -and $body -match $quotaRx) -or (-not $body -and $errText -match $quotaRx)) {
            $status = 'quota'
            $until = Get-QuotaReset "$body`n$errText"
            try {
                if (-not (Test-Path -LiteralPath $quotaDir)) { New-Item -ItemType Directory -Path $quotaDir -Force | Out-Null }
                Write-Atomic (Join-Path $quotaDir "quota-$Target.json") ([pscustomobject]@{ until = $until.ToString('o') } | ConvertTo-Json)
            } catch { }
            $reason = "$Target is out of quota (skipped until about $($until.ToString('yyyy-MM-dd HH:mm'))). Send this step to another target. Target said: " + (Limit-Text (($body + ' ' + $errText).Trim()) 300)
            $body = ''
        }
        elseif ($proc.ExitCode -eq 0 -and $body -match 'matches a user-configured deny rule') {
            $status = 'blocked'
            $reason = "$Target was refused by a deny rule (read-only mode blocks file writes). Re-run with -Edit if the task needs to change files."
        }
        elseif ($proc.ExitCode -eq 0 -and $body) { $status = 'done' }
        else {
            $status = 'failed'
            $err = if (Test-Path -LiteralPath $errFile) { ([IO.File]::ReadAllText($errFile)).Trim() } else { '' }
            if ($err.Length -gt 300) { $err = $err.Substring(0, 300) + '...' }
            if ($err -match 'cannot prompt for') {
                $status = 'blocked'
                $reason = "$Target needed a permission that headless mode cannot ask for (a shell command, or a file write in read-only mode). Re-run with -Allow <rule> for that command, or hand the task to another agent." + $(if ($err) { " Target said: $err" } else { '' })
            } else {
                $reason = "exit code $($proc.ExitCode)" + $(if (-not $body) { ', no answer' } else { '' }) + $(if ($err) { ": $err" } else { '' })
            }
        }
    } else {
        $status = 'timed out'
        $reason = "no answer within $TimeoutSec s"
        & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
    }

    # ---- Changed files (edit mode only) -----------------------------------------------------------------------
    if ($Edit) {
        $changed = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $t0 -and $_.FullName -notmatch $junk } |
            Sort-Object LastWriteTime -Descending | Select-Object -First ($maxChanged + 1))
    }
} catch {
    $status = 'failed'
    $reason = $_.Exception.Message
} finally {
    Remove-Item -LiteralPath (Join-Path $tai "run-$Target.out"), (Join-Path $tai "run-$Target.err"), (Join-Path $tai "run-$Target.in"), $setFile, $lock -Force -ErrorAction SilentlyContinue
    Clear-AgentEnv
    Remove-Item Env:TAI_DELEGATE_DEPTH -ErrorAction SilentlyContinue
    if ($from -eq 'user') { Remove-Item Env:TAI_AGENT -ErrorAction SilentlyContinue } else { $env:TAI_AGENT = $from }
}

$seconds = [int]((Get-Date) - $t0).TotalSeconds
$changedNames = @($changed | Select-Object -First $maxChanged | ForEach-Object { $_.FullName.Substring($dir.Length).TrimStart('\') })
$more = if ($changed.Count -gt $maxChanged) { " (+ more)" } else { '' }

# ---- Reply file, history ----------------------------------------------------------------------------------------
$reply = New-Object System.Text.StringBuilder
[void]$reply.AppendLine("<!-- tai delegate: from=$from target=$Target status=$status seconds=$seconds -->")
if ($status -eq 'done') { [void]$reply.AppendLine((Limit-Text $body $maxReply)) }
else { [void]$reply.AppendLine("Delegation $status. $reason"); if ($body) { [void]$reply.AppendLine(''); [void]$reply.AppendLine((Limit-Text $body $maxReply)) } }
if ($changedNames.Count) { [void]$reply.AppendLine(''); [void]$reply.AppendLine("Files changed: $($changedNames -join ', ')$more") }
Write-Atomic $replyFile $reply.ToString()

try {
    $stamp = $t0.ToString('yyyyMMdd-HHmmss')
    $saved = Join-Path $histDir "$stamp-$Target.md"
    Copy-Item -LiteralPath $replyFile -Destination $saved -Force
    $rec = [pscustomobject]@{ time = $t0.ToString('o'); from = $from; target = $Target; mode = $mode; status = $status; seconds = $seconds; allow = @($Allow | Where-Object { $_ }); wide = [bool]($wide.Count); task = (Limit-Text $Task 500); changed = $changedNames; reply = "history/$stamp-$Target.md" }
    Add-Content -LiteralPath $histLog -Value ($rec | ConvertTo-Json -Compress) -Encoding utf8
    # Keep the newest runs and drop anything older than the age limit.
    $lines = @(Get-Content -LiteralPath $histLog -Encoding UTF8 | Where-Object { $_.Trim() })
    $cut = (Get-Date).AddDays(-$keepDays)
    $kept = @()
    foreach ($l in $lines) { try { if ([datetime](($l | ConvertFrom-Json).time) -ge $cut) { $kept += $l } } catch { } }
    $kept = @($kept | Select-Object -Last $keepRuns)
    Write-Atomic $histLog (($kept -join "`n") + "`n")
    $keepNames = @($kept | ForEach-Object { try { Split-Path (($_ | ConvertFrom-Json).reply) -Leaf } catch { } })
    foreach ($f in Get-ChildItem -LiteralPath $histDir -Filter '*.md' -File -ErrorAction SilentlyContinue) {
        if ($keepNames -notcontains $f.Name) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
} catch { }

# ---- Back to the caller -----------------------------------------------------------------------------------------
if ($status -eq 'done') { Write-Output (Limit-Text $body $maxReply) } else { Write-Output "Delegation $status. $reason" }
if ($changedNames.Count) { Write-Output "Files changed: $($changedNames -join ', ')$more" }
if ($wtNote) { Write-Output $wtNote }
Write-Output "[tai delegate: $Target $status in ${seconds}s - reply saved to .tai/reply-$Target.md]"
if ($status -eq 'done') { exit 0 } elseif ($status -eq 'timed out') { exit 2 } elseif ($status -eq 'quota') { exit 3 } else { exit 1 }
