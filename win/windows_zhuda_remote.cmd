@echo off
setlocal
set SCRIPT=%~dp0windows_zhuda_remote.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
