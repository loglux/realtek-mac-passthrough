@echo off
rem --- Запуск GUI-смотрелки Realtek Card Inspector (с правами админа) ---
cd /d "%~dp0"

rem self-elevate: чтение чипа (diag) требует админа
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0card-inspector.ps1"
