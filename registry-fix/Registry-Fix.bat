@echo off
rem --- Launch Registry Fix: MAC pass-through in Windows without changing the card (as Administrator) ---
cd /d "%~dp0"

rem self-elevate: writing the driver settings in the registry needs admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0registry-fix.ps1"
