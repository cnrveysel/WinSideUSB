[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ModeProbePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repo '.codex\display-profile-config-tests'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Import-Module (Join-Path $repo 'scripts\Setup-DriverSupport.psm1') -Force
$sourcePath = Join-Path $repo 'WinSideUSB\WinSideUSB.cpp'
$xmlPath = Join-Path $output 'vdd_settings.xml'
$count = New-SetupDisplayConfiguration $sourcePath $xmlPath
$xml = New-Object Xml.XmlDocument
$xml.Load($xmlPath)
$sizes = @($xml.vdd_settings.resolutions.resolution | ForEach-Object { "$($_.width),$($_.height)" })
if (($sizes | Select-Object -Unique).Count -ne $sizes.Count) { throw 'Duplicate packaged display dimensions.' }
if (($xml.vdd_settings.global.g_refresh_rate -join ',') -ne '60,120') { throw 'Refresh choices changed.' }
if ($xml.vdd_settings.options.CustomEdid -ne 'false') { throw 'A model-specific EDID became a global setup default.' }
$source = Get-Content -LiteralPath $sourcePath -Raw
$table = [regex]::Match($source, '(?s)static const iPadDef g_ipadDefs\[\] = \{(.*?)\r?\n\};')
if (-not $table.Success) { throw 'No iPad definitions found.' }
$inputs = @([regex]::Matches($table.Groups[1].Value, '(?m)^\s*\{\s*"iPad[^"]+",.*?,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}') | ForEach-Object {
    "$($_.Groups[1].Value) $($_.Groups[2].Value) $($_.Groups[3].Value)"
} | Select-Object -Unique)
if ($inputs.Count -lt 10) { throw 'Too few distinct model definitions were tested.' }
# Ask the actual C++ helper used by the UI, rather than duplicate its math here.
# File redirection preserves exact ASCII bytes on Windows PowerShell 5.1 too.
# Its native pipeline can otherwise depend on the hosted console's encoding.
$probeInput = Join-Path $output 'mode-input.txt'
[IO.File]::WriteAllText($probeInput, ($inputs -join "`n") + "`n", [Text.Encoding]::ASCII)
$probeCommand = '"' + (Resolve-Path -LiteralPath $ModeProbePath).Path + '" --list-modes < "' + $probeInput + '"'
$actualModes = @(& $env:ComSpec /d /s /c ('"' + $probeCommand + '"'))
if ($LASTEXITCODE -ne 0 -or -not $actualModes.Count) {
    throw "C++ display mode probe failed (exit $LASTEXITCODE, $($inputs.Count) inputs, $($actualModes.Count) outputs)."
}
foreach ($mode in $actualModes) {
    if ($mode -notmatch '^(\d+),(\d+),(60|120)$') { throw "Invalid C++ mode probe line: $mode" }
    if ($sizes -notcontains "$($matches[1]),$($matches[2])") { throw "UI mode missing from packaged driver XML: $mode" }
}
foreach ($expected in @('2732,2048,120', '2732,2048,60', '2048,1536,120', '1366,1024,120', '1366,1024,60')) {
    if ($actualModes -notcontains $expected) { throw "Missing required iPad Pro choice: $expected" }
}
foreach ($expected in @('2360,1640', '2048,1536', '1920,1080', '1024,768')) {
    if ($sizes -notcontains $expected) { throw "Unknown-device fallback missing: $expected" }
}
[pscustomobject]@{ Passed = $true; ModelVariants = $inputs.Count; GeneratedModeChecks = $actualModes.Count; PackagedResolutions = $count; LiveChanges = $false } | ConvertTo-Json
