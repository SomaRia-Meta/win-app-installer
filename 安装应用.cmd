@echo off
rem Main entry: double-click to open the GUI
rem (selection list + custom install path + progress bar + live log)
rem ASCII-only on purpose: this file must survive any console code page.
setlocal
call "%~dp0install-apps-gui.cmd" %*
exit /b %ERRORLEVEL%
