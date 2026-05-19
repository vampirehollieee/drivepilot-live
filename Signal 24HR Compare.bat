@echo off
chcp 65001 >nul
title DrivePilot Signal 24HR Compare
cd /d "%~dp0"
python --version >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Please install Python or add it to PATH.
  pause
  exit /b 1
)
python ".\live-system\signal_stats_24h.py"
if errorlevel 1 (
  echo.
  echo Signal 24HR compare failed. Please check the error above.
  pause
  exit /b 1
)
pause
