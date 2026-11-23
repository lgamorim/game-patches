@echo off
rem Shared runner: makes sure the Python runtime and libraries exist, then runs the patcher.
if not exist "%~dp0runtime\site\.complete" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
  if errorlevel 1 exit /b 1
)
"%~dp0runtime\python.exe" "%~dp0app\run.py" %*
