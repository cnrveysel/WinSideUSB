param(
    [string]$InstallDir = "$env:ProgramFiles\WinSideUSB",
    [switch]$SkipDriver,
    [switch]$NoShortcuts
)

$ErrorActionPreference = "Stop"

$installLog = Join-Path $env:TEMP "WinSideUSBDevPreviewInstall.log"
try {
    Start-Transcript -Path $installLog -Append | Out-Null
}
catch {
    $installLog = $null
}

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

function Copy-Directory([string]$Source, [string]$Destination) {
    Require-Dir $Source
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function New-Shortcut([string]$Path, [string]$TargetPath, [string]$WorkingDirectory) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = $TargetPath
    $shortcut.Save()
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this installer as Administrator."
}

$sourceRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sourceRelease = Join-Path $sourceRoot "x64\Release"
$sourceDriver = Join-Path $sourceRelease "IddSampleDriver"

Require-File (Join-Path $sourceRelease "WinSideUSB.exe")
Require-File (Join-Path $sourceRelease "IddSampleDriver.cer")
Require-Dir $sourceDriver
Require-File (Join-Path $sourceDriver "IddSampleDriver.inf")
Require-File (Join-Path $sourceDriver "IddSampleDriver.dll")
Require-File (Join-Path $sourceDriver "iddsampledriver.cat")
Require-File (Join-Path $sourceRoot "WinSideUSB\swiftclientcode.swift")
Require-File (Join-Path $sourceRoot "scripts\Install-DevDriver.ps1")

$secureBoot = "Unknown"
try {
    $secureBoot = Confirm-SecureBootUEFI
}
catch {
    $secureBoot = "Unavailable"
}

$testSigningText = ""
try {
    $testSigningText = (& bcdedit /enum "{current}" 2>$null | Out-String)
}
catch {
    $testSigningText = ""
}
$testSigningOn = $testSigningText -match "testsigning\s+Yes"

Write-Host ""
Write-Host "WinSideUSB Developer Preview Installer"
if ($installLog) {
    Write-Host "Installer log: $installLog"
}
Write-Host "Install directory: $InstallDir"
Write-Host "Secure Boot: $secureBoot"
Write-Host "Windows test-signing: $(if ($testSigningOn) { 'on' } else { 'off or unknown' })"
Write-Host ""

if (-not $SkipDriver -and -not $testSigningOn) {
    Write-Warning "The development driver may not load until Windows test-signing is enabled and the PC is rebooted."
    Write-Host "If driver install/load fails, run as Administrator:"
    Write-Host "  bcdedit /set testsigning on"
    Write-Host "Then reboot. Secure Boot may need to be disabled in BIOS/UEFI."
    Write-Host ""
}

Get-Process WinSideUSB, iproxy -ErrorAction SilentlyContinue | Stop-Process -Force

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "x64\Release") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "WinSideUSB") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "scripts") | Out-Null

Copy-Item -LiteralPath (Join-Path $sourceRelease "WinSideUSB.exe") -Destination (Join-Path $InstallDir "x64\Release\WinSideUSB.exe") -Force
Copy-Item -LiteralPath (Join-Path $sourceRelease "IddSampleDriver.cer") -Destination (Join-Path $InstallDir "x64\Release\IddSampleDriver.cer") -Force
Copy-Directory $sourceDriver (Join-Path $InstallDir "x64\Release\IddSampleDriver")

Copy-Item -LiteralPath (Join-Path $sourceRoot "WinSideUSB\swiftclientcode.swift") -Destination (Join-Path $InstallDir "WinSideUSB\swiftclientcode.swift") -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\Install-DevDriver.ps1") -Destination (Join-Path $InstallDir "scripts\Install-DevDriver.ps1") -Force

foreach ($dir in @("docs", "licenses")) {
    $src = Join-Path $sourceRoot $dir
    if (Test-Path $src -PathType Container) {
        Copy-Directory $src (Join-Path $InstallDir $dir)
    }
}

foreach ($file in @("README.md", "LICENSE", "NOTICE.md", "SECURITY.md", "CONTRIBUTING.md", "START_HERE_DEV_PREVIEW.txt")) {
    $src = Join-Path $sourceRoot $file
    if (Test-Path $src -PathType Leaf) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $file) -Force
    }
}

if (-not $SkipDriver) {
    & (Join-Path $InstallDir "scripts\Install-DevDriver.ps1")
}

if (-not $NoShortcuts) {
    $exe = Join-Path $InstallDir "x64\Release\WinSideUSB.exe"
    $startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) "WinSideUSB"
    New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
    New-Shortcut (Join-Path $startMenuDir "WinSideUSB.lnk") $exe (Split-Path $exe -Parent)

    $desktop = [Environment]::GetFolderPath("Desktop")
    New-Shortcut (Join-Path $desktop "WinSideUSB.lnk") $exe (Split-Path $exe -Parent)
}

Write-Host ""
Write-Host "Installed WinSideUSB Developer Preview."
Write-Host "Run: $InstallDir\x64\Release\WinSideUSB.exe"
Write-Host "iPad Swift client source: $InstallDir\WinSideUSB\swiftclientcode.swift"

try {
    Stop-Transcript | Out-Null
}
catch {
}
