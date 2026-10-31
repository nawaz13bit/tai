@echo off
rem Double-click to open the terminal_ai menu. Extra args pass through (e.g. tai.cmd list).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tai.ps1" %*
if errorlevel 1 pause
