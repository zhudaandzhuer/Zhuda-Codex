@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows_zhuda_log_forwarder.ps1"
echo.
pause
