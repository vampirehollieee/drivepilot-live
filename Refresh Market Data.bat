@echo off
chcp 65001 >nul
title DrivePilot Refresh Market Data
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
  echo Refresh market data failed. Please check the error above.
  pause
  exit /b 1
)

echo.
echo Market data refreshed.
pause
