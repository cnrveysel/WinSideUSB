# Single-EXE Setup

The Windows installer packages WinSideUSB, its ready-signed virtual display driver, display service, Microsoft Visual C++ x64 runtime, documentation, license notices, and iPad client source into one executable. It creates shortcuts and a Windows **Installed apps** entry with an uninstaller.

The default **Signed** mode uses the unchanged trusted-signed Virtual Display Driver 25.7.23 x64 package. It does not require test mode or disabling Secure Boot. The separate Development/Release modes retain our own-driver workflows. Installed-app USB streaming and exact display modes have been checked on the development machine; clean-PC install/uninstall and other hardware remain to be tested. See [SIGNED_DISPLAY.md](SIGNED_DISPLAY.md) for exact-mode handling, device lifetime and upstream limitations, and [PERFORMANCE.md](PERFORMANCE.md) for the Windows 0.3.7 pacing comparison.

## Install On Windows

1. Use **Windows 11 x64**, build 22000 or later, the supported target for this setup and its display service. Windows on ARM and S mode are not supported by this integration. On **Windows 11 N**, install Microsoft's [Media Feature Pack](https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-n) and restart first. Setup checks for `MFPlat.dll`, which the app requires to launch.
2. Ensure **Apple Mobile Device Service** and Apple's USB device support are installed. Setup checks this prerequisite before installing WinSideUSB. If it is missing, follow setup's link to Apple's official [Apple Devices / iTunes installation guidance](https://support.apple.com/en-us/118290), install the Apple software, and run setup again.
3. For a **Development** setup, prepare Windows for the test-signed driver first: test-signing must already be enabled and Secure Boot disabled. See [DRIVER.md](DRIVER.md#test-signed-development-install). Setup checks these settings and leaves them under your control.
4. Double-click the downloaded setup EXE, accept the administrator prompt, choose the installation options, and install. Setup installs the bundled Visual C++ runtime when needed, installs the virtual display driver, and copies the app. It creates an all-users Start menu shortcut and an optional desktop shortcut.
5. Complete any requested restart, open the iPad client and run the Windows app. The managed display stays disabled until the USB client handshake succeeds. Stop, USB loss or app exit releases it. Pixel/Hz choices retain the existing iPad modes.

Download a built setup from the project's release artifacts. GitHub's **Code → Download ZIP** downloads source code and cannot be used as an installer.

Apple's USB software is a separate prerequisite. `iproxy.exe` and `usbmuxd.dll` bundled inside WinSideUSB are client tools; they depend on a working usbmux service. The [libusbmuxd project](https://github.com/libimobiledevice/libusbmuxd#prerequisites) documents Apple Mobile Device Support as the Windows provider. Setup does not redistribute Apple's installer or replace it with copied Apple DLLs. If the service exists but does not start, use Apple's [AMDS troubleshooting instructions](https://support.apple.com/en-us/102347).

WinSideUSB setup does not install the iPad application. Use the included `swiftclientcode.swift` with Swift Playgrounds or a native iOS app target, on iPadOS 17 or later. See [IPAD_CLIENT.md](IPAD_CLIENT.md).

## Development And Release Packages

| Mode | Output name | Driver requirement |
| --- | --- | --- |
| Signed (default) | `WinSideUSB-0.3.9-Setup.exe` | Original pinned MttVDD INF/DLL/CAT, trusted vendor signatures and catalog contents; native display service; no test-signing requirement |
| Development | `WinSideUSB-0.2.0-Development-Setup.exe` | Test-signed package, matching test certificate, test-signing already on, Secure Boot off |
| Release | `WinSideUSB-0.2.0-Setup.exe` | Trusted app/DLL/CAT signatures and signed setup/uninstaller; clean-PC validation with Secure Boot on and test-signing off |

The default version is `0.3.9` and mode is **Signed**. Signed verifies the original vendor files and trusted DLL/CAT signatures; it never imports a development certificate or changes Windows security settings. Signing our app/setup is optional in this mode. The optional **Release** mode retains trusted app/own-driver signatures and requires `-SigningCertificateThumbprint` to sign setup and its uninstaller. **Development** remains explicit and separately labeled.

Development app/setup executables may be unsigned. Only the public test certificate is included in a Development payload; private signing keys are never included.

The development path imports its matching certificate only for driver installation and records whether this installation added it. Uninstall uses that ownership information. Setup does not enable test-signing, change Secure Boot, or reboot without showing the outcome.

## Build The Setup

Maintainers need the built app and display service, the pinned upstream package (`MttVDD.inf`, `MttVDD.dll`, `mttvdd.cat`), an official Microsoft Visual C++ x64 Redistributable, and [Inno Setup 6.7 or later](https://jrsoftware.org/isdl.php) with its compiler (`ISCC.exe`). Development/Release instead use our `IddSampleDriver` package. The Windows app already embeds the 25 USB tool/runtime resources listed in `WinSideUSB/WinSideUSB.rc`; those files must have been present when the app was built. `Build-Setup.ps1` verifies all 25 resources inside the actual EXE.

End users do not need Visual Studio, the WDK, or Inno Setup. These are build-machine requirements.

For the normal ready-signed setup, build `WinSideUSB.sln` Release x64 (including the display service), then obtain the pinned upstream package and run:

```powershell
.\scripts\Get-SignedDisplayDriver.ps1
.\scripts\Build-Setup.ps1 -Version "0.3.9" -DriverMode Signed `
  -DriverPackageDir ".\.codex\vendor\VirtualDisplayDriver" `
  -ServicePath ".\x64\Release\WinSideUSBDisplayService.exe" `
  -VcRedistPath "C:\Path\To\VC_redist.x64.exe"
```

The fetcher and build verify the pinned original package. Use the directory printed by the fetcher if a different cache/output path is supplied. Only unchanged trusted upstream DLL/INF/CAT bytes are accepted. The generated XML includes all existing iPad pixel/Hz modes and is stored separately under protected `%ProgramData%\WinSideUSB\display-config`.

Obtain the x64 runtime from [Microsoft's supported Visual C++ Redistributable downloads](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170). Use a runtime at least as recent as the MSVC toolset used for the app; the current build requires `14.44.35211.0` or later and checks the redist's Microsoft signature. Installing only `vcruntime140.dll` is insufficient: the app also imports `MSVCP140.dll` and `VCRUNTIME140_1.dll`.

From the repository root, build a development setup with explicit input paths:

```powershell
.\scripts\Build-Setup.ps1 `
  -Version "0.2.0" `
  -DriverMode Development `
  -AppPath ".\x64\Release\WinSideUSB.exe" `
  -DriverPackageDir ".\x64\Release\IddSampleDriver" `
  -CertificatePath ".\x64\Release\IddSampleDriver.cer" `
  -VcRedistPath "C:\Path\To\VC_redist.x64.exe"
```

For a trusted release package:

```powershell
.\scripts\Build-Setup.ps1 `
  -Version "0.2.0" `
  -DriverMode Release `
  -AppPath "C:\Path\To\Signed\WinSideUSB.exe" `
  -DriverPackageDir "C:\Path\To\ReleaseDriver" `
  -VcRedistPath "C:\Path\To\VC_redist.x64.exe" `
  -SigningCertificateThumbprint "<40-character certificate thumbprint>"
```

Replace the thumbprint placeholder with a trusted signing certificate available, with its private key, in the build user's `CurrentUser\My` store. `SignToolPath` can be supplied explicitly; otherwise the build looks for the Windows SDK's signing tool. No PFX or signing password is placed in the payload.

Additional build parameters:

| Parameter | Purpose |
| --- | --- |
| `Version` | Package version; default `0.3.9` |
| `DriverMode` | `Signed` (default), `Release` or `Development` |
| `ServicePath` | Built native display-service EXE; required for Signed mode |
| `AppPath` | Built Windows app |
| `DriverPackageDir` | Complete built and signed driver package |
| `CertificatePath` | Matching development certificate; used only in Development mode |
| `VcRedistPath` | Official x64 Visual C++ Redistributable to bundle |
| `CompilerPath` | Explicit path to `ISCC.exe`, when automatic discovery is unsuitable |
| `OutputDir` | Output directory; default `dist` |
| `SigningCertificateThumbprint` | Required in Release mode; signs setup and its uninstaller using the certificate in `CurrentUser\My` |
| `SignToolPath` | Optional explicit path to the Windows SDK's `signtool.exe` |

The installer source is `installer/WinSideUSB.iss`. Driver operations use `scripts/Setup-Driver.ps1` and `scripts/Setup-DriverSupport.psm1`; Apple/Media Foundation checks use `scripts/Setup-Prerequisites.ps1`. The existing `Install-DevDriver.ps1` belongs to the earlier manual development flow.

The build also writes `.sha256` and `.manifest.json` sidecars for release verification. Installation itself uses only the single setup EXE.

The setup includes the project license texts and documentation. Before publishing, complete the exact third-party binary/version/source inventory described in [THIRD_PARTY.md](THIRD_PARTY.md) and [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). Include corresponding GPL/LGPL source access for the actual bundled builds and notices for every embedded binary. Keep private signing keys out of the installer and repository.

## Upgrade And Uninstall

Run a newer setup to upgrade the installed app. Driver operations record package and device identity so cleanup can target WinSideUSB's own installation. Error handling attempts to roll back driver changes introduced by the failed operation rather than treating a partial installation as complete. These flows still need clean-PC upgrade and failure-path testing.

The installed app is `%ProgramFiles%\WinSideUSB\WinSideUSB.exe`, with `driver`, `scripts`, `docs`, `licenses`, and `iPad` subdirectories beside it.

Signed mode also installs `WinSideUSBDisplayService.exe` and a LocalSystem Windows service. It records its exact root-device instance, service and configuration ownership. An unrelated MttVDD installation is detected and preserved; setup refuses to change it because upstream shares a global configuration path. Upgrading an owned legacy driver removes only the prior owned device before switching to the signed driver.

To remove the app, open **Settings → Apps → Installed apps → WinSideUSB → Uninstall** (the development entry is **WinSideUSB Development Preview**). The uninstaller closes the owned app, stops/removes the owned service, removes its virtual display device/package and restores recorded configuration/registry values. Development certificate cleanup applies only to the legacy development package. Only after this succeeds does it remove app files and shortcuts.

If driver cleanup fails or returns restart-required status, uninstall preserves the app and helper scripts for retry. Follow the reported recovery step, restart when required, then run **Uninstall** again to complete driver/certificate cleanup and file removal. A partial removal is not reported as a finished uninstall.

Shared Apple software and the Visual C++ runtime remain installed, since other applications may depend on them. User logs and extracted runtime files under `%LOCALAPPDATA%\WinSideUSB` remain for diagnostics; remove this retained user data manually if you no longer need it.

If Windows requires a restart, complete it before reinstalling or using the virtual display. Driver operations report exit code `3010` for a restart requirement; `0` means success and other nonzero results indicate a step needing attention.

## Setup Diagnostics

Driver setup logs, operation results, and recorded installation state are stored under:

```text
%ProgramData%\WinSideUSB\
```

Relevant files include `setup-state.json`, `setup-result.json`, `setup-result.txt`, and `setup-driver-*.log`. Keep this folder when diagnosing installation, upgrade, driver trust, or removal failures. Inno Setup also writes its wizard log in the Windows temporary directory. App streaming logs remain under `%LOCALAPPDATA%\WinSideUSB`; these are different from setup logs.

## Verification Still Required

- Clean Windows 11 x64 installation without Visual Studio or the WDK.
- Missing/stopped Apple Mobile Device Service, Windows N without Media Feature Pack, absent/outdated Visual C++ runtime, administrator cancellation, and blocked development driver prerequisites.
- Driver install failure, interrupted setup, locked files, and restart-required outcomes.
- Upgrade, repeated uninstall, removal after a partial installation, and install → uninstall → reinstall.
- Trusted release driver with Secure Boot on and test-signing off.
- Ready-signed setup leaves no active second desktop at rest; an iPad client handshake activates only its owned screen at the selected exact pixel/Hz mode. Static-desktop USB removal, app exit and repeated reconnects disable it without Code 43.
- Real iPad streaming after setup, including USB disconnect and reconnect.

The earlier developer-preview ZIP remains documented in [DEV_PREVIEW_RELEASE.md](DEV_PREVIEW_RELEASE.md). Its CMD/PowerShell installation flow is separate from this EXE installer and its registered uninstaller.
