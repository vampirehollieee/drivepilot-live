@echo off
chcp 65001 >nul
title Import DrivePilot Signal DB
cd /d "%~dp0"
python --version >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Please install Python or add it to PATH.
  pause
  exit /b 1
)
python ".\live-system\import_notifications_to_db.py"
if errorlevel 1 (
  echo.
  echo Signal DB import failed. Please check the error above.
  pause
  exit /b 1
)
pause
