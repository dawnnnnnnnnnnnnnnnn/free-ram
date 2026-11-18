@echo off
title Free-Ram Setup
cd /d "%~dp0"

echo.
echo   ==============================================
echo    Free-Ram Portable - one-time setup
echo   ==============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"

echo.
pause
exit /b
