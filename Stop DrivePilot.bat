@echo off
cd /d "C:\Users\mar22\Documents\New project"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\live-system\stop_drivepilot_live.ps1"
pause
