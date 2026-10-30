# Real installer lifecycle test. Run only inside an explicitly marked disposable VM.
[CmdletBinding()]
param([string]$TestRoot = 'C:\WSTest')
$ErrorActionPreference = 'Stop'
$computer = Get-CimInstance Win32_ComputerSystem
$markerPath = Join-Path $TestRoot 'vm-marker.json'
$virtual = $computer.Manufacturer -match 'QEMU|VMware|innotek|Xen' -or $computer.Model -match 'Virtual Machine|VirtualBox'
if ($env:COMPUTERNAME -notlike 'WSUSBE2E*' -or -not $virtual -or -not (Test-Path -LiteralPath $markerPath)) {
    throw 'Refusing to change this machine: the lifecycle test requires the explicitly marked disposable VM.'
}
$config = Get-Content -LiteralPath (Join-Path $TestRoot 'lifecycle-config.json') -Raw | ConvertFrom-Json
$resultRoot = Join-Path $TestRoot 'results'
New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
$phasePath = Join-Path $resultRoot 'lifecycle-phase.json'
$phase = if (Test-Path $phasePath) { (Get-Content $phasePath -Raw | ConvertFrom-Json).Phase } else { 'first-install' }
$appDir = Join-Path $env:ProgramFiles 'WinSideUSB'
$appPath = Join-Path $appDir 'WinSideUSB.exe'
$statePath = Join-Path $env:ProgramData 'WinSideUSB\setup-state.json'
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{B1638B2B-88F8-40A2-B7C0-B75F2EE9BA5F}_is1'
$server = [string]$config.ReportUri

function Send-File([string]$Path, [string]$Name) {
    if (-not $server) { return }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $data = @{name=$Name; data=[Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))} | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "$server/file" -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($data)) -TimeoutSec 30 | Out-Null
    }
}
function Event([string]$Name, $Details) {
    $value = @{time=[DateTime]::UtcNow.ToString('o');version=$config.Version;phase=$phase;name=$Name;details=$Details}
    $json = $value | ConvertTo-Json -Depth 10 -Compress
    Add-Content -LiteralPath (Join-Path $resultRoot 'lifecycle-events.jsonl') -Value $json -Encoding UTF8
    if ($server) {
        Invoke-RestMethod -Method Post -Uri "$server/event" -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 15 | Out-Null
    }
    Write-Output "$phase : $Name"
}
function Set-Phase([string]$Next) {
    @{Phase=$Next} | ConvertTo-Json | Set-Content -LiteralPath $phasePath -Encoding UTF8
    $script:phase=$Next
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reboot-Test([string]$Next) {
    Set-Phase $Next
    Event 'reboot-requested' @{next=$Next}
    & shutdown.exe /r /t 3 /f
    Start-Sleep -Seconds 30
    throw 'The requested VM restart did not occur.'
}
function Installer([string]$Name) {
    $setupPath = Join-Path $TestRoot "WinSideUSB-$($config.Version)-Setup.exe"
    if (-not (Test-Path -LiteralPath $setupPath)) {
        Event 'download-setup' @{url=$config.Url}
        $ProgressPreference='SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $config.Url -OutFile $setupPath -TimeoutSec 300
    }
    Assert ((Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash -eq $config.SHA256) 'The downloaded setup hash differs from the tested public release.'
    $log = Join-Path $resultRoot "$Name-inno.log"
    Event 'installer-start' @{name=$Name;sha256=$config.SHA256}
    $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/RESTARTEXITCODE=3010','/SP-','/LANG=english','/TASKS=desktopicon,appleusb,media',('/LOG="'+$log+'"'))
    if ($config.TrustDriverPublisher) { $arguments += '/TRUSTDISPLAYPUBLISHER=1' }
    $process = Start-Process -FilePath $setupPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(900000)) { throw 'The installer exceeded its 15 minute test timeout.' }
    $code=$process.ExitCode
    $script:LastInstallerExitCode=$code
    Send-File $log "$Name-inno.log"
    Event 'installer-exit' @{name=$Name;exitCode=$code}
    Assert ($code -in @(0,3010)) "The real installer failed with exit $code."
    return $code
}
function Installed([string]$Name) {
    Assert (Test-Path -LiteralPath $appPath) 'The app executable is missing.'
    Assert (Test-Path -LiteralPath $uninstallKey) 'Installed apps registration is missing.'
    Assert ((Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -eq $config.Version) 'Installed version differs.'
    $service=Get-CimInstance Win32_Service -Filter "Name='WinSideUSBDisplayService'"
    Assert ($service -and $service.State -eq 'Running' -and $service.StartMode -eq 'Auto' -and $service.StartName -eq 'LocalSystem') 'The display service is not running automatically as LocalSystem.'
    $apple=Get-Service 'Apple Mobile Device Service' -ErrorAction Stop
    Assert ($apple.Status -eq 'Running') 'Apple USB support is not running.'
    $runtime=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    Assert ($runtime.Installed -eq 1 -and [version]$runtime.Version.TrimStart('v') -ge [version]'14.44.35211.0') 'The required Visual C++ runtime is missing.'
    Assert (Test-Path "$env:windir\System32\MFPlat.dll") 'Media Foundation is missing.'
    Assert (-not (Test-Path "$env:ProgramFiles\iTunes\iTunes.exe")) 'The setup installed the unrelated iTunes app.'
    Assert (Test-Path "$env:PUBLIC\Desktop\WinSideUSB.lnk") 'The desktop shortcut is missing.'
    $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert ($state.Installed -and @($state.DeviceIds).Count -eq 1 -and @($state.Packages).Count -eq 1) 'Owned device/package state is incomplete or duplicated.'
    if ($config.TrustDriverPublisher) {
        $publisher = '3CF8CF26D8BA266C3A483AB7D26D4A818E317D76'
        Assert (Test-Path "Cert:\LocalMachine\TrustedPublisher\$publisher") 'The explicitly selected publisher trust is absent.'
        Assert (@($state.Certificates | Where-Object { $_.Store -eq 'TrustedPublisher' -and $_.Thumbprint -eq $publisher }).Count -eq 1) 'Publisher trust ownership is missing or duplicated.'
        Assert (-not (Test-Path "Cert:\LocalMachine\Root\$publisher")) 'The publisher leaf was incorrectly installed as a root.'
    }
    $devices=@(Get-PnpDevice -PresentOnly -Class Display)
    $owned=@($devices | Where-Object {$_.InstanceId -in $state.DeviceIds})
    Assert ($owned.Count -eq 1) 'The owned display node is absent or duplicated.'
    $properties=Get-PnpDeviceProperty -InstanceId $state.DeviceIds[0] -KeyName DEVPKEY_Device_ProblemCode
    Assert ([int]$properties.Data -eq 22) 'The virtual display must remain disabled at idle.'
    $record=@{name=$Name;devices=$owned | Select-Object InstanceId,FriendlyName,Status;problemCode=[int]$properties.Data;service=$service | Select-Object Name,State,StartMode,StartName;apple=[string]$apple.Status;runtime=$runtime.Version;state=$state}
    $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $resultRoot "$Name-installed.json") -Encoding UTF8
    Send-File (Join-Path $resultRoot "$Name-installed.json") "$Name-installed.json"
    Event 'installed-verified' @{name=$Name;device=$state.DeviceIds[0];publishedInf=$state.Packages[0].PublishedInf}
    return $state
}
function Launch-App([string]$Name) {
    $action=New-ScheduledTaskAction -Execute $appPath
    $principal=New-ScheduledTaskPrincipal -UserId 'WSTester' -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'WinSideUSB test user launch' -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName 'WinSideUSB test user launch'
    Start-Sleep -Seconds 15
    $process=Get-Process -Name WinSideUSB -ErrorAction SilentlyContinue
    Assert ($process -and -not $process.HasExited -and $process.MainWindowHandle -ne 0) 'WinSideUSB did not remain open with a native window.'
    if (-not ('WinSideUSB.TestToken' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace WinSideUSB {
    public static class TestToken {
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint rights, bool inherit, int pid);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint rights, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int type, out uint value, uint size, out uint returned);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public static bool Elevated(int pid) {
            IntPtr process=OpenProcess(0x1000, false, pid), token=IntPtr.Zero;
            if(process==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                if(!OpenProcessToken(process,8,out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint value, returned;
                if(!GetTokenInformation(token,20,out value,4,out returned)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return value!=0;
            } finally { if(token!=IntPtr.Zero)CloseHandle(token); CloseHandle(process); }
        }
    }
}
'@
    }
    $elevated=[WinSideUSB.TestToken]::Elevated($process.Id)
    Event 'user-app-running' @{name=$Name;pid=$process.Id;title=$process.MainWindowTitle;responding=$process.Responding;session=$process.SessionId;elevated=$elevated}
    Assert (-not $elevated) 'The Windows app unexpectedly requires an elevated token.'
    Assert $process.Responding 'The app is not responding.'
    Start-Sleep -Seconds 10
}
function Uninstall([string]$Name) {
    $owned=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $owned | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $resultRoot 'before-uninstall.json') -Encoding UTF8
    $uninstaller=Join-Path $appDir 'unins000.exe'
    $log=Join-Path $resultRoot "$Name-uninstall.log"
    Event 'uninstaller-start' @{name=$Name;appWasRunning=[bool](Get-Process WinSideUSB -ErrorAction SilentlyContinue)}
    $process=Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="'+$log+'"')) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(300000)) { throw 'Uninstall exceeded its five minute timeout.' }
    Send-File $log "$Name-uninstall.log"
    Event 'uninstaller-exit' @{name=$Name;exitCode=$process.ExitCode}
    $script:LastUninstallExitCode=$process.ExitCode
    if ($process.ExitCode -notin @(0,3010)) {
        $remainingState=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Assert ($remainingState.PendingRestart -or $remainingState.PendingRemovalBootId) 'Uninstall failed without a genuine recorded restart requirement.'
    }
    return $process.ExitCode
}
function Removed([string]$Name) {
    Assert (-not (Get-Process WinSideUSB -ErrorAction SilentlyContinue)) 'The app process survived uninstall.'
    Assert (-not (Get-Service WinSideUSBDisplayService -ErrorAction SilentlyContinue)) 'The display service survived uninstall.'
    Assert (-not (Test-Path $uninstallKey)) 'Installed apps registration survived uninstall.'
    Assert (-not (Test-Path $appPath)) 'The app executable survived uninstall.'
    Assert (-not (Test-Path $appDir)) 'The installed application directory survived uninstall.'
    Assert (-not (Test-Path "$env:PUBLIC\Desktop\WinSideUSB.lnk")) 'The desktop shortcut survived uninstall.'
    Assert (-not (Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\WinSideUSB")) 'The Start menu group survived uninstall.'
    $owned=Get-Content -LiteralPath (Join-Path $resultRoot 'before-uninstall.json') -Raw | ConvertFrom-Json
    $present=@(Get-PnpDevice -Class Display -PresentOnly)
    Assert (@($present | Where-Object {$_.InstanceId -in $owned.DeviceIds}).Count -eq 0) 'An owned display device survived uninstall.'
    foreach ($package in $owned.Packages) { Assert (-not (Test-Path (Join-Path "$env:windir\INF" $package.PublishedInf))) 'The owned Driver Store INF survived uninstall.' }
    $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert (-not $state.Installed -and @($state.DeviceIds).Count -eq 0 -and @($state.Packages).Count -eq 0) 'Cleanup ownership state is incomplete.'
    foreach ($certificate in $owned.Certificates) {
        Assert (-not (Test-Path ("Cert:\LocalMachine\{0}\{1}" -f $certificate.Store,$certificate.Thumbprint))) 'An exclusively owned publisher certificate survived uninstall.'
    }
    Assert (@($state.Certificates).Count -eq 0) 'Certificate cleanup ownership state is incomplete.'
    Assert ((Get-Service 'Apple Mobile Device Service').Status -eq 'Running') 'Uninstall removed or stopped shared Apple support.'
    Assert ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64').Installed -eq 1) 'Uninstall removed the shared runtime.'
    Event 'uninstall-verified' @{name=$Name;sharedApplePreserved=$true;sharedRuntimePreserved=$true}
}
function Collect-Logs {
    Get-ChildItem (Join-Path $env:ProgramData 'WinSideUSB') -File -ErrorAction SilentlyContinue | Where-Object {$_.Extension -in '.log','.json','.txt'} | ForEach-Object { Send-File $_.FullName ('driver-'+$_.Name) }
    $diag=Join-Path $env:LOCALAPPDATA 'WinSideUSB\winsideusb_diag.log'
    Send-File $diag 'app-diagnostic.log'
    Send-File (Join-Path $resultRoot 'lifecycle-events.jsonl') 'lifecycle-events.jsonl'
}
try {
    Event 'phase-start' @{}
    switch ($phase) {
        'first-install' {
            Assert (-not (Test-Path $appPath)) 'The initial VM already has the app.'
            Assert (-not (Get-Service 'Apple Mobile Device Service' -ErrorAction SilentlyContinue)) 'The initial VM already has Apple USB support.'
            $null=Installer 'first'
            if ($script:LastInstallerExitCode -eq 0) { $null=Installed 'first-before-reboot' }
            Collect-Logs
            Reboot-Test 'after-first-reboot'
        }
        'after-first-reboot' {
            $null=Installed 'first-after-reboot'
            Launch-App 'first'
            $null=Uninstall 'first'
            Collect-Logs
            Reboot-Test 'after-first-uninstall-reboot'
        }
        'after-first-uninstall-reboot' {
            if (Test-Path $appPath) { $null=Uninstall 'first-retry-after-reboot' }
            Removed 'first'
            $null=Installer 'reinstall'
            Collect-Logs
            Reboot-Test 'after-reinstall-reboot'
        }
        'after-reinstall-reboot' {
            $null=Installed 'reinstall'
            Launch-App 'reinstall'
            $null=Installer 'same-version-upgrade'
            Collect-Logs
            Reboot-Test 'after-upgrade-reboot'
        }
        'after-upgrade-reboot' {
            $null=Installed 'same-version-upgrade'
            Launch-App 'after-upgrade'
            $null=Uninstall 'final'
            Collect-Logs
            Reboot-Test 'after-final-uninstall-reboot'
        }
        'after-final-uninstall-reboot' {
            if (Test-Path $appPath) { $null=Uninstall 'final-retry-after-reboot' }
            Removed 'final'
            Collect-Logs
            Set-Phase 'complete'
            @{passed=$true;version=$config.Version;sha256=$config.SHA256;completedUtc=[DateTime]::UtcNow.ToString('o');os=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber);secureBoot=(Confirm-SecureBootUEFI)} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $resultRoot 'lifecycle-result.json') -Encoding UTF8
            Send-File (Join-Path $resultRoot 'lifecycle-result.json') 'lifecycle-result.json'
            Event 'lifecycle-passed' @{}
        }
        'complete' { Write-Output 'The lifecycle test already completed.' }
        default { throw "Unknown lifecycle phase: $phase" }
    }
} catch {
    Event 'lifecycle-failed' @{message=$_.Exception.Message;stack=$_.ScriptStackTrace}
    Collect-Logs
    throw
}
