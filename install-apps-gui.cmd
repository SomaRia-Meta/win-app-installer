@echo off
rem Launcher for install-apps-gui.ps1  (graphical app installer / updater)
rem Opens a real console window (live winget output + debug) and a selection dialog.
rem Pure ASCII on purpose: this file must survive any console code page.
setlocal
chcp 65001 >nul 2>&1
title App Installer (winget)
set "PS1=%~dp0install-apps-gui.ps1"
if not exist "%PS1%" (
  echo [X] install-apps-gui.ps1 not found next to this launcher.
  pause
  exit /b 1
)
echo ================================================================
echo  winget app installer / updater
echo  - a selection window will open; pick apps, then press Start
echo  - this console shows live output for debugging
echo ================================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %RC%
