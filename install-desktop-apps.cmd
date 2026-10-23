@echo off
rem Launcher for install-desktop-apps.ps1
rem Bypasses the execution policy for this one file only (no machine-wide change).
rem Pure ASCII on purpose: this file must survive any console code page.
setlocal
chcp 65001 >nul 2>&1
set "PS1=%~dp0install-desktop-apps.ps1"
if not exist "%PS1%" (
  echo [X] install-desktop-apps.ps1 not found next to this launcher.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
rem Pause only when launched with no arguments (i.e. double-clicked).
if "%~1"=="" pause
exit /b %RC%
