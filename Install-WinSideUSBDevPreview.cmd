@echo off
setlocal EnableExtensions

cd /d "%~dp0" || goto cd_failed
set "SCRIPT=%CD%\scripts\Install-WinSideUSBDevPreview.ps1"
set "LOG=%TEMP%\WinSideUSBDevPreviewInstall.log"
set "CMDLOG=%TEMP%\WinSideUSBDevPreviewLauncher.log"

echo [%date% %time%] Launcher started from "%~f0" >> "%CMDLOG%"

if not exist "%SCRIPT%" goto missing_script

net session >nul 2>&1
if errorlevel 1 goto need_admin

goto run_installer

:need_admin
echo Requesting administrator permission...
echo [%date% %time%] Requesting elevation >> "%CMDLOG%"
set "WSUSB_INSTALL_SCRIPT=%SCRIPT%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',$env:WSUSB_INSTALL_SCRIPT)"
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
exit /b %ELEVATE_EXIT%

:run_installer
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

:missing_script
echo Installer script not found:
echo   %SCRIPT%
echo.
echo If you opened this file from inside the ZIP preview, extract the ZIP first.
echo Launcher log:
echo   %CMDLOG%
echo.
pause
exit /b 1

:cd_failed
echo Could not enter installer directory:
echo   %~dp0
echo.
pause
exit /b 1
