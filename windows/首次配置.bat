@echo off
chcp 65001 >nul
title JXUST Campus Auto Login - Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusAutoLogin.ps1" -Action Setup
echo.
pause
