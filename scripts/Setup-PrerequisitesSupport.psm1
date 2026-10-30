$ErrorActionPreference = 'Stop'

function Get-SetupAppleUsbDefinition {
    $definition = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'AppleUsbPrerequisite.json') -Raw | ConvertFrom-Json
    $uri = [uri]$definition.Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'secure-appldnld.apple.com' -or
        $definition.SHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $definition.UsbPackageSHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $definition.CabinetOffset -le 0 -or $definition.CabinetLength -le 36 -or
        $definition.Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw 'The reviewed Apple USB prerequisite definition is invalid.'
    }
    $definition
}

function Get-SetupAppleUsbState {
    $service = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
    if (-not $service) {
        return [pscustomobject]@{ Ready = $false; Message = 'Apple USB support is not installed.' }
    }
    $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='Apple Mobile Device Service'"
    $binary = [Environment]::ExpandEnvironmentVariables([string]$serviceInfo.PathName)
    if ($binary -match '^"([^"]+)"') { $binary = $Matches[1] }
    elseif ($binary -match '^(.+?\.exe)(?:\s|$)') { $binary = $Matches[1] }
    $ready = $binary -and (Test-Path -LiteralPath $binary -PathType Leaf)
    [pscustomobject]@{
        Ready = [bool]$ready
        Message = if ($ready) { 'Apple USB support is installed.' } else { 'Apple USB support needs repair.' }
    }
}

function Assert-SetupAppleFile {
    param([string]$Path, [string]$SHA256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'The Apple USB installer download is missing.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $SHA256) {
        throw 'Apple installer checksum verification failed. Nothing was run; retry the download.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Apple Inc\.(?:,|$)') {
        throw 'The downloaded installer does not have a trusted Apple signature. Nothing was run.'
    }
}

function Test-SetupAppleUsbInstaller {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-SetupAppleFile -Path $Path -SHA256 (Get-SetupAppleUsbDefinition).SHA256
}

function Test-SetupAppleUsbPackage {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-SetupAppleFile -Path $Path -SHA256 (Get-SetupAppleUsbDefinition).UsbPackageSHA256
}

function Expand-SetupAppleUsbPackage {
    param([string]$Path, [string]$DestinationDirectory)
    $definition = Get-SetupAppleUsbDefinition
    $folder = Join-Path $DestinationDirectory ('apple-usb-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $folder -Force
    $cabinetPath = Join-Path $folder 'AppleUSB.cab'
    $inputStream = [IO.File]::OpenRead($Path)
    $outputStream = $null
    try {
        if ([long]$definition.CabinetOffset + [long]$definition.CabinetLength -gt $inputStream.Length) {
            throw 'The reviewed Apple cabinet is outside the downloaded file.'
        }
        $null = $inputStream.Seek($definition.CabinetOffset, [IO.SeekOrigin]::Begin)
        $header = New-Object byte[] 12
        if ($inputStream.Read($header, 0, $header.Length) -ne $header.Length -or
            [Text.Encoding]::ASCII.GetString($header, 0, 4) -ne 'MSCF' -or
            [BitConverter]::ToUInt32($header, 8) -ne $definition.CabinetLength) {
            throw 'The reviewed Apple cabinet header does not match.'
        }
        $null = $inputStream.Seek($definition.CabinetOffset, [IO.SeekOrigin]::Begin)
        $outputStream = [IO.File]::Create($cabinetPath)
        $remaining = [long]$definition.CabinetLength
        $buffer = New-Object byte[] 1048576
        while ($remaining -gt 0) {
            $read = $inputStream.Read($buffer, 0, [int][Math]::Min($remaining, $buffer.Length))
            if ($read -eq 0) { throw 'The Apple cabinet ended unexpectedly.' }
            $outputStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        $inputStream.Dispose()
    }
    # Windows' built-in cabinet tool extracts only this fixed member name.
    $expandOutput = & (Join-Path $env:windir 'System32\expand.exe') '-F:AppleMobileDeviceSupport64.msi' $cabinetPath $folder 2>&1
    $expandCode = $LASTEXITCODE
    $expandOutput | Set-Content -LiteralPath (Join-Path $DestinationDirectory 'AppleUSB-extract.log') -Encoding UTF8
    $packagePath = Join-Path $folder 'AppleMobileDeviceSupport64.msi'
    if ($expandCode -ne 0 -or -not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw 'Windows could not extract the Apple USB support package. Retry setup.'
    }
    $packagePath
}

function Invoke-SetupAppleUsbInstaller {
    param([string]$Path, [string]$LogPath)
    $process = Start-Process -FilePath (Join-Path $env:windir 'System32\msiexec.exe') -ArgumentList @('/i', ('"' + $Path + '"'), '/qn', '/norestart', 'REBOOT=ReallySuppress', '/L*v', ('"' + $LogPath + '"')) -WindowStyle Hidden -Wait -PassThru
    [int]$process.ExitCode
}

function Start-SetupAppleUsbService {
    $service = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='Apple Mobile Device Service'"
        if ($serviceInfo.StartMode -eq 'Disabled') {
            Set-Service -Name $service.Name -StartupType Automatic
        }
        Start-Service -Name $service.Name
        (Get-Service -Name $service.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
    if ((Get-Service -Name $service.Name).Status -ne 'Running') {
        throw 'Apple USB support could not start. Restart Windows and retry setup.'
    }
}

function Test-SetupMediaFoundation {
    Test-Path -LiteralPath (Join-Path $env:windir 'System32\MFPlat.dll') -PathType Leaf
}

function Get-SetupMediaCapability {
    Get-WindowsCapability -Online -Name 'Media.MediaFeaturePack*' -ErrorAction Stop | Select-Object -First 1
}

function Add-SetupMediaCapability {
    param([string]$Name)
    Add-WindowsCapability -Online -Name $Name -ErrorAction Stop
}

function Initialize-SetupMediaFoundation {
    param([switch]$InstallMissing)
    if (Test-SetupMediaFoundation) { return $false }
    if (-not $InstallMissing) {
        throw 'Windows media components are missing. Enable the Windows N media components option in setup, or install the Media Feature Pack and restart.'
    }
    $capability = Get-SetupMediaCapability
    if (-not $capability -or $capability.Name -notlike 'Media.MediaFeaturePack~*') {
        throw 'Windows Media Foundation is missing, but this Windows edition does not offer the Media Feature Pack. Repair Windows before installing WinSideUSB.'
    }
    if ([string]$capability.State -notin @('Installed', 'InstallPending')) {
        $null = Add-SetupMediaCapability -Name $capability.Name
        $capability = Get-SetupMediaCapability
        if (-not $capability -or [string]$capability.State -notin @('Installed', 'InstallPending')) {
            throw 'Windows could not install its media components. Check the internet connection or Windows Update policy, then retry setup.'
        }
    }
    # Microsoft requires a restart after installing the Media Feature Pack.
    return $true
}

function Initialize-SetupPrerequisites {
    param([string]$AppleInstallerPath, [switch]$InstallMissingMedia, [string]$LogDirectory)
    $restart = Initialize-SetupMediaFoundation -InstallMissing:$InstallMissingMedia
    $apple = Get-SetupAppleUsbState
    if (-not $apple.Ready) {
        if (-not $AppleInstallerPath) {
            throw 'Apple USB support is missing. Enable the Apple USB support option so setup can download and install the required component.'
        }
        Test-SetupAppleUsbInstaller -Path $AppleInstallerPath
        $usbPackage = Expand-SetupAppleUsbPackage -Path $AppleInstallerPath -DestinationDirectory $LogDirectory
        Test-SetupAppleUsbPackage -Path $usbPackage
        $code = Invoke-SetupAppleUsbInstaller -Path $usbPackage -LogPath (Join-Path $LogDirectory 'AppleUSB-install.log')
        if ($code -notin @(0, 3010, 1638)) {
            throw "Apple USB installation failed (exit $code). Retry setup after other installations finish; details are in AppleUSB-install.log."
        }
        if ($code -eq 3010) { $restart = $true }
        $apple = Get-SetupAppleUsbState
        if (-not $apple.Ready) {
            if ($code -eq 3010) { return [pscustomobject]@{ RestartRequired = $true } }
            throw 'The Apple installer finished without usable Apple USB support. Repair Apple Devices/iTunes and retry setup.'
        }
    }
    try {
        Start-SetupAppleUsbService
    } catch {
        if (-not $restart) { throw }
        # An installer-requested restart may be needed before the service starts.
    }
    [pscustomobject]@{ RestartRequired = [bool]$restart }
}

Export-ModuleMember -Function Get-SetupAppleUsbDefinition, Get-SetupAppleUsbState, Test-SetupAppleUsbInstaller, Test-SetupAppleUsbPackage, Test-SetupMediaFoundation, Initialize-SetupPrerequisites
