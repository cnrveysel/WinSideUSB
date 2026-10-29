[CmdletBinding()]
param(
    [ValidateSet('Check', 'CheckApple', 'Prepare', 'CloseApp')][string]$Action = 'Check',
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$AppPath,
    [string]$AppleInstallerPath,
    [switch]$InstallMissingMedia
)

# Called by the elevated setup; shared Apple/VC components are never uninstalled.
$ErrorActionPreference = 'Stop'
# A setup started from PowerShell 7 can pass its module search path to 5.1.
# Prefer the running engine's built-in modules over inherited module locations.
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
Import-Module (Join-Path $PSScriptRoot 'Setup-PrerequisitesSupport.psm1') -Force
$exitCode = 0
try {
    if ($Action -in @('Prepare', 'CloseApp') -and $AppPath) {
        if (-not ('WinSideUSB.SetupAppWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace WinSideUSB {
    public static class SetupAppWindow {
        private delegate bool EnumWindow(IntPtr window, IntPtr argument);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindow callback, IntPtr argument);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int length);
        [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        public static bool Close(int processId) {
            bool sent = false;
            EnumWindows(delegate(IntPtr window, IntPtr argument) {
                uint pid; GetWindowThreadProcessId(window, out pid);
                if (pid == processId) {
                    StringBuilder name = new StringBuilder(128);
                    GetClassName(window, name, name.Capacity);
                    if (name.ToString() == "WinSideUSBWnd")
                        sent = PostMessage(window, 0x10, IntPtr.Zero, IntPtr.Zero) || sent;
                }
                return true;
            }, IntPtr.Zero);
            return sent;
        }
    }
}
'@
        }
        $expected = [IO.Path]::GetFullPath($AppPath)
        foreach ($process in @(Get-Process -Name WinSideUSB -ErrorAction SilentlyContinue)) {
            if ($process.Path -and [IO.Path]::GetFullPath($process.Path) -eq $expected) {
                # EnumWindows also finds the app's window when hidden in the tray.
                if (-not [WinSideUSB.SetupAppWindow]::Close($process.Id) -or -not $process.WaitForExit(15000)) {
                    throw 'Close WinSideUSB and stop the display before continuing setup.'
                }
            }
        }
    }
    if ($Action -eq 'CloseApp') {
        $message = 'The installed WinSideUSB application is closed.'
    }
    elseif ($Action -eq 'Prepare') {
        $directory = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $state = Initialize-SetupPrerequisites -AppleInstallerPath $AppleInstallerPath -InstallMissingMedia:$InstallMissingMedia -LogDirectory $directory
        $exitCode = if ($state.RestartRequired) { 3010 } else { 0 }
        $message = if ($state.RestartRequired) { 'Windows components are installed. Restart Windows before opening WinSideUSB.' } else { 'Windows and Apple USB components are ready.' }
    } else {
        if ($Action -eq 'Check' -and -not (Test-SetupMediaFoundation)) {
            throw 'Windows media components are missing. Setup can install the Media Feature Pack on Windows N.'
        }
        $apple = Get-SetupAppleUsbState
        if (-not $apple.Ready) { throw $apple.Message }
        $message = $apple.Message
    }
}
catch {
    $exitCode = 1
    $message = $_.Exception.Message
}
$directory = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
[IO.File]::WriteAllText($ResultPath, $message, [Text.UTF8Encoding]::new($false))
Write-Output $message
exit $exitCode
