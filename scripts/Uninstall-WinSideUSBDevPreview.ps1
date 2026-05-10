param(
    [string]$InstallDir = "$env:ProgramFiles\WinSideUSB",
    [switch]$KeepDriver
)

$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this uninstaller as Administrator."
}

Get-Process WinSideUSB, iproxy -ErrorAction SilentlyContinue | Stop-Process -Force

if (-not $KeepDriver) {
    $devices = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq "WinSideUSB Virtual Display" }

    foreach ($device in $devices) {
        pnputil /remove-device $device.InstanceId | Out-Host
    }
}

$startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) "WinSideUSB"
if (Test-Path $startMenuDir) {
    Remove-Item -LiteralPath $startMenuDir -Recurse -Force
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "WinSideUSB.lnk"
if (Test-Path $desktopShortcut) {
    Remove-Item -LiteralPath $desktopShortcut -Force
}

if (Test-Path $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}

Write-Host "Removed WinSideUSB Developer Preview."
if ($KeepDriver) {
    Write-Host "Driver was left installed because -KeepDriver was specified."
}

