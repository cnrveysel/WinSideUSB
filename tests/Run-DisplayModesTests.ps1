[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repo '.codex\display-mode-tests'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Visual Studio C++ build tools are required.' }
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
$environment = & $env:ComSpec /d /c ('call "' + $vcvars + '" >nul && set')
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the C++ compiler environment.' }
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process') }
}
$executable = Join-Path $output 'DisplayModes.Tests.exe'
$object = Join-Path $output 'DisplayModes.Tests.obj'
& cl.exe /nologo /std:c++17 /EHsc /W4 /WX "/Fo$object" "/Fe$executable" (Join-Path $PSScriptRoot 'DisplayModes.Tests.cpp') /link /INCREMENTAL:NO
if ($LASTEXITCODE -ne 0) { throw 'Display mode tests did not compile.' }
& $executable
if ($LASTEXITCODE -ne 0) { throw 'Display mode tests failed.' }
& (Join-Path $PSScriptRoot 'Test-DisplayProfilesConfiguration.ps1') -ModeProbePath $executable
