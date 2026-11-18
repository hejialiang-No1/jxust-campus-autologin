@echo off
chcp 65001 >nul
title JXUST Campus Auto Login - Login Now
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusAutoLogin.ps1" -Action Login
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusAutoLogin.ps1" -Action ClosePopup
echo.
pause
