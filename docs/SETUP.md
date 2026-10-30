# Single-EXE Setup

The Windows installer packages WinSideUSB, its ready-signed virtual display driver, display service, Microsoft Visual C++ x64 runtime, documentation, license notices, and iPad client source into one executable. It creates shortcuts and a Windows **Installed apps** entry with an uninstaller.

The default **Signed** mode uses the unchanged trusted-signed Virtual Display Driver 25.7.23 x64 package. It does not require test mode or disabling Secure Boot. The separate Development/Release modes retain our own-driver workflows. Installed-app USB streaming and exact display modes have been checked on the development machine. Clean Windows 11 VM installation, driver loading, removal and reinstall are verified in [the 0.3.12 report](RELEASE_0.3.12.md); other physical hardware remains to be tested. See [SIGNED_DISPLAY.md](SIGNED_DISPLAY.md) for exact-mode handling, device lifetime and upstream limitations, and [PERFORMANCE.md](PERFORMANCE.md) for the Windows 0.3.7 pacing comparison.

## Install On Windows

1. Use **Windows 11 x64**, build 22000 or later. Windows on ARM and S mode are not supported by this integration.
2. Run setup and leave its prerequisite options enabled. If Apple USB support is absent, setup downloads Apple's official iTunes package (about 200 MB) with progress/cancellation, verifies the pinned hash and Apple signature, then extracts and installs only Apple Mobile Device Support. The extracted MSI also needs its own pinned hash and trusted Apple signature; iTunes itself is not installed. The task explicitly accepts Apple's terms, linked in setup. An existing usable Apple installation is reused. On Windows N, missing media components are installed through Windows Update. These downloads need internet access; an already prepared PC does not need them.
3. On the **Driver publisher** page, choose whether setup may add the verified SignPath Foundation publisher to this machine's Trusted Publishers store. The option is unchecked by default. Selecting it allows driver installation without a separate Windows publisher prompt; leaving it unchecked keeps Windows' normal approval prompt. The trust applies to other drivers signed by the same certificate. For a separate **Development** setup, test-signing must already be enabled and Secure Boot disabled; see [DRIVER.md](DRIVER.md#test-signed-development-install).
4. Accept the administrator prompt and finish setup. It installs the bundled Visual C++ runtime when needed, the virtual display driver, service and app, with Start menu and desktop shortcuts. No terminal commands or manual DLL/driver copies are required.
5. Complete any requested restart. Otherwise the default finish action opens WinSideUSB immediately. With an iPad client open, connect USB and trust the PC on the iPad if asked. The managed display stays disabled until the USB handshake succeeds. Stop, USB loss or app exit releases it. Pixel/Hz choices retain the existing modes.

Download a built setup from the project's release artifacts. GitHub's **Code → Download ZIP** downloads source code and cannot be used as an installer.

`iproxy.exe` and `usbmuxd.dll` are client tools that depend on a working Apple usbmux service. The [libusbmuxd project](https://github.com/libimobiledevice/libusbmuxd#prerequisites) documents Apple Mobile Device Support as the Windows provider. Setup now handles acquiring that prerequisite from Apple; Apple's installer is downloaded during installation and is not redistributed inside our EXE. The exact URL, version and SHA-256 are reviewed in `scripts/AppleUsbPrerequisite.json`. The outer package and extracted Apple Mobile Device Support MSI each need their own pinned hash and trusted Apple publisher signature. Windows cabinet extraction and Windows Installer are used to prepare just the USB component. Setup starts an installed stopped service, restores automatic startup if it was disabled, and preserves shared Apple software during WinSideUSB uninstall.

Windows N media installation uses Microsoft's [Add-WindowsCapability](https://learn.microsoft.com/en-us/powershell/module/dism/add-windowscapability) and requests a restart, as required by the [Media Feature Pack](https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-n). Setup does not bypass Windows Update or organizational policy. An unavailable download, invalid signature, failed prerequisite or missing post-install service blocks completion with a retryable error. A genuine pending restart disables the finish-page launch action.

WinSideUSB setup does not install the iPad application. Use the included `swiftclientcode.swift` with Swift Playgrounds or a native iOS app target, on iPadOS 17 or later. See [IPAD_CLIENT.md](IPAD_CLIENT.md).

## Development And Release Packages

| Mode | Output name | Driver requirement |
| --- | --- | --- |
| Signed (default) | `WinSideUSB-0.3.12-Setup.exe` | Original pinned MttVDD INF/DLL/CAT, trusted vendor signatures and catalog contents; native display service; no test-signing requirement |
| Development | `WinSideUSB-0.2.0-Development-Setup.exe` | Test-signed package, matching test certificate, test-signing already on, Secure Boot off |
| Release | `WinSideUSB-0.2.0-Setup.exe` | Trusted app/DLL/CAT signatures and signed setup/uninstaller; clean-PC validation with Secure Boot on and test-signing off |

The default version is `0.3.12` and mode is **Signed**. Signed verifies the original vendor files, trusted DLL/CAT signatures and reviewed publisher thumbprint. Only the explicit publisher option can add that leaf certificate to `LocalMachine\TrustedPublisher`; it never adds a root certificate or enables test-signing. Pre-existing trust is preserved. Trust introduced by setup is removed during rollback/uninstall once no driver package needs it. Signing our app/setup is optional in this mode. The optional **Release** mode retains trusted app/own-driver signatures and requires `-SigningCertificateThumbprint` to sign setup and its uninstaller. **Development** remains explicit and separately labeled.

For unattended Signed installation, explicitly pass `/TRUSTDISPLAYPUBLISHER=1` when accepting the same machine-wide publisher trust. Without that flag, silent setup requires this publisher to be trusted already and otherwise fails before installing prerequisites or staging the driver. This avoids an invisible Windows consent dialog. The signed package bytes and publisher certificate remain pinned regardless of the choice. See Microsoft's [Trusted Publishers guidance](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/trusted-publishers-certificate-store).

Development app/setup executables may be unsigned. Only the public test certificate is included in a Development payload; private signing keys are never included.

The development path imports its matching certificate only for driver installation and records whether this installation added it. Uninstall uses that ownership information. Setup does not enable test-signing, change Secure Boot, or reboot without showing the outcome.

## Build The Setup

Maintainers need the built app and display service, the pinned upstream package (`MttVDD.inf`, `MttVDD.dll`, `mttvdd.cat`), an official Microsoft Visual C++ x64 Redistributable, and [Inno Setup 6.7 or later](https://jrsoftware.org/isdl.php) with its compiler (`ISCC.exe`). Development/Release instead use our `IddSampleDriver` package. The Windows app already embeds the 25 USB tool/runtime resources listed in `WinSideUSB/WinSideUSB.rc`; those files must have been present when the app was built. `Build-Setup.ps1` verifies all 25 resources inside the actual EXE.

End users do not need Visual Studio, the WDK, or Inno Setup. These are build-machine requirements.

For the normal ready-signed setup, build `WinSideUSB.sln` Release x64 (including the display service), then obtain the pinned upstream package and run:

```powershell
.\scripts\Get-SignedDisplayDriver.ps1
.\scripts\Build-Setup.ps1 -Version "0.3.12" -DriverMode Signed `
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
| `Version` | Package version; default `0.3.12` |
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

Run a newer setup to upgrade the installed app. Driver operations record package and device identity so cleanup can target WinSideUSB's own installation. Error handling attempts to roll back driver changes introduced by the failed operation rather than treating a partial installation as complete. Same-version upgrade, uninstall and reinstall passed in the [clean Windows 11 VM](RELEASE_0.3.12.md); historical-version migrations and real induced-failure recovery still need their own checks.

The installed app is `%ProgramFiles%\WinSideUSB\WinSideUSB.exe`, with `driver`, `scripts`, `docs`, `licenses`, and `iPad` subdirectories beside it.

Signed mode also installs `WinSideUSBDisplayService.exe` and a LocalSystem Windows service. It records its exact root-device instance, service and configuration ownership. An unrelated MttVDD installation is detected and preserved; setup refuses to change it because upstream shares a global configuration path. Upgrading an owned legacy driver removes only the prior owned device before switching to the signed driver.

To remove the app, open **Settings → Apps → Installed apps → WinSideUSB → Uninstall** (the development entry is **WinSideUSB Development Preview**). The uninstaller closes the owned app, stops/removes the owned service, removes its virtual display device/package and restores recorded configuration/registry values. It removes publisher trust only when this setup introduced it and no other driver package uses it. Only after driver cleanup succeeds does it remove app files and shortcuts.

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
