@echo off
set "ZHUDA_LAUNCHER=%~dp0Zhuda-Codex-Launcher.ps1"
powershell -NoProfile -STA -ExecutionPolicy Bypass -Command "try { & '%ZHUDA_LAUNCHER%' } catch { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Zhuda-Codex Launcher Error') | Out-Null; exit 1 }"
if errorlevel 1 pause
