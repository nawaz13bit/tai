# Add (or update) a "terminal_ai" profile in Windows Terminal's settings.json.
# Usage: setup-profile.ps1 [-FontSize 8]
param([int]$FontSize = 8)

$path = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
$text = Get-Content $path -Raw
if (-not (Test-Path "$path.bak")) { Copy-Item $path "$path.bak" }

if ($text -match 'terminal_ai') {
    # Profile exists: only change its font size.
    $text = [regex]::Replace($text, '("font"\s*:\s*\{\s*"size"\s*:\s*)\d+', "`${1}$FontSize")
    Set-Content $path $text -Encoding utf8
    Write-Host "Set terminal_ai font size to $FontSize."
    return
}

$profile = @"
            {
                "commandline": "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
                "font": { "size": $FontSize },
                "guid": "{7d1f3c52-9a4e-5b86-a2d0-3e6c1f8b4a97}",
                "hidden": true,
                "name": "terminal_ai"
            },
"@
$m = [regex]::Match($text, '"list"\s*:\s*\[')
if (-not $m.Success) { throw 'Could not find profiles list in settings.json.' }
$text = $text.Insert($m.Index + $m.Length, [Environment]::NewLine + $profile.TrimEnd())
Set-Content $path $text -Encoding utf8
Write-Host "Added terminal_ai profile (font size $FontSize)."
