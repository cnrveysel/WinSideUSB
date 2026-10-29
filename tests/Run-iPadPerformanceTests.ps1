param(
    [string]$Distribution = 'Ubuntu-24.04',
    [string]$User = 'veysel'
)

$ErrorActionPreference = 'Stop'
$runner = (Resolve-Path (Join-Path $PSScriptRoot 'run_ipad_performance_tests.py')).Path
$linuxPath = & wsl.exe -d $Distribution --user $User --exec wslpath -a -u $runner.Replace('\', '/')
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the performance test runner.' }

# One compiler job, low CPU/I/O priority; no real device or display access.
& wsl.exe -d $Distribution --user $User --exec bash -lc 'nice -n 15 ionice -c 3 python3 "$1"' ipad-performance-tests $linuxPath.Trim()
if ($LASTEXITCODE -ne 0) { throw "iPad performance checks failed (exit $LASTEXITCODE)." }
