@echo off
:: AllGet Auto-Update Task Installer
:: This script requests Administrator privileges if not already elevated

NET SESSION >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Run the script natively in PowerShell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\setup.ps1" -Install
pause
