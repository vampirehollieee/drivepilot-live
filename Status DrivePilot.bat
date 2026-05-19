@echo off
cd /d "C:\Users\mar22\Documents\New project"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\live-system\status_drivepilot_live.ps1"
pause
