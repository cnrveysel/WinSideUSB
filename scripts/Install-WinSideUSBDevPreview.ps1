param(
    [string]$InstallDir = "$env:ProgramFiles\WinSideUSB",
    [switch]$SkipDriver,
    [switch]$NoShortcuts
)

$ErrorActionPreference = "Stop"
$setupExitCode = 0
$installLog = Join-Path $env:TEMP "WinSideUSBDevPreviewInstall.log"
$driverStatus = "Not checked"
$driverMessage = ""

try {
    Start-Transcript -Path $installLog -Append | Out-Null
}
catch {
    $installLog = $null
}

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Host "== $Text =="
}

function Write-Ok([string]$Text) {
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-WarnLine([string]$Text) {
    Write-Host "[!] $Text" -ForegroundColor Yellow
}

function Write-FailLine([string]$Text) {
    Write-Host "[X] $Text" -ForegroundColor Red
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

function Get-SecureBootState {
    try {
        $value = Confirm-SecureBootUEFI
        if ($value -eq $true) { return "On" }
        if ($value -eq $false) { return "Off" }
        return "Unknown"
    }
    catch {
        return "Unavailable"
    }
}

function Get-TestSigningState {
    try {
        $text = (& bcdedit /enum "{current}" 2>$null | Out-String)
        if ($text -match "(?im)^\s*testsigning\s+Yes\s*$") {
            return "On"
        }
        return "Off"
    }
    catch {
        return "Unknown"
    }
}

function Get-WinSideUsbDisplayDevice {
    Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq "WinSideUSB Virtual Display" } |
        Select-Object -First 1
}

function Show-DriverPreparationHelp([string]$SecureBoot, [string]$TestSigning) {
    if ($SecureBoot -eq "On") {
        Write-WarnLine "Secure Boot is ON. Windows usually blocks test-signed drivers while Secure Boot is enabled."
        Write-Host "    To use the development driver:"
        Write-Host "    1. Disable Secure Boot in BIOS/UEFI."
        Write-Host "    2. Boot Windows again."
        Write-Host "    3. Open Command Prompt as Administrator and run:"
        Write-Host "       bcdedit /set testsigning on"
        Write-Host "    4. Reboot, then run this setup again."
        return
    }

    if ($TestSigning -ne "On") {
        Write-WarnLine "Windows test-signing is not enabled. The app can be installed, but the virtual display driver will not load yet."
        Write-Host "    To enable it:"
        Write-Host "    1. Open Command Prompt as Administrator."
        Write-Host "    2. Run:"
        Write-Host "       bcdedit /set testsigning on"
        Write-Host "    3. Reboot, then run this setup again."
    }
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required. Please run Install-WinSideUSBDevPreview.cmd as Administrator."
    }

    $sourceRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $sourceRelease = Join-Path $sourceRoot "x64\Release"
    $sourceDriver = Join-Path $sourceRelease "IddSampleDriver"
    $expectedExe = Join-Path $sourceRelease "WinSideUSB.exe"

    Write-Section "Package Check"
    if (-not (Test-Path $expectedExe -PathType Leaf)) {
        throw @"
This setup must be run from the packaged WinSideUSB developer-preview ZIP, not from GitHub's Code/Source ZIP.

Missing:
  $expectedExe

Download the packaged build from:
  https://github.com/cnrveysel/WinSideUSB/releases

Look for:
  WinSideUSB-*-dev-preview.zip
"@
    }

    Require-File $expectedExe
    Require-File (Join-Path $sourceRelease "IddSampleDriver.cer")
    Require-Dir $sourceDriver
    Require-File (Join-Path $sourceDriver "IddSampleDriver.inf")
    Require-File (Join-Path $sourceDriver "IddSampleDriver.dll")
    Require-File (Join-Path $sourceDriver "iddsampledriver.cat")
    Require-File (Join-Path $sourceRoot "WinSideUSB\swiftclientcode.swift")
    Require-File (Join-Path $sourceRoot "scripts\Install-DevDriver.ps1")
    Write-Ok "Package files found."

    $secureBoot = Get-SecureBootState
    $testSigning = Get-TestSigningState
    $driverModeReady = ($testSigning -eq "On" -and $secureBoot -ne "On")

    Write-Section "System Check"
    Write-Host "Install directory: $InstallDir"
    Write-Host "Installer log: $(if ($installLog) { $installLog } else { 'Unavailable' })"
    Write-Host "Secure Boot: $secureBoot"
    Write-Host "Windows test-signing: $testSigning"

    if ($SkipDriver) {
        Write-WarnLine "Driver installation was skipped by request."
    }
    elseif ($driverModeReady) {
        Write-Ok "Windows is prepared for the development driver."
    }
    else {
        Show-DriverPreparationHelp $secureBoot $testSigning
        $setupExitCode = 2
    }

    Write-Section "Installing App Files"
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
    Write-Ok "App files copied."

    if (-not $NoShortcuts) {
        Write-Section "Creating Shortcuts"
        $exe = Join-Path $InstallDir "x64\Release\WinSideUSB.exe"
        $startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) "WinSideUSB"
        New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
        New-Shortcut (Join-Path $startMenuDir "WinSideUSB.lnk") $exe (Split-Path $exe -Parent)

        $desktop = [Environment]::GetFolderPath("Desktop")
        New-Shortcut (Join-Path $desktop "WinSideUSB.lnk") $exe (Split-Path $exe -Parent)
        Write-Ok "Shortcuts created."
    }

    if ($SkipDriver) {
        $driverStatus = "Skipped"
        $driverMessage = "Driver installation was skipped."
    }
    elseif (-not $driverModeReady) {
        $driverStatus = "Not ready"
        $driverMessage = "Windows must be prepared for test-signed drivers before the virtual display driver can load."
    }
    else {
        Write-Section "Installing Development Driver"
        try {
            & (Join-Path $InstallDir "scripts\Install-DevDriver.ps1")
            $driverStatus = "Installed"
            $driverMessage = "Driver installer completed."
        }
        catch {
            $driverStatus = "Install failed"
            $driverMessage = $_.Exception.Message
            $setupExitCode = 2
            Write-WarnLine "Driver install failed: $driverMessage"
        }
    }

    Write-Section "Driver State"
    $device = Get-WinSideUsbDisplayDevice
    if ($device) {
        Write-Host "Device: $($device.FriendlyName)"
        Write-Host "Status: $($device.Status)"
        Write-Host "Instance: $($device.InstanceId)"
        if ($device.Status -eq "OK") {
            Write-Ok "Virtual display device is present."
        }
        else {
            Write-WarnLine "Virtual display device exists but is not fully ready."
            $setupExitCode = 2
        }
    }
    else {
        Write-WarnLine "Virtual display device was not found."
        if (-not $SkipDriver) {
            $setupExitCode = 2
        }
    }

    Write-Section "Result"
    Write-Ok "WinSideUSB app files are installed."
    Write-Host "App path:"
    Write-Host "  $InstallDir\x64\Release\WinSideUSB.exe"
    Write-Host "iPad Swift client:"
    Write-Host "  $InstallDir\WinSideUSB\swiftclientcode.swift"
    Write-Host "Driver status: $driverStatus"
    if ($driverMessage) {
        Write-Host "Driver note: $driverMessage"
    }

    if ($setupExitCode -eq 0) {
        Write-Ok "Setup is complete. Start the iPad Swift client first, then run WinSideUSB."
    }
    else {
        Write-WarnLine "Setup installed the app, but one or more driver steps still need attention."
        Show-DriverPreparationHelp $secureBoot $testSigning
        Write-Host "After fixing the driver prerequisites, reboot and run this setup again."
    }
}
catch {
    $setupExitCode = 1
    Write-Section "Setup Failed"
    Write-FailLine $_.Exception.Message
    Write-Host ""
    Write-Host "Installer log:"
    Write-Host "  $(if ($installLog) { $installLog } else { 'Unavailable' })"
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}

exit $setupExitCode
