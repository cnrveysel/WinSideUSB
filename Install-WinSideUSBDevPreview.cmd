@echo off
setlocal

set "SCRIPT=%~dp0scripts\Install-WinSideUSBDevPreview.ps1"
if not exist "%SCRIPT%" (
  echo Installer script not found:
  echo   %SCRIPT%
  pause
  exit /b 1
)

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo Requesting administrator permission...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo Running WinSideUSB Developer Preview installer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%SCRIPT%"
