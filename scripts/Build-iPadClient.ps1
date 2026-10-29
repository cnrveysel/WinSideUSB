param(
    [string]$Distribution = 'Ubuntu-24.04',
    [string]$User = 'veysel',
    [string]$LinuxProjectPath = '/home/veysel/projects/WinSideUSBClient',
    [switch]$Sign,
    [switch]$Ipa
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Sync-iPadClient.ps1')
$project = Join-Path $repo 'iPadClient'
$linuxSource = & wsl.exe -d $Distribution --user $User --exec wslpath -a -u $project
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the iPad project in WSL.' }

# Arguments stay separate from shell source, including project paths with spaces.
$build = @'
set -euo pipefail
source_dir="$1"
project_dir="$2"
mkdir -p "$project_dir/Sources/WinSideUSBClient"
cp "$source_dir/Package.swift" "$source_dir/xtool.yml" "$source_dir/Info.plist" "$project_dir/"
cp "$source_dir/Sources/WinSideUSBClient/App.swift" "$project_dir/Sources/WinSideUSBClient/App.swift"
cd "$project_dir"
flags=(--configuration release)
if [ "$3" = 1 ]; then flags+=(--sign); fi
if [ "$4" = 1 ]; then flags+=(--ipa); fi
xtool dev build "${flags[@]}"
if [ "$4" = 1 ]; then
    mkdir -p "$source_dir/artifacts"
    cp xtool/WinSideUSBClient.ipa "$source_dir/artifacts/WinSideUSBClient-recovery.ipa"
fi
'@
$signFlag = if ($Sign) { '1' } else { '0' }
$ipaFlag = if ($Ipa) { '1' } else { '0' }
& wsl.exe -d $Distribution --user $User --exec bash -lc $build ipad-build $linuxSource.Trim() $LinuxProjectPath $signFlag $ipaFlag
if ($LASTEXITCODE -ne 0) { throw "iPad release build failed (exit $LASTEXITCODE)." }
if ($Ipa) {
    Write-Host "Package: $(Join-Path $project 'artifacts\WinSideUSBClient-recovery.ipa')"
}
