[CmdletBinding()]
param([string]$CompilerPath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repo '.codex\frame-pacing-tests'
New-Item -ItemType Directory -Path $output -Force | Out-Null
if (-not $CompilerPath) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio C++ build tools are required.' }
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installation) { throw 'Visual Studio C++ build tools are required.' }
    $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
    # Read the developer environment without modifying persistent machine settings.
    $environment = & $env:ComSpec /d /c ('call "' + $vcvars + '" >nul && set')
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the C++ build environment.' }
    foreach ($line in $environment) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    $CompilerPath = (Get-Command cl.exe -ErrorAction Stop).Source
}
$source = Join-Path $PSScriptRoot 'FramePacing.Tests.cpp'
$executable = Join-Path $output 'FramePacing.Tests.exe'
$object = Join-Path $output 'FramePacing.Tests.obj'
& $CompilerPath /nologo /std:c++17 /EHsc /W4 /WX /DUNICODE /D_UNICODE "/Fo$object" "/Fe$executable" $source /link /INCREMENTAL:NO
if ($LASTEXITCODE -ne 0) { throw 'Frame pacing tests did not compile.' }
& $executable
if ($LASTEXITCODE -ne 0) { throw 'Frame pacing tests failed.' }
