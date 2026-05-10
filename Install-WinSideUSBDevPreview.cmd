@echo off
setlocal EnableExtensions

title WinSideUSB Developer Preview Setup
cd /d "%~dp0" || goto cd_failed

set "SCRIPT=%CD%\scripts\Install-WinSideUSBDevPreview.ps1"
set "INSTALL_LOG=%TEMP%\WinSideUSBDevPreviewInstall.log"
set "LAUNCHER_LOG=%TEMP%\WinSideUSBDevPreviewLauncher.log"

echo [%date% %time%] Launcher started from "%~f0" >> "%LAUNCHER_LOG%"

echo.
echo ============================================================
echo  WinSideUSB Developer Preview Setup
echo ============================================================
echo.
echo This window will stay open and show the full setup result.
echo.

if not exist "%SCRIPT%" goto missing_script

net session >nul 2>&1
if errorlevel 1 goto need_admin

goto run_installer

:need_admin
echo Administrator permission is required.
echo A new elevated Command Prompt will open after the UAC prompt.
echo.
echo [%date% %time%] Requesting elevation >> "%LAUNCHER_LOG%"
set "WSUSB_LAUNCHER=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $args='/k call ' + $q + $env:WSUSB_LAUNCHER + $q + ' --elevated'; Start-Process -FilePath 'cmd.exe' -Verb RunAs -ArgumentList $args"
set "ELEVATE_EXIT=%errorlevel%"
echo [%date% %time%] Elevation command exit code %ELEVATE_EXIT% >> "%LAUNCHER_LOG%"

if not "%ELEVATE_EXIT%"=="0" (
  echo.
  echo Could not open the elevated setup window.
  echo Right-click Install-WinSideUSBDevPreview.cmd and choose Run as administrator.
  echo.
  echo Launcher log:
  echo   %LAUNCHER_LOG%
  echo.
  pause
  exit /b %ELEVATE_EXIT%
)

echo If the elevated setup window opened, continue there.
echo This non-elevated launcher can be closed.
echo.
pause
exit /b 0

:run_installer
echo Running setup as Administrator...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "INSTALL_EXIT=%errorlevel%"
echo [%date% %time%] Installer PowerShell exit code %INSTALL_EXIT% >> "%LAUNCHER_LOG%"
echo.
echo ============================================================
if "%INSTALL_EXIT%"=="0" (
  echo  Setup completed successfully.
) else if "%INSTALL_EXIT%"=="2" (
  echo  Setup completed with required follow-up steps.
) else (
  echo  Setup failed.
)
echo ============================================================
echo.
echo Installer log:
echo   %INSTALL_LOG%
echo Launcher log:
echo   %LAUNCHER_LOG%
echo.
pause
exit /b %INSTALL_EXIT%

:missing_script
echo Setup script not found:
echo   %SCRIPT%
echo.
echo This usually means the ZIP was not extracted correctly.
echo Extract the full WinSideUSB developer-preview ZIP first, then run this file again.
echo.
echo Launcher log:
echo   %LAUNCHER_LOG%
echo.
pause
exit /b 1

:cd_failed
echo Could not enter setup directory:
echo   %~dp0
echo.
pause
exit /b 1
