param(
    [string]$Distribution = 'Ubuntu-24.04',
    [string]$User = 'veysel'
)

$ErrorActionPreference = 'Stop'
$runner = (Resolve-Path (Join-Path $PSScriptRoot 'run_ipad_transport_tests.py')).Path

# Keep the test process unprivileged. No device, driver, or installed app changes.
$runnerForWsl = $runner.Replace('\', '/')
$linuxPath = & wsl.exe -d $Distribution --user $User --exec wslpath -a -u $runnerForWsl
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the test runner in WSL.' }

# Login shell loads the existing Swift installation. Pass the file path as an
# argument instead of interpolating it into shell source.
& wsl.exe -d $Distribution --user $User --exec bash -lc 'python3 "$1"' ipad-transport-tests $linuxPath.Trim()
if ($LASTEXITCODE -ne 0) { throw "iPad transport tests failed (exit $LASTEXITCODE)." }
