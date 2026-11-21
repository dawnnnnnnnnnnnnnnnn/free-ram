@echo off
title Free-Ram Setup
cd /d "%~dp0"

REM ---------------------------------------------------------------
REM Strip Mark-of-the-Web first.
REM A zip downloaded from WeChat / QQ / a browser tags every extracted
REM file with Zone.Identifier=3. PowerShell then refuses to load the
REM .ps1 before it even prints an error. .bat files are exempt from
REM that gate, so this wrapper is the only thing guaranteed to run -
REM its first job is to clear the tag from the whole folder.
REM ---------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

echo.
echo   ==============================================
echo    Free-Ram Portable - one-time setup
echo   ==============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"

echo.
pause
exit /b
