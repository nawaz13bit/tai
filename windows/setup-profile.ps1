# Add (or update) a "terminal_ai" profile in Windows Terminal's settings.json.
# Usage: setup-profile.ps1 [-FontSize 8]
param([int]$FontSize = 8)

$path = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
$guid = '{7d1f3c52-9a4e-5b86-a2d0-3e6c1f8b4a97}'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = [IO.File]::ReadAllText($path, $utf8)
if (-not (Test-Path "$path.bak")) { Copy-Item $path "$path.bak" }

# Only our own profile counts as "exists": identified by its guid, not by the name appearing anywhere in the file.
if ($text.Contains($guid)) {
    # Change the font size inside that one profile object only (it may contain one level of nested braces, like "font").
    $objRe = '\{(?:[^{}]|\{[^{}]*\})*"guid"\s*:\s*"' + [regex]::Escape($guid) + '"(?:[^{}]|\{[^{}]*\})*\}'
    $m = [regex]::Match($text, $objRe)
    if (-not $m.Success) { throw 'Found the terminal_ai guid but could not isolate its profile object; edit settings.json by hand.' }
    $fontRe = '("font"\s*:\s*\{[^{}]*?"size"\s*:\s*)\d+'
    if (-not [regex]::IsMatch($m.Value, $fontRe)) { throw 'The terminal_ai profile has no font size to change; edit settings.json by hand.' }
    $obj = [regex]::Replace($m.Value, $fontRe, "`${1}$FontSize")
    $text = $text.Substring(0, $m.Index) + $obj + $text.Substring($m.Index + $m.Length)
    [IO.File]::WriteAllText($path, $text, $utf8)
    Write-Host "Set terminal_ai font size to $FontSize."
    return
}

$profile = @"
            {
                "commandline": "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                "font": { "size": $FontSize },
                "guid": "$guid",
                "hidden": true,
                "name": "terminal_ai"
            },
"@
$m = [regex]::Match($text, '"list"\s*:\s*\[')
if (-not $m.Success) { throw 'Could not find profiles list in settings.json.' }
$entry = $profile.TrimEnd()
# An empty list would be left with a trailing comma before "]", which is invalid JSON.
if ($text.Substring($m.Index + $m.Length) -match '^\s*\]') { $entry = $entry.TrimEnd(',') }
$text = $text.Insert($m.Index + $m.Length, [Environment]::NewLine + $entry)
[IO.File]::WriteAllText($path, $text, $utf8)
Write-Host "Added terminal_ai profile (font size $FontSize)."
