@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply.ps1" apply %*
set "rc=%errorlevel%"
pause
exit /b %rc%
