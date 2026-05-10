param(
    [string]$Version = "0.1.0-dev",
    [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$releaseDir = Join-Path $repoRoot "x64\Release"
$driverDir = Join-Path $releaseDir "IddSampleDriver"
$packageName = "WinSideUSB-$Version-dev-preview"
$distRoot = Join-Path $repoRoot $OutDir
$packageRoot = Join-Path $distRoot $packageName
$zipPath = Join-Path $distRoot "$packageName.zip"

function Require-File([string]$Path) {
    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Required file missing: $Path"
    }
}

function Require-Dir([string]$Path) {
    if (-not (Test-Path $Path -PathType Container)) {
        throw "Required directory missing: $Path"
    }
}

Require-File (Join-Path $releaseDir "WinSideUSB.exe")
Require-File (Join-Path $releaseDir "IddSampleDriver.cer")
Require-Dir $driverDir
Require-File (Join-Path $driverDir "IddSampleDriver.inf")
Require-File (Join-Path $driverDir "IddSampleDriver.dll")
Require-File (Join-Path $driverDir "iddsampledriver.cat")
Require-File (Join-Path $repoRoot "WinSideUSB\swiftclientcode.swift")
Require-File (Join-Path $repoRoot "scripts\Install-DevDriver.ps1")
Require-File (Join-Path $repoRoot "scripts\Install-WinSideUSBDevPreview.ps1")
Require-File (Join-Path $repoRoot "scripts\Uninstall-WinSideUSBDevPreview.ps1")
Require-File (Join-Path $repoRoot "Install-WinSideUSBDevPreview.cmd")
Require-File (Join-Path $repoRoot "licenses\GPL-2.0.txt")
Require-File (Join-Path $repoRoot "licenses\LGPL-2.1.txt")

New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
if (Test-Path $packageRoot) {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot "x64\Release") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot "WinSideUSB") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot "scripts") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot "docs") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot "licenses") | Out-Null

Copy-Item -LiteralPath (Join-Path $releaseDir "WinSideUSB.exe") -Destination (Join-Path $packageRoot "x64\Release\WinSideUSB.exe") -Force
Copy-Item -LiteralPath (Join-Path $releaseDir "IddSampleDriver.cer") -Destination (Join-Path $packageRoot "x64\Release\IddSampleDriver.cer") -Force
Copy-Item -LiteralPath $driverDir -Destination (Join-Path $packageRoot "x64\Release") -Recurse -Force

Copy-Item -LiteralPath (Join-Path $repoRoot "WinSideUSB\swiftclientcode.swift") -Destination (Join-Path $packageRoot "WinSideUSB\swiftclientcode.swift") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\Install-DevDriver.ps1") -Destination (Join-Path $packageRoot "scripts\Install-DevDriver.ps1") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\Install-WinSideUSBDevPreview.ps1") -Destination (Join-Path $packageRoot "scripts\Install-WinSideUSBDevPreview.ps1") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\Uninstall-WinSideUSBDevPreview.ps1") -Destination (Join-Path $packageRoot "scripts\Uninstall-WinSideUSBDevPreview.ps1") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "Install-WinSideUSBDevPreview.cmd") -Destination (Join-Path $packageRoot "Install-WinSideUSBDevPreview.cmd") -Force

foreach ($file in @("README.md", "LICENSE", "NOTICE.md", "SECURITY.md", "CONTRIBUTING.md")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $packageRoot $file) -Force
}

foreach ($file in @("DEV_PREVIEW_RELEASE.md", "DRIVER.md", "IPAD_CLIENT.md", "TROUBLESHOOTING.md", "THIRD_PARTY.md")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "docs\$file") -Destination (Join-Path $packageRoot "docs\$file") -Force
}

Copy-Item -LiteralPath (Join-Path $repoRoot "licenses\Microsoft-Public-License.txt") -Destination (Join-Path $packageRoot "licenses\Microsoft-Public-License.txt") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "licenses\GPL-2.0.txt") -Destination (Join-Path $packageRoot "licenses\GPL-2.0.txt") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "licenses\LGPL-2.1.txt") -Destination (Join-Path $packageRoot "licenses\LGPL-2.1.txt") -Force

@"
WinSideUSB $Version Developer Preview

This package is experimental. It includes a test-signed development driver.

Quick start:
1. Extract this ZIP first. Do not run the installer from inside Windows' ZIP preview.
2. Double-click Install-WinSideUSBDevPreview.cmd.
   The setup window stays open and explains the final result.
3. Run the iPad Swift client from WinSideUSB\swiftclientcode.swift.
4. Start WinSideUSB from the desktop/start-menu shortcut.

Important:
- The setup can install the app files even when the driver is not ready yet.
- If Secure Boot is ON or Windows test-signing is OFF, the setup will show the exact steps required before the virtual display driver can load.
- Anti-cheat/protected games may refuse to run while test-signing is enabled.
- This is not a production driver or consumer installer.
- Read docs\DEV_PREVIEW_RELEASE.md before installing.
"@ | Set-Content -Path (Join-Path $packageRoot "START_HERE_DEV_PREVIEW.txt") -Encoding UTF8

Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $zipPath -Force
Write-Host "Created $zipPath"
