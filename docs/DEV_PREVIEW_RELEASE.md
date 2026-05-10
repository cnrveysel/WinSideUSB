# Developer Preview Release

WinSideUSB can be packaged as an experimental developer preview for people who explicitly want to test the current driver flow.

This is not a normal consumer installer. The driver is test-signed and may require Windows test-signing mode. Do not present these builds as production-ready.

## What The Preview Zip Contains

- `x64/Release/WinSideUSB.exe`
- `x64/Release/IddSampleDriver/` driver package
- `x64/Release/IddSampleDriver.cer` test certificate
- `scripts/Install-DevDriver.ps1`
- `WinSideUSB/swiftclientcode.swift`
- README, troubleshooting docs, notices, and license texts

The app embeds the libimobiledevice/usbmux runtime tools at build time. If the preview build bundles those tools, include the GPL/LGPL license texts and third-party notices in the zip.

## Tester Requirements

- Windows 10 or Windows 11.
- Administrator access.
- Secure Boot disabled if Windows blocks test-signing mode.
- Windows test-signing enabled:

```powershell
bcdedit /set testsigning on
```

- Reboot after changing test-signing mode.
- iPad app running from `WinSideUSB/swiftclientcode.swift`.

Anti-cheat and protected games may refuse to run while test-signing mode is enabled. Testers should turn test-signing off again when done:

```powershell
bcdedit /set testsigning off
```

Then reboot.

## Tester Quick Start

1. Extract the zip.
2. Open PowerShell as Administrator in the extracted folder.
3. Install the development driver:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-DevDriver.ps1
```

4. Run the iPad Swift client and wait for `PC bekleniyor`.
5. Run:

```powershell
.\x64\Release\WinSideUSB.exe
```

6. Press Start.

## Packaging

Build the app and driver first, then run:

```powershell
.\scripts\Package-DevPreview.ps1 -Version "0.1.0-dev"
```

The zip is written under `dist/`.

