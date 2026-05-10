@echo off
setlocal

cd /d "%~dp0"
set "SCRIPT=%~dp0scripts\Install-WinSideUSBDevPreview.ps1"
set "LOG=%TEMP%\WinSideUSBDevPreviewInstall.log"
set "CMDLOG=%TEMP%\WinSideUSBDevPreviewLauncher.log"
echo [%date% %time%] Launcher started from "%~f0" >> "%CMDLOG%"
if not exist "%SCRIPT%" (
  echo Installer script not found:
  echo   %SCRIPT%
  echo.
  echo If you opened this file from inside the ZIP preview, extract the ZIP first.
  echo Launcher log:
  echo   %CMDLOG%
  pause
  exit /b 1
)

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo Requesting administrator permission...
  echo [%date% %time%] Requesting elevation >> "%CMDLOG%"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%SCRIPT%')"
  set "ELEVATE_EXIT=%errorlevel%"
  echo [%date% %time%] Elevation command exit code %ELEVATE_EXIT% >> "%CMDLOG%"
  if not "%ELEVATE_EXIT%"=="0" (
    echo.
    echo Could not open the elevated installer window.
    echo Right-click Install-WinSideUSBDevPreview.cmd and choose Run as administrator.
  )
  echo.
  echo If the elevated PowerShell window opened, continue there.
  echo If nothing opened, send this launcher log:
  echo   %CMDLOG%
  echo.
  pause
  exit /b
)

echo Running WinSideUSB Developer Preview installer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%SCRIPT%"
set "INSTALL_EXIT=%errorlevel%"
echo [%date% %time%] Installer PowerShell exit code %INSTALL_EXIT% >> "%CMDLOG%"
echo.
echo Installer finished with exit code %INSTALL_EXIT%.
echo Installer log:
echo   %LOG%
echo Launcher log:
echo   %CMDLOG%
echo.
if not "%INSTALL_EXIT%"=="0" (
  echo Install failed. Scroll up for the error, or send the log file above.
) else (
  echo Install completed.
)
echo.
pause
exit /b %INSTALL_EXIT%
