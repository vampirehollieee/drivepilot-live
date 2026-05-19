@echo off
where python >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Please install Python or add it to PATH.
  pause
  exit /b 1
)

python ".\live-system\audit_parsed_address_classification.py"
pause
