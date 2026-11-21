@echo off
REM self-elevate to admin, then run the PS1 with ExecutionPolicy Bypass
net session >nul 2>&1
if %errorlevel% NEQ 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0passthrough-enable.ps1" 
echo.
pause
