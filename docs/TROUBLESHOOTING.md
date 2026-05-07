# Troubleshooting

## iPad shows "PC bekleniyor"

First check whether Windows received the iPad handshake:

```powershell
Get-Content "$env:LOCALAPPDATA\WinSideUSB\winsideusb_diag.log" -Tail 80
```

If you see:

```text
iPad READY received
selected iPad device port 17326
```

then the USB tunnel and iPad listener are working. Look at the IDD driver state next.

If you do not see `READY2`, check:

```powershell
Get-Content "$env:LOCALAPPDATA\WinSideUSB\iproxy.log" -Tail 80
```

Common causes:

- iPad app is not running the latest `swiftclientcode.swift`.
- Swift Playgrounds has an old run holding the port.
- iPad did not trust the Windows computer.
- `iproxy.exe` or libimobiledevice DLLs are missing from the embedded resources or runtime folder.

## iPad reports "Portlar dolu: 48"

Darwin error `48` is `EADDRINUSE`.

The iPad has a stale listener holding all fallback ports. Fully close Swift Playgrounds from the app switcher and run it again.

The current iPad client tries:

```text
17326, 17325, 17324, 17323, 17322, 17321
```

## Windows connects then immediately disconnects

Open:

```powershell
Get-Content "$env:LOCALAPPDATA\WinSideUSB\winsideusb_diag.log" -Tail 120
```

If the log shows `iPad READY received` and then cleanup without new TX CSV logs, the app likely failed before capture started. Check the virtual display driver:

```powershell
pnputil /enum-devices /class Display /drivers
```

Expected:

```text
WinSideUSB Virtual Display
Status: Started
```

If it shows `Problem Code: 43`, reinstall the development driver:

```powershell
cd C:\Path\To\WinSideUSB
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-DevDriver.ps1
```

## Code 43 on WinSideUSB Virtual Display

`Code 43` means the UMDF driver crashed or failed post-start. The usual recovery is:

1. Stop `WinSideUSB.exe`.
2. Rebuild `IddSampleDriver.sln`.
3. Run `scripts/Install-DevDriver.ps1` from elevated PowerShell.
4. Reboot if Windows refuses to restart the device.

Relevant logs:

```powershell
Get-WinEvent -LogName System -MaxEvents 120 |
  Where-Object { $_.Message -match 'WinSideUSB|WUDF|IddSample|Display' } |
  Format-List TimeCreated,ProviderName,Id,Message
```

Crash dumps:

```text
C:\ProgramData\Microsoft\WDF\
C:\ProgramData\Microsoft\Windows\WER\
```

## Build fails because iproxy or DLLs are missing

The app resource file embeds libimobiledevice tools from:

```text
x64/Release/
```

The file names are listed in:

```text
WinSideUSB/WinSideUSB.rc
```

Place those binaries before building `WinSideUSB.sln`, or adjust the resource file for your local packaging strategy.

## No telemetry CSV appears

The app creates `winsideusb_tx_*.csv` only after capture/encode initialization reaches the telemetry stage.

If no new CSV appears after Start:

- iPad handshake may have failed.
- virtual display driver may be `Code 43`.
- Desktop Duplication may not have initialized.
- encoder initialization may have failed before streaming.

Start with `winsideusb_diag.log`.

## Useful One-Liners

Check iPad device visibility:

```powershell
& "$env:LOCALAPPDATA\WinSideUSB\tools\ideviceinfo.exe" -k ProductType
```

Check app and tunnel processes:

```powershell
Get-Process WinSideUSB,iproxy -ErrorAction SilentlyContinue
```

Check local tunnel socket:

```powershell
Get-NetTCPConnection -LocalPort 8081 -ErrorAction SilentlyContinue
```
