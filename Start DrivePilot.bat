@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\live-system\start_drivepilot_live.ps1"
pause
