@echo off
title Free-Ram
cd /d "%~dp0"

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
