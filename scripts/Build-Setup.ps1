[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')][string]$Version = '0.3.11',
    [ValidateSet('Signed', 'Release', 'Development')][string]$DriverMode = 'Signed',
    [string]$AppPath,
    [string]$ServicePath,
    [string]$DriverPackageDir,
    [string]$CertificatePath,
    [string]$VcRedistPath,
    [string]$CompilerPath,
    [string]$OutputDir = 'dist',
    [ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$SigningCertificateThumbprint,
    [string]$SignToolPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'Setup-PrerequisitesSupport.psm1') -Force
$applePrerequisite = Get-SetupAppleUsbDefinition
if (-not $AppPath) { $AppPath = Join-Path $repoRoot 'x64\Release\WinSideUSB.exe' }
if (-not $DriverPackageDir) {
    $DriverPackageDir = if ($DriverMode -eq 'Signed') { Join-Path $repoRoot '.codex\vendor\VirtualDisplayDriver' } else { Join-Path $repoRoot 'x64\Release\IddSampleDriver' }
}
if ($DriverMode -eq 'Signed' -and -not $ServicePath) { $ServicePath = Join-Path $repoRoot 'x64\Release\WinSideUSBDisplayService.exe' }
if (-not $CertificatePath -and $DriverMode -eq 'Development') {
    $CertificatePath = Join-Path $repoRoot 'x64\Release\IddSampleDriver.cer'
}
function Resolve-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file missing: $Path" }
    (Resolve-Path -LiteralPath $Path).Path
}
$AppPath = Resolve-File $AppPath
$DriverPackageDir = (Resolve-Path -LiteralPath $DriverPackageDir).Path
$driverFiles = if ($DriverMode -eq 'Signed') { @('MttVDD.inf', 'MttVDD.dll', 'mttvdd.cat') } else { @('IddSampleDriver.inf', 'IddSampleDriver.dll', 'IddSampleDriver.cat') }
foreach ($name in $driverFiles) {
    $null = Resolve-File (Join-Path $DriverPackageDir $name)
}
if ($DriverMode -eq 'Development') { $CertificatePath = Resolve-File $CertificatePath }
if ($DriverMode -eq 'Signed') { $ServicePath = Resolve-File $ServicePath }

if (-not $CompilerPath) {
    $candidates = @(
        (Join-Path $repoRoot '.codex\setup-tools\inno\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $CompilerPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $CompilerPath) { throw 'Install Inno Setup 6.7+ from https://jrsoftware.org/isdl.php or supply -CompilerPath.' }
}
$CompilerPath = Resolve-File $CompilerPath
if (-not $VcRedistPath) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        foreach ($installation in @(& $vswhere -products '*' -property installationPath)) {
            $redistRoot = Join-Path $installation 'VC\Redist\MSVC'
            if (Test-Path -LiteralPath $redistRoot) {
                $VcRedistPath = Get-ChildItem -LiteralPath $redistRoot -Filter vc_redist.x64.exe -Recurse |
                    Sort-Object { [version]$_.VersionInfo.ProductVersion } -Descending |
                    Select-Object -First 1 -ExpandProperty FullName
                if ($VcRedistPath) { break }
            }
        }
    }
    if (-not $VcRedistPath) { throw 'Supply -VcRedistPath using the Microsoft x64 redistributable: https://aka.ms/vc14/vc_redist.x64.exe' }
}
$VcRedistPath = Resolve-File $VcRedistPath
$signature = Get-AuthenticodeSignature -LiteralPath $VcRedistPath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
    throw 'The VC++ redistributable must have a valid Microsoft signature.'
}
$runtimeVersion = [version](Get-Item -LiteralPath $VcRedistPath).VersionInfo.ProductVersion
if ($runtimeVersion -lt [version]'14.44.35211.0') { throw 'VC++ runtime 14.44.35211.0 or newer is required by this build.' }

# Check the actual executable resources, rather than trusting adjacent USB files.
if (-not ('WinSideUsbSetupPayload' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class WinSideUsbSetupPayload {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")] static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    public static void Validate(string path) {
        IntPtr module = LoadLibraryEx(path, IntPtr.Zero, 0x22);
        if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            for (int id=10000; id<=10024; id++) {
                IntPtr resource = FindResource(module, new IntPtr(id), new IntPtr(10));
                if (resource == IntPtr.Zero || SizeofResource(module, resource) == 0)
                    throw new Exception("Missing embedded USB runtime resource " + id);
            }
        } finally { FreeLibrary(module); }
    }
}
'@
}
[WinSideUsbSetupPayload]::Validate($AppPath)

if ($DriverMode -eq 'Release') {
    foreach ($path in @($AppPath, (Join-Path $DriverPackageDir 'IddSampleDriver.dll'), (Join-Path $DriverPackageDir 'IddSampleDriver.cat'))) {
        if ((Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') {
            throw "Release packaging requires trusted signatures: $path is not release-ready. -DriverMode Development is only for explicit test packages."
        }
    }
    if (-not $SigningCertificateThumbprint) {
        throw 'Release setup requires -SigningCertificateThumbprint to sign setup and its uninstaller. Development builds can remain unsigned.'
    }
}
if ($SigningCertificateThumbprint) {
    if (-not $SignToolPath) {
        $SignToolPath = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    $SignToolPath = Resolve-File $SignToolPath
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$SigningCertificateThumbprint" -ErrorAction SilentlyContinue
    if (-not $certificate -or -not $certificate.HasPrivateKey) {
        throw 'Setup signing needs the matching certificate/private key in CurrentUser\My (not a PFX in source).'
    }
}

$outputRoot = if ([IO.Path]::IsPathRooted($OutputDir)) { [IO.Path]::GetFullPath($OutputDir) } else { [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir)) }
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$stagingRoot = Join-Path $repoRoot '.codex\setup-build'
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
# New staging per build avoids any recursive deletion of computed paths.
$payloadDir = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
foreach ($folder in @('', 'driver', 'scripts', 'docs', 'licenses', 'iPad')) {
    New-Item -ItemType Directory -Path (Join-Path $payloadDir $folder) -Force | Out-Null
}
Copy-Item -LiteralPath $AppPath -Destination (Join-Path $payloadDir 'WinSideUSB.exe')
if ($DriverMode -eq 'Signed') { Copy-Item -LiteralPath $ServicePath -Destination (Join-Path $payloadDir 'WinSideUSBDisplayService.exe') }
Copy-Item -LiteralPath $VcRedistPath -Destination (Join-Path $payloadDir 'vc_redist.x64.exe')
foreach ($name in $driverFiles) {
    Copy-Item -LiteralPath (Join-Path $DriverPackageDir $name) -Destination (Join-Path $payloadDir 'driver')
}
if ($DriverMode -eq 'Development') {
    Copy-Item -LiteralPath $CertificatePath -Destination (Join-Path $payloadDir 'driver\IddSampleDriver.cer')
}
foreach ($name in @('Setup-Driver.ps1', 'Setup-DriverSupport.psm1', 'Setup-Prerequisites.ps1', 'Setup-PrerequisitesSupport.psm1', 'AppleUsbPrerequisite.json')) {
    Copy-Item -LiteralPath (Resolve-File (Join-Path $PSScriptRoot $name)) -Destination (Join-Path $payloadDir 'scripts')
}
foreach ($name in @('LICENSE', 'NOTICE.md')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $name) -Destination $payloadDir
}
Copy-Item -Path (Join-Path $repoRoot 'licenses\*') -Destination (Join-Path $payloadDir 'licenses') -Recurse
Copy-Item -Path (Join-Path $repoRoot 'docs\*.md') -Destination (Join-Path $payloadDir 'docs')
Copy-Item -LiteralPath (Join-Path $repoRoot 'installer\iPad-Guide.html') -Destination (Join-Path $payloadDir 'docs')
foreach ($name in @('README.md', 'ROADMAP.md')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $name) -Destination (Join-Path $payloadDir 'docs')
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'WinSideUSB\swiftclientcode.swift') -Destination (Join-Path $payloadDir 'iPad')

# Build host need not enable test mode. Package hashes/signatures remain mandatory.
Import-Module (Join-Path $PSScriptRoot 'Setup-DriverSupport.psm1') -Force
if ($DriverMode -eq 'Signed') {
    $modeCount = New-SetupDisplayConfiguration -AppSourcePath (Join-Path $repoRoot 'WinSideUSB\WinSideUSB.cpp') -DestinationPath (Join-Path $payloadDir 'driver\vdd_settings.xml')
    Write-Host "Included $modeCount display resolutions with the existing 60/120 Hz modes."
}
$null = Test-SetupPackage -PackageDir (Join-Path $payloadDir 'driver') -DriverMode $DriverMode -CertificatePath $CertificatePath -SkipMachineChecks
$manifest = [ordered]@{
    Version = $Version; DriverMode = $DriverMode; Architecture = 'x64'; MinimumWindowsBuild = 22000
    RuntimeVersion = $runtimeVersion.ToString(); CreatedUtc = [DateTime]::UtcNow.ToString('o')
    AppleUsbPrerequisite = [ordered]@{ Version = $applePrerequisite.Version; Url = $applePrerequisite.Url; SHA256 = $applePrerequisite.SHA256; UsbPackageVersion = $applePrerequisite.UsbPackageVersion; UsbPackageSHA256 = $applePrerequisite.UsbPackageSHA256; DownloadedOnlyIfMissing = $true }
    Files = @(Get-ChildItem -LiteralPath $payloadDir -File -Recurse | ForEach-Object {
        [ordered]@{ Path = $_.FullName.Substring($payloadDir.Length + 1); SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
}
if ($DriverMode -eq 'Signed') {
    $manifest.DriverProvider = 'VirtualDrivers/Virtual-Display-Driver'
    $manifest.DriverVersion = '25.7.23'
    $manifest.DriverSource = 'https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.7.23'
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $payloadDir 'payload-manifest.json') -Encoding UTF8
$compilerArgs = @('/Qp', "/DPayloadDir=$payloadDir", "/DOutputDir=$outputRoot", "/DAppVersion=$Version", "/DDriverMode=$DriverMode", "/DRuntimeVersion=$runtimeVersion")
$compilerArgs += "/DAppleInstallerUrl=$($applePrerequisite.Url)"
$compilerArgs += "/DAppleInstallerSHA256=$($applePrerequisite.SHA256)"
if ($SigningCertificateThumbprint) {
    # Inno replaces $f with its target filename. No password/private key in arguments.
    $signCommand = '"' + $SignToolPath + '" sign /sha1 ' + $SigningCertificateThumbprint + ' /s My /fd SHA256 /tr https://timestamp.digicert.com /td SHA256 $f'
    $compilerArgs += '/SWinSideUSB=' + $signCommand
    $compilerArgs += '/DSignCommand='
}
$compilerArgs += Join-Path $repoRoot 'installer\WinSideUSB.iss'
& $CompilerPath @compilerArgs
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compile failed (exit $LASTEXITCODE). Staging retained at $payloadDir" }
$suffix = if ($DriverMode -eq 'Development') { '-Development' } else { '' }
$setupPath = Join-Path $outputRoot "WinSideUSB-$Version$suffix-Setup.exe"
if ($SigningCertificateThumbprint -and (Get-AuthenticodeSignature -LiteralPath $setupPath).Status -ne 'Valid') {
    throw 'Built setup did not pass trusted signature validation.'
}
$hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
"$hash  $([IO.Path]::GetFileName($setupPath))" | Set-Content -LiteralPath "$setupPath.sha256" -Encoding ASCII
Copy-Item -LiteralPath (Join-Path $payloadDir 'payload-manifest.json') -Destination "$setupPath.manifest.json" -Force
Write-Host "Created $setupPath"
Write-Host "SHA256 $hash"
if ($DriverMode -eq 'Development') { Write-Warning 'Development setup: test-signed driver. Requires prepared Windows test mode; not a consumer release.' }
