[CmdletBinding()]
param(
    [ValidateSet('Check', 'Prepare', 'CloseApp')][string]$Action = 'Check',
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$AppPath
)

# Called by the elevated setup; shared Apple/VC components are never uninstalled.
$ErrorActionPreference = 'Stop'
# A setup started from PowerShell 7 can pass its module search path to 5.1.
# Prefer the running engine's built-in modules over inherited module locations.
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
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
    else {
    if (-not (Test-Path -LiteralPath (Join-Path $env:windir 'System32\MFPlat.dll') -PathType Leaf)) {
        throw 'Windows Media Foundation is missing. On Windows N, install the Media Feature Pack in Settings > Apps > Optional features, then restart and run setup again.'
    }
    $service = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
    if (-not $service) {
        throw 'Apple USB support is missing. Install Apple Devices or iTunes from Apple, then run this setup again. https://support.apple.com/118290'
    }
    $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='Apple Mobile Device Service'"
    $binary = [Environment]::ExpandEnvironmentVariables($serviceInfo.PathName)
    if ($binary -match '^"([^"]+)"') { $binary = $Matches[1] }
    elseif ($binary -match '^(.+?\.exe)(?:\s|$)') { $binary = $Matches[1] }
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw 'Apple USB support is damaged. Repair Apple Devices or iTunes, then run setup again.'
    }
    if ($Action -eq 'Prepare') {
        if ($service.Status -ne 'Running') { Start-Service -Name $service.Name }
        (Get-Service -Name $service.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    }
    $message = 'Apple USB support is available.'
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
