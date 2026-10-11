@echo off
chcp 65001 >nul
fltmc >nul 2>&1 || (
  echo Requesting administrator privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tether-doctor.ps1" -Apply -Test
echo.
pause
