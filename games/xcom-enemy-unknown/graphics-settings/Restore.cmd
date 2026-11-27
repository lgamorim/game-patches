@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply.ps1" restore %*
set "rc=%errorlevel%"
pause
exit /b %rc%
