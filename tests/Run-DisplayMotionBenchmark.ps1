[CmdletBinding()]
param(
    [ValidateRange(1, 120)][double]$Duration = 18,
    [switch]$BuildOnly,
    [string]$CompilerPath
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repo '.codex\motion-benchmark'
New-Item -ItemType Directory -Path $output -Force | Out-Null
if (-not $CompilerPath) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio C++ build tools are required.' }
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installation) { throw 'Visual Studio C++ build tools are required.' }
    $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
    # Initialize only this process; no persistent environment or device changes.
    $environment = & $env:ComSpec /d /c ('call "' + $vcvars + '" >nul && set')
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the C++ build environment.' }
    foreach ($line in $environment) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    $CompilerPath = (Get-Command cl.exe -ErrorAction Stop).Source
}
$source = Join-Path $PSScriptRoot 'DisplayMotion.Benchmark.cpp'
$executable = Join-Path $output 'DisplayMotion.Benchmark.exe'
$object = Join-Path $output 'DisplayMotion.Benchmark.obj'
& $CompilerPath /nologo /std:c++17 /EHsc /W4 /WX /O2 /DUNICODE /D_UNICODE "/Fo$object" "/Fe$executable" $source /link /INCREMENTAL:NO
if ($LASTEXITCODE -ne 0) { throw 'Motion benchmark did not compile.' }
if ($BuildOnly) {
    Write-Output $executable
    return
}
# Requires the app's existing display lease at 120 Hz. The executable emits JSON
# and never enables a device, changes a mode, or selects a physical fallback.
$seconds = $Duration.ToString([Globalization.CultureInfo]::InvariantCulture)
& $executable --duration $seconds
if ($LASTEXITCODE -ne 0) { throw "Motion benchmark exited with code $LASTEXITCODE." }
