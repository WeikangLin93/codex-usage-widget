@echo off
cd /d %~dp0
echo [%date% %time%] START > widget_start.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex_usage_widget.ps1" >> widget_start.log 2>&1
echo [%date% %time%] END code=%errorlevel% >> widget_start.log
pause
