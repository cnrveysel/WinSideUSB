[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Check', 'Install', 'Finalize', 'Uninstall')][string]$Action,
    [string]$PackageDir = '',
    [Parameter(Mandatory = $true)][string]$StatePath,
    [ValidateSet('Signed', 'Development', 'Release')][string]$DriverMode = 'Signed',
    [string]$CertificatePath = '',
    [string]$InstallDir = '',
    [string]$ServicePath = '',
    [switch]$TrustDriverPublisher,
    [switch]$NonInteractive
)

# Inno may inherit another PowerShell edition's PSModulePath. Prefer this
# Windows PowerShell process's built-in modules for Security, Storage and CIM.
$setupBuiltinModuleDir = Join-Path $PSHOME 'Modules'
$setupOtherModuleDirs = @($env:PSModulePath -split ';' | Where-Object { $_ -and $_ -ne $setupBuiltinModuleDir })
$env:PSModulePath = (@($setupBuiltinModuleDir) + $setupOtherModuleDirs) -join ';'

$ErrorActionPreference = 'Stop'
$exitCode = 1
$message = 'Driver setup failed before initialization.'
$logPath = ''
try {
    Import-Module (Join-Path $PSScriptRoot 'Setup-DriverSupport.psm1') -Force
    $StatePath = [IO.Path]::GetFullPath($StatePath)
    $logPath = Initialize-SetupLog $StatePath $Action
    $result = Invoke-SetupDriverAction $Action $PackageDir $StatePath $DriverMode $CertificatePath $InstallDir $ServicePath -TrustDriverPublisher:$TrustDriverPublisher -NonInteractive:$NonInteractive
    $exitCode = $result.ExitCode
    $message = $result.Message
} catch {
    $message = $_.Exception.Message
    Write-Host $message
    if ($logPath) {
        Add-Content -LiteralPath $logPath -Value $message -Encoding UTF8
        Add-Content -LiteralPath $logPath -Value $_.ScriptStackTrace -Encoding UTF8
        Add-Content -LiteralPath $logPath -Value $_.InvocationInfo.PositionMessage -Encoding UTF8
    }
}

try {
    if (-not $logPath) { throw 'Setup diagnostics could not be initialized safely; no result file was written.' }
    $directory = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [pscustomobject]@{
        Action = $Action; ExitCode = $exitCode; Success = ($exitCode -in @(0, 3010))
        RebootRequired = ($exitCode -eq 3010); Message = $message; LogPath = $logPath
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'setup-result.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $directory 'setup-result.txt') -Value $message -Encoding UTF8
} catch { Write-Host "Could not save setup result: $($_.Exception.Message)"; $exitCode = 1 }
exit $exitCode
