@echo off
setlocal
powershell.exe -NoLogo -ExecutionPolicy Bypass -File "%~dp0generate-ssh-key.ps1" -PauseOnExit %*
