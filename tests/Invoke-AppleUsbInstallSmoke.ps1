# Run only on an ephemeral Windows CI machine; installs Apple's shared software.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\Setup-PrerequisitesSupport.psm1') -Force
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$before = Get-SetupAppleUsbState
if ($before.Ready) { throw 'The smoke test needs a machine without existing Apple USB support.' }
$definition = Get-SetupAppleUsbDefinition
$installer = Join-Path $OutputDirectory 'iTunes64Setup.exe'
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -UseBasicParsing -Uri $definition.Url -OutFile $installer -TimeoutSec 900
Test-SetupAppleUsbInstaller -Path $installer
$logPath = Join-Path $OutputDirectory 'AppleUSB-install.log'
$code = & (Get-Module Setup-PrerequisitesSupport) {
    param($InstallerPath, $InstallerLogPath)
    Invoke-SetupAppleUsbInstaller -Path $InstallerPath -LogPath $InstallerLogPath
} $installer $logPath
if ($code -notin @(0, 3010)) { throw "The real Apple installer failed (exit $code)." }
$after = Get-SetupAppleUsbState
if (-not $after.Ready) { throw 'Apple installation did not create usable USB service files.' }
& (Get-Module Setup-PrerequisitesSupport) { Start-SetupAppleUsbService }
$service = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction Stop
if ($service.Status -ne 'Running') { throw 'Apple USB support did not become ready.' }
[ordered]@{
    Version = $definition.Version
    SHA256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    PreviouslyInstalled = [bool]$before.Ready
    ExitCode = $code
    ServiceRunning = $true
    Computer = 'Ephemeral Windows CI runner; not a Windows 11 display/driver test'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'apple-usb-result.json') -Encoding UTF8
Write-Output 'Verified official download; real silent installation and Apple USB service startup passed.'
exit 0
