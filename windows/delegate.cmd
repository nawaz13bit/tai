@echo off
rem tai delegate: hand a task to another agent CLI (headless). See delegate.ps1 for the options.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0delegate.ps1" %*
exit /b %errorlevel%
