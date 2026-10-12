[CmdletBinding()]
param([string]$OutputDir)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot '.codex\vendor\VirtualDisplayDriver' }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$cacheRoot = Join-Path $repoRoot '.codex\vendor-downloads'
$scratch = Join-Path $cacheRoot ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch -Force
$archive = Join-Path $scratch 'VirtualDisplayDriver-25.7.23.zip'
$url = 'https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip'
$expectedZip = 'E24210692B442B39AF763536330CE78B423F19342B7A7792C26DE3944E418B3A'
# Despite the upstream asset name, the pinned DLL is AMD64 (x64).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedZip) { throw 'The upstream archive differs from the reviewed release. No driver was copied.' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($name in @('MttVDD.inf', 'MttVDD.dll', 'mttvdd.cat')) {
        $entries = @($zip.Entries | Where-Object { $_.Name -eq $name })
        if ($entries.Count -ne 1) { throw "Expected one upstream $name in the archive." }
        # Extract only named payloads to fixed destinations; ignore archive paths.
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], (Join-Path $scratch $name), $false)
    }
} finally { $zip.Dispose() }
Import-Module (Join-Path $PSScriptRoot 'Setup-DriverSupport.psm1') -Force
$null = Test-SetupPackage -PackageDir $scratch -DriverMode Signed -SkipMachineChecks
$null = New-Item -ItemType Directory -Path $OutputDir -Force
foreach ($name in @('MttVDD.inf', 'MttVDD.dll', 'mttvdd.cat')) {
    Copy-Item -LiteralPath (Join-Path $scratch $name) -Destination (Join-Path $OutputDir $name) -Force
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'licenses\Virtual-Display-Driver-MIT.txt') -Destination (Join-Path $OutputDir 'LICENSE.txt') -Force
Write-Host 'Verified original Virtual Display Driver 25.7.23 x64 signatures, catalog and hashes.'
Write-Output $OutputDir
