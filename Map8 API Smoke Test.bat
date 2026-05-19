@echo off
chcp 65001 >nul
title DrivePilot MAP8 API Smoke Test
cd /d "%~dp0"
python --version >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Please install Python or add it to PATH.
  pause
  exit /b 1
)
python ".\live-system\map8_api_smoke_test.py"
pause
