param([Parameter(Mandatory)][string]$Path)
# Runs in its own wt tab (started by the dashboard's F key); closes when git's pager is left.
& git -C $Path -c color.ui=always diff HEAD --stat --patch
if ($LASTEXITCODE -ne 0) { Write-Host 'git diff failed (not a repo?)' -ForegroundColor Red; Start-Sleep -Seconds 2 }
