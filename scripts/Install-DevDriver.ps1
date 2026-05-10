param(
    [string]$InstanceId = ""
)

$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$packageDir = Join-Path $repoRoot "x64\Release\IddSampleDriver"
$inf = Join-Path $packageDir "IddSampleDriver.inf"
$cert = Join-Path $repoRoot "x64\Release\IddSampleDriver.cer"

function New-WinSideUsbRootDevice([string]$InfPath) {
    if (-not ([System.Management.Automation.PSTypeName]'WinSideUsbRootDeviceInstaller').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class WinSideUsbRootDeviceInstaller
{
    private const int DICD_GENERATE_ID = 0x00000001;
    private const int SPDRP_HARDWAREID = 0x00000001;
    private const int DIF_REGISTERDEVICE = 0x00000019;
    private const int INSTALLFLAG_FORCE = 0x00000001;
    private const int INSTALLFLAG_NONINTERACTIVE = 0x00000004;

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public int cbSize;
        public Guid ClassGuid;
        public int DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiCreateDeviceInfo(
        IntPtr DeviceInfoSet,
        string DeviceName,
        ref Guid ClassGuid,
        string DeviceDescription,
        IntPtr hwndParent,
        int CreationFlags,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiSetDeviceRegistryProperty(
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData,
        int Property,
        byte[] PropertyBuffer,
        int PropertyBufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiCallClassInstaller(
        int InstallFunction,
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool UpdateDriverForPlugAndPlayDevices(
        IntPtr hwndParent,
        string HardwareId,
        string FullInfPath,
        int InstallFlags,
        out bool bRebootRequired);

    public static bool Install(string infPath)
    {
        string hardwareId = "Root\\IddSampleDriver";
        Guid displayClass = new Guid("4d36e968-e325-11ce-bfc1-08002be10318");
        IntPtr infoSet = SetupDiCreateDeviceInfoList(ref displayClass, IntPtr.Zero);
        if (infoSet == new IntPtr(-1)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList failed");
        }

        try {
            SP_DEVINFO_DATA data = new SP_DEVINFO_DATA();
            data.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));

            if (!SetupDiCreateDeviceInfo(
                    infoSet,
                    "WinSideUSBVirtualDisplay",
                    ref displayClass,
                    "WinSideUSB Virtual Display",
                    IntPtr.Zero,
                    DICD_GENERATE_ID,
                    ref data)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfo failed");
            }

            byte[] hardwareIdBytes = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(
                    infoSet,
                    ref data,
                    SPDRP_HARDWAREID,
                    hardwareIdBytes,
                    hardwareIdBytes.Length)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiSetDeviceRegistryProperty(SPDRP_HARDWAREID) failed");
            }

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, infoSet, ref data)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCallClassInstaller(DIF_REGISTERDEVICE) failed");
            }
        }
        finally {
            SetupDiDestroyDeviceInfoList(infoSet);
        }

        bool rebootRequired;
        if (!UpdateDriverForPlugAndPlayDevices(
                IntPtr.Zero,
                hardwareId,
                infPath,
                INSTALLFLAG_FORCE | INSTALLFLAG_NONINTERACTIVE,
                out rebootRequired)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateDriverForPlugAndPlayDevices failed");
        }

        return rebootRequired;
    }
}
"@
    }

    [WinSideUsbRootDeviceInstaller]::Install($InfPath)
}

if (-not (Test-Path $inf)) {
    throw "Driver package not found: $inf"
}

Get-Process WinSideUSB, iproxy -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path $cert) {
    certutil -addstore -f Root $cert | Out-Host
    certutil -addstore -f TrustedPublisher $cert | Out-Host
}

pnputil /add-driver $inf /install | Out-Host

if (-not $InstanceId) {
    $device = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq "WinSideUSB Virtual Display" } |
        Select-Object -First 1

    if ($device) {
        $InstanceId = $device.InstanceId
    }
}

if ($InstanceId) {
    pnputil /restart-device $InstanceId | Out-Host
    Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction SilentlyContinue
}
else {
    Write-Host "WinSideUSB root display device was not found. Creating it with SetupAPI..."
    try {
        $rebootRequired = New-WinSideUsbRootDevice $inf
        if ($rebootRequired) {
            Write-Warning "Windows reported that a reboot is required to finish driver installation."
        }
        Start-Sleep -Seconds 1

        $device = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -eq "WinSideUSB Virtual Display" } |
            Select-Object -First 1

        if ($device) {
            $InstanceId = $device.InstanceId
            pnputil /restart-device $InstanceId | Out-Host
        }
    }
    catch {
        Write-Warning "SetupAPI root device creation failed: $($_.Exception.Message)"
    }

    if (-not $InstanceId) {
        $devcon = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Tools" -Recurse -Filter devcon.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\x64\\devcon\.exe$" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1

        if (-not $devcon) {
            throw "WinSideUSB root display device could not be created automatically and devcon.exe was not found. On development machines, install the WDK or create the device manually with: devcon.exe install `"$inf`" `"Root\IddSampleDriver`""
        }

        & $devcon.FullName install $inf "Root\IddSampleDriver" | Out-Host
    }
}

pnputil /enum-devices /class Display /drivers | Out-Host
