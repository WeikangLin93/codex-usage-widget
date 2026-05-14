@echo off
cd /d %~dp0
start "" /b wscript.exe "%~dp0run_widget_hidden.vbs"
exit /b
