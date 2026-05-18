@echo off
cd /d %~dp0
set "APPDIR=%LOCALAPPDATA%\CodexUsageWidget"
if not exist "%APPDIR%" mkdir "%APPDIR%"
> "%APPDIR%\widget_config.json" echo {
>> "%APPDIR%\widget_config.json" echo   "layer_mode": "topmost",
>> "%APPDIR%\widget_config.json" echo   "opacity": 0.9,
>> "%APPDIR%\widget_config.json" echo   "game_mode_enabled": true,
>> "%APPDIR%\widget_config.json" echo   "manual_visibility": "none"
>> "%APPDIR%\widget_config.json" echo }
start "" /b wscript.exe "%~dp0run_widget_hidden.vbs"
exit /b
