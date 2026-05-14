@echo off
cd /d %~dp0
> widget_config.json echo {
>> widget_config.json echo   "layer_mode": "topmost",
>> widget_config.json echo   "opacity": 0.9,
>> widget_config.json echo   "game_mode_enabled": true,
>> widget_config.json echo   "manual_visibility": "none"
>> widget_config.json echo }
start "" /b wscript.exe "%~dp0run_widget_hidden.vbs"
exit /b
