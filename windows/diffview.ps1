param([Parameter(Mandatory)][string]$Path)
# Runs in its own wt tab (started by the dashboard's F key). git pages long diffs (q leaves the pager); short ones
# (or none) print straight through, so always wait for a key before the tab closes.
& git -C $Path -c color.ui=always diff HEAD --stat --patch
if ($LASTEXITCODE -ne 0) { Write-Host 'git diff failed (not a repo?)' -ForegroundColor Red }
Write-Host ''
Write-Host 'Press any key to close this tab' -ForegroundColor DarkGray
$null = [Console]::ReadKey($true)
