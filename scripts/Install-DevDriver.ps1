param(
    [string]$InstanceId = ""
)

$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$packageDir = Join-Path $repoRoot "x64\Release\IddSampleDriver"
$inf = Join-Path $packageDir "IddSampleDriver.inf"
$cert = Join-Path $repoRoot "x64\Release\IddSampleDriver.cer"

if (-not (Test-Path $inf)) {
    throw "Driver package not found: $inf"
}

Get-Process WinSideUSB, iproxy -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path $cert) {
    certutil -addstore -f Root $cert | Out-Host
    certutil -addstore -f TrustedPublisher $cert | Out-Host
}

pnputil /add-driver $inf /install | Out-Host

if (-not $InstanceId) {
    $device = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq "WinSideUSB Virtual Display" } |
        Select-Object -First 1

    if ($device) {
        $InstanceId = $device.InstanceId
    }
}

if ($InstanceId) {
    pnputil /restart-device $InstanceId | Out-Host
    Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction SilentlyContinue
}
else {
    $devcon = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Tools" -Recurse -Filter devcon.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\devcon\.exe$" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if (-not $devcon) {
        throw "WinSideUSB device was not found and devcon.exe was not found."
    }

    & $devcon.FullName install $inf "Root\IddSampleDriver" | Out-Host
}

pnputil /enum-devices /class Display /drivers | Out-Host
