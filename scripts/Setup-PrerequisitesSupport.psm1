$ErrorActionPreference = 'Stop'

function Get-SetupAppleUsbDefinition {
    $definition = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'AppleUsbPrerequisite.json') -Raw | ConvertFrom-Json
    $uri = [uri]$definition.Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'secure-appldnld.apple.com' -or
        $definition.SHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or
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

function Test-SetupAppleUsbInstaller {
    param([Parameter(Mandatory = $true)][string]$Path)
    $definition = Get-SetupAppleUsbDefinition
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'The Apple USB installer download is missing.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $definition.SHA256) {
        throw 'Apple installer checksum verification failed. Nothing was run; retry the download.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Apple Inc\.(?:,|$)') {
        throw 'The downloaded installer does not have a trusted Apple signature. Nothing was run.'
    }
}

function Invoke-SetupAppleUsbInstaller {
    param([string]$Path, [string]$LogPath)
    $process = Start-Process -FilePath $Path -ArgumentList @('/quiet', '/norestart', '/log', ('"' + $LogPath + '"')) -WindowStyle Hidden -Wait -PassThru
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
            throw 'Apple USB support is missing. Enable the Apple USB support option in setup so it can download and install iTunes.'
        }
        Test-SetupAppleUsbInstaller -Path $AppleInstallerPath
        $code = Invoke-SetupAppleUsbInstaller -Path $AppleInstallerPath -LogPath (Join-Path $LogDirectory 'AppleUSB-install.log')
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

Export-ModuleMember -Function Get-SetupAppleUsbDefinition, Get-SetupAppleUsbState, Test-SetupAppleUsbInstaller, Test-SetupMediaFoundation, Initialize-SetupPrerequisites
