@echo off
REM Launch the Realtek MAC Pass-Through GUI (elevates to admin, STA for WinForms)
net session >nul 2>&1
if %errorlevel% NEQ 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0passthrough-gui.ps1"
