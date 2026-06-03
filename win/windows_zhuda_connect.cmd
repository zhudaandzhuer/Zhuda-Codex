@echo off
setlocal
set SCRIPT=%~dp0windows_zhuda_connect.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
