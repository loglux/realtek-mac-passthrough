@echo off
rem --- Launch the RtlPassthru card inspector GUI (as Administrator) ---
cd /d "%~dp0"

rem self-elevate: reading the chip (diag) needs admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0card-inspector.ps1"
