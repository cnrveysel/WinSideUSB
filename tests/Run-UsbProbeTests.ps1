[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repo '.codex\usb-probe-tests'
$null = New-Item -ItemType Directory -Path $output -Force
$vswhere = Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Visual Studio C++ build tools are required.' }
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
$environment = & $env:ComSpec /d /c ('call "' + $vcvars + '" >nul && set')
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize C++ build environment.' }
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
}
$compiler = (Get-Command cl.exe -ErrorAction Stop).Source
$source = Get-Content -LiteralPath (Join-Path $repo 'WinSideUSB\WinSideUSB.cpp') -Raw
$start = $source.IndexOf('static bool ValidDeviceUdid(')
$end = $source.IndexOf('static std::wstring g_detectedName;', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Actual USB probe implementation could not be extracted.' }
[IO.File]::WriteAllText((Join-Path $output 'UsbProbe.implementation.h'), $source.Substring($start, $end - $start), (New-Object Text.UTF8Encoding($false)))
foreach ($build in @(@('UsbProbe.FakeTool.cpp', 'ideviceinfo.exe'), @('UsbProbe.Tests.cpp', 'UsbProbe.Tests.exe'))) {
    & $compiler /nologo /std:c++17 /EHsc /W4 /WX /utf-8 "/I$output" "/Fo$(Join-Path $output ($build[0] + '.obj'))" "/Fe$(Join-Path $output $build[1])" (Join-Path $PSScriptRoot $build[0]) /link /INCREMENTAL:NO
    if ($LASTEXITCODE -ne 0) { throw 'USB probe regression tests did not compile.' }
}
& (Join-Path $output 'UsbProbe.Tests.exe') $output
if ($LASTEXITCODE -ne 0) { throw 'USB probe regression tests failed.' }
