@echo off
setlocal

cd /d "%~dp0"
set "SCRIPT=%~dp0scripts\Install-WinSideUSBDevPreview.ps1"
set "LOG=%TEMP%\WinSideUSBDevPreviewInstall.log"
if not exist "%SCRIPT%" (
  echo Installer script not found:
  echo   %SCRIPT%
  pause
  exit /b 1
)

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo Requesting administrator permission...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/k ""%~f0""' -Verb RunAs"
  if errorlevel 1 (
    echo.
    echo Could not open the elevated installer window.
    echo Right-click Install-WinSideUSBDevPreview.cmd and choose Run as administrator.
    echo.
    pause
  )
  exit /b
)

echo Running WinSideUSB Developer Preview installer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "INSTALL_EXIT=%errorlevel%"
echo.
echo Installer finished with exit code %INSTALL_EXIT%.
echo Installer log:
echo   %LOG%
echo.
if not "%INSTALL_EXIT%"=="0" (
  echo Install failed. Scroll up for the error, or send the log file above.
) else (
  echo Install completed.
)
echo.
pause
exit /b %INSTALL_EXIT%
