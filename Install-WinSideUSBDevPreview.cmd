@echo off
setlocal

set "SCRIPT=%~dp0scripts\Install-WinSideUSBDevPreview.ps1"
if not exist "%SCRIPT%" (
  echo Installer script not found:
  echo   %SCRIPT%
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%SCRIPT%""'"

