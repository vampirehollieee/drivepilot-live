@echo off
chcp 65001 >nul
title Generate DrivePilot Daily Report
cd /d "C:\Users\mar22\Documents\New project"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\live-system\daily_report.ps1"
if errorlevel 1 (
  echo.
  echo Daily report failed. Please check the error above.
  pause
  exit /b 1
)
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set TODAY=%%i
set REPORT=reports\daily_%TODAY%.md
echo.
echo Report: %CD%\%REPORT%
if exist "%REPORT%" (
  start notepad "%REPORT%"
) else (
  echo Report file was not found.
)
pause
