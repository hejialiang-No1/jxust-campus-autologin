@echo off
chcp 65001 >nul
title JXUST Campus Auto Login - Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusAutoLogin.ps1" -Action Status
echo.
pause
