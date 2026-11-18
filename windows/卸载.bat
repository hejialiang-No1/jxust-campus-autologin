@echo off
chcp 65001 >nul
title JXUST Campus Auto Login - Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusAutoLogin.ps1" -Action Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusAutoLogin.ps1" -Action RestoreProbe
echo.
echo Config and saved password were kept. Re-run Setup any time.
pause
