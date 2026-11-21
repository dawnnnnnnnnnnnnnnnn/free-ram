@echo off
title Free-Ram
cd /d "%~dp0"

REM Strip Mark-of-the-Web so PowerShell will load the script
REM (see Setup.cmd for the full explanation)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

echo.
echo   ============================================
echo    Free-Ram : memory cleanup / process reclaim
echo    Level normal - keeps browser, game, windows
echo   ============================================
echo.
echo   Requesting administrator privileges...
echo   (click YES on the UAC prompt)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Free-Ram.ps1" -Mode full -Level normal -Elevate -Pause

exit /b
