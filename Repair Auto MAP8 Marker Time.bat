@echo off
setlocal
cd /d "%~dp0"
python live-system\auto_map8_coordinate_import.py --repair-auto-map8-time
pause
