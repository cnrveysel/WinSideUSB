[CmdletBinding()]
param([string]$CompilerPath, [switch]$Hardware)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repo '.codex\desktop-cursor-tests'
New-Item -ItemType Directory -Path $output -Force | Out-Null
if (-not $CompilerPath) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio C++ build tools are required.' }
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installation) { throw 'Visual Studio C++ build tools are required.' }
    $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
    $environment = & $env:ComSpec /d /c ('call "' + $vcvars + '" >nul && set')
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the C++ build environment.' }
    foreach ($line in $environment) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    $CompilerPath = (Get-Command cl.exe -ErrorAction Stop).Source
}
$source = Join-Path $PSScriptRoot 'DesktopCursor.Tests.cpp'
$executable = Join-Path $output 'DesktopCursor.Tests.exe'
$object = Join-Path $output 'DesktopCursor.Tests.obj'
& $CompilerPath /nologo /std:c++17 /EHsc /W4 /WX /DUNICODE /D_UNICODE "/Fo$object" "/Fe$executable" $source /link /INCREMENTAL:NO
if ($LASTEXITCODE -ne 0) { throw 'Cursor compositor tests did not compile.' }
[string[]]$testArguments = if ($Hardware) { @('--hardware') } else { @() }
& $executable @testArguments
if ($LASTEXITCODE -ne 0) { throw 'Cursor compositor tests failed.' }
