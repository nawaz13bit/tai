# Interactive list of the unchecked items in LIVE-TESTS.md.
# Up/Down move, Space ticks or unticks (saved at once), A shows ticked items too, Q or Esc quits.
$file = Join-Path $PSScriptRoot 'LIVE-TESTS.md'
$utf8 = New-Object System.Text.UTF8Encoding $false
$lines = [System.IO.File]::ReadAllLines($file, $utf8)

function Get-Rows($showAll) {
    $rows = @(); $section = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## (.+)') { $section = $Matches[1]; continue }
        if ($lines[$i] -match '^- \[( |x)\] (.+)') {
            if ($showAll -or $Matches[1] -eq ' ') { $rows += [pscustomobject]@{ line = $i; section = $section; text = $Matches[2] } }
        }
    }
    return , $rows
}

$all = $false; $cursor = 0
while ($true) {
    $rows = Get-Rows $all
    if ($cursor -ge $rows.Count) { $cursor = [Math]::Max(0, $rows.Count - 1) }
    Clear-Host
    $open = @($lines | Where-Object { $_ -match '^- \[ \] ' }).Count
    Write-Host "tai live tests: $open open   (Up/Down, Space tick, A $(if ($all) { 'hide' } else { 'show' }) ticked, Q quit)" -ForegroundColor Cyan
    $width = [Math]::Max(40, [Console]::WindowWidth - 8)
    $last = ''
    for ($n = 0; $n -lt $rows.Count; $n++) {
        $r = $rows[$n]
        if ($r.section -ne $last) { Write-Host "`n$($r.section)" -ForegroundColor Yellow; $last = $r.section }
        $done = $lines[$r.line] -match '^- \[x\]'
        $text = $r.text -replace '`', ''
        if ($text.Length -gt $width) { $text = $text.Substring(0, $width - 1) + '...' }
        $box = if ($done) { '[x]' } else { '[ ]' }
        if ($n -eq $cursor) { Write-Host "> $box $text" -ForegroundColor Black -BackgroundColor Gray }
        else { Write-Host "  $box $text" -ForegroundColor $(if ($done) { 'DarkGray' } else { 'White' }) }
    }
    if (-not $rows.Count) { Write-Host "`nNothing left to test." -ForegroundColor Green }
    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
        'UpArrow'   { if ($rows.Count) { $cursor = ($cursor - 1 + $rows.Count) % $rows.Count } }
        'DownArrow' { if ($rows.Count) { $cursor = ($cursor + 1) % $rows.Count } }
        'Spacebar'  {
            if ($rows.Count) {
                $i = $rows[$cursor].line
                $lines[$i] = if ($lines[$i] -match '^- \[x\]') { $lines[$i] -replace '^- \[x\]', '- [ ]' } else { $lines[$i] -replace '^- \[ \]', '- [x]' }
                [System.IO.File]::WriteAllLines($file, $lines, $utf8)
            }
        }
        'A'         { $all = -not $all }
        'Q'         { Clear-Host; return }
        'Escape'    { Clear-Host; return }
    }
}
