# Virtual Display Driver

WinSideUSB uses a Windows Indirect Display Driver (IDD) to create a virtual monitor only while streaming.

The app controls the driver through a custom device interface and three IOCTLs:

```text
IOCTL_IDD_SET_RESOLUTION
IOCTL_IDD_CONNECT_MONITOR
IOCTL_IDD_DISCONNECT_MONITOR
```

## Build Output

The release driver package is generated here:

```text
x64/Release/IddSampleDriver/
```

Important files:

```text
IddSampleDriver.inf
IddSampleDriver.dll
iddsampledriver.cat
```

The development certificate is exported to:

```text
x64/Release/IddSampleDriver.cer
```

Do not commit these generated files to source control.

## Test-Signed Development Install

Local development uses a test-signed driver. On most machines this requires:

1. Disable Secure Boot in BIOS/UEFI.
2. Enable test signing:

```powershell
bcdedit /set testsigning on
```

3. Reboot.
4. Install from an elevated PowerShell:

```powershell
cd C:\Path\To\WinSideUSB
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-DevDriver.ps1
```

The helper script:

- stops `WinSideUSB.exe` and `iproxy.exe`
- adds the test certificate to `Root` and `TrustedPublisher`
- installs the generated driver package
- restarts, disables, and re-enables the device when possible
- prints the display driver state at the end

## Manual Install

If the helper script cannot find the root-enumerated device, install it with DevCon:

```powershell
& "C:\Program Files (x86)\Windows Kits\10\Tools\10.0.26100.0\x64\devcon.exe" install "x64\Release\IddSampleDriver\IddSampleDriver.inf" "Root\IddSampleDriver"
```

Check state:

```powershell
pnputil /enum-devices /class Display /drivers
```

Expected:

```text
Device Description: WinSideUSB Virtual Display
Status: Started
Driver Status: Best Ranked / Installed
```

## Important Lifecycle Detail

After `IddCxMonitorDeparture`, the monitor handle should not be reused. WinSideUSB creates a fresh monitor on the next connect. Reusing a stale monitor handle can crash `WUDFHost.exe` inside `IddCxMonitorArrival` and put the device into `Code 43`.

The current driver also reports a single EDID monitor mode from the monitor descriptor to avoid invalid or duplicate mode entries during IDD startup.

## Recovering From Code 43

If the device shows:

```text
Status: Problem
Problem Code: 43 (0x2B) [CM_PROB_FAILED_POST_START]
```

then Windows has marked the UMDF driver as failed. Install the latest driver build again from an elevated PowerShell:

```powershell
cd C:\Path\To\WinSideUSB
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-DevDriver.ps1
```

If Windows refuses to restart the device with access denied, reboot and run the script again.

Useful event logs:

```powershell
Get-WinEvent -LogName System -MaxEvents 100 |
  Where-Object { $_.Message -match 'WinSideUSB|WUDF|IddSample' } |
  Format-List TimeCreated,ProviderName,Id,Message
```

Crash dumps may appear under:

```text
C:\ProgramData\Microsoft\WDF\
C:\ProgramData\Microsoft\Windows\WER\
```

## Public Distribution

Test signing is not acceptable for normal users. Public releases need Microsoft driver signing through the normal Windows driver signing flow. Until that is done, describe the driver as development-only.
