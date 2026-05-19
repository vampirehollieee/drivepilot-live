@echo off
where python >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Please install Python or add it to PATH.
  pause
  exit /b 1
)

python ".\live-system\build_missing_coordinate_queue.py"
pause
