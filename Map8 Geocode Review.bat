@echo off
chcp 65001 >nul
title DrivePilot MAP8 Geocode Review
cd /d "%~dp0"
python --version >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Please install Python or add it to PATH.
  pause
  exit /b 1
)
python ".\live-system\map8_geocode_review.py"
pause
