# WinSideUSB

WinSideUSB is an open-source, experimental Windows-to-iPad USB display streamer.

It creates a Windows virtual display with an Indirect Display Driver (IDD), captures that display on the GPU, encodes the frames with a low-latency H.264 path, and sends video to an iPad over a USB-tunneled TCP connection.

The primary tested target is an iPad Pro 12.9-inch M2-class display at `2732x2048` and up to `120 Hz`.

## Status

This is a personal research project. It is not production-ready commercial display software yet.

The fastest path is designed for NVIDIA GPUs with NVENC, but the app also has Windows Media Foundation hardware/software fallback paths for non-NVIDIA systems. The default single-EXE setup uses the unchanged, trusted-signed x64 [Virtual Display Driver 25.7.23](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.7.23), a small display service, and the Visual C++ runtime. This package does not require test-signing or disabling Secure Boot. Installed-app USB streaming and exact display modes have been checked on the development machine; clean-PC installation/removal and other hardware remain to be tested. See [docs/SIGNED_DISPLAY.md](docs/SIGNED_DISPLAY.md) and [docs/SETUP.md](docs/SETUP.md).

Windows 0.3.7 improves capture frame pacing while retaining the existing display modes and iPad protocol. A controlled 120 FPS motion comparison and its measurement limits are documented in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

Windows 0.3.8 also composites the separate DXGI hardware cursor onto the video before encoding. Color, monochrome and masked cursors are supported on both GPU and software encoding paths; the existing iPad client can display the result.

This project is not affiliated with Apple or any commercial display product. iPad is a trademark of Apple Inc.

Development note: WinSideUSB was built by Veysel as a personal engineering project with ChatGPT used as an AI pair-programming and research assistant for debugging, profiling, documentation, and iterative implementation work.

## Roadmap

The native Windows/iPad UI, single-EXE setup/uninstall, and ready-signed display-driver integration have been implemented. The managed display stays disabled until the iPad client connects and is disabled when that connection ends. Real-device UI checks and clean-PC installation/removal verification remain pending. Automatic provisioning of Apple's USB software and Apple Pencil writing/drawing input remain planned work.

See [ROADMAP.md](ROADMAP.md) for the ordered checklist, dependencies, and completion criteria (in Turkish).

## Features

- Minimal native Windows UI with a light theme, DPI-aware resizing, keyboard navigation, and a log-folder shortcut.
- Adaptive iPad connection panel with setup guidance, expandable diagnostics, and controls that hide during streaming.
- Single-EXE Windows setup with bundled Visual C++ runtime, driver installation, shortcuts, and a registered uninstaller.
- USB-only iPad transport through the libimobiledevice/usbmux toolchain.
- On-demand Windows virtual display through a custom IDD driver.
- GPU capture with D3D11 Desktop Duplication.
- Native NVENC H.264 encode path for NVIDIA GPUs.
- Media Foundation hardware/software H.264 fallback path for other systems.
- Low-latency sender with latest-frame-wins behavior.
- iPad Swift client source for Swift Playgrounds or a native iOS app target.
- Product-type based iPad mode presets for Pro, Air, mini, and standard iPad models.
- Resilient iPad listener handshake using `WSUSB_HELLO2` / `WSUSB_READY2`.
- iPad port fallback over `17326` to `17321` to avoid stale Playgrounds listeners.

## iPad Compatibility

The Windows app reads the connected device `ProductType` with `ideviceinfo` and selects a matching resolution/FPS preset. The current source includes presets for known iPad, iPad Air, iPad mini, and iPad Pro identifiers through May 2026, including A16 iPad, M4 iPad Air, and M5 iPad Pro models.

Compatibility outside the primary tested iPad is best-effort: listed models should get an appropriate mode, but each physical device still needs real testing for smoothness, scaling, thermal behavior, and USB reliability. Unknown future iPads fall back to safe 60 Hz modes instead of being rejected outright.

Very old iPads are included in the Windows detection table for completeness, but they may not be practical targets for the current Swift client if they cannot run a compatible iPadOS app build.

## Repository Layout

```text
WinSideUSB.sln                 Windows desktop streamer solution
WinSideUSB/WinSideUSB.cpp      Main Windows app source
WinSideUSB/swiftclientcode.swift
IddSampleDriver.sln            Virtual display driver solution
IddSampleDriver/               IDD driver source
scripts/Install-DevDriver.ps1  Local test-driver install helper
scripts/Build-Setup.ps1        Single-EXE setup packager
scripts/Setup-Driver.ps1       Setup driver install/removal entry point
scripts/Setup-DriverSupport.psm1
scripts/Setup-Prerequisites.ps1
WinSideUSBDisplayService/      Native display-service project
installer/WinSideUSB.iss       Inno Setup installer source
docs/                          Driver, iPad, troubleshooting, and release notes
```

## Requirements

### Windows host

- Windows 11 x64, build 22000 or later, matching the current driver INF.
- Windows 11 N requires Microsoft's [Media Feature Pack](https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-n); setup checks Media Foundation availability.
- Apple Mobile Device Service and Apple USB support installed through Apple's software. Setup detects this prerequisite and offers official installation guidance if it is missing.
- Microsoft Visual C++ v14 x64 runtime; the EXE setup bundles and installs it when needed.
- NVIDIA GPU and driver for the native NVENC path. AMD and Intel systems may use the Media Foundation fallback path, but that path is less tested and may have higher latency or lower smoothness.
- The default **Signed** setup uses a ready-signed driver and leaves Windows security settings unchanged. The optional legacy **Development** package still requires test-signing enabled and Secure Boot disabled.

### Source build only

- Visual Studio 2022 with Desktop development with C++ and the Windows SDK.
- Windows Driver Kit (WDK), required only when building the separate legacy IDD driver.
- NVIDIA Video Codec SDK header `nvEncodeAPI.h` for building the native NVENC path.
- Inno Setup 6.7+ compiler and an official Visual C++ x64 Redistributable for building the setup EXE.

### iPad

- iPad running iPadOS 17 or later, with a USB connection to the Windows host.
- Swift Playgrounds or an iOS app target that can run `WinSideUSB/swiftclientcode.swift`.
- Keep the iPad app open. Windows automatically attempts to connect when it detects the USB iPad. **Start display** retries manually; **Stop display** pauses automatic connection until the iPad is unplugged/reconnected.

### USB tools

The Windows app can embed `iproxy.exe`, `ideviceinfo.exe`, and required libimobiledevice DLLs as resources. These binaries are third-party runtime files and are not committed to the repository by default.

The embedded tools still need Apple's USB service and device support on Windows. They do not install it themselves. Follow Apple's [Apple Devices / iTunes installation guidance](https://support.apple.com/en-us/118290) before running setup if Apple Mobile Device Service is absent. Apple's installer is not bundled with WinSideUSB.

`iproxy` comes from the libimobiledevice/libusbmuxd project. If you distribute builds that include `iproxy.exe` or libimobiledevice DLLs, include the upstream license texts and attribution notices. See [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).

Before building the app from a fresh checkout, place the required libimobiledevice runtime files in:

```text
x64/Release/
```

The expected file names are listed in `WinSideUSB/WinSideUSB.rc`.

## Build

Open a Developer PowerShell for Visual Studio, then build the app:

```powershell
$env:NVENC_INCLUDE_DIR = "C:\Path\To\Video_Codec_SDK\Interface"
& "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\amd64\MSBuild.exe" WinSideUSB.sln /p:Configuration=Release /p:Platform=x64
```

For the optional development backend, build our driver:

```powershell
& "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\amd64\MSBuild.exe" IddSampleDriver.sln /p:Configuration=Release /p:Platform=x64
```

## Setup EXE

End users can double-click `WinSideUSB-<version>-Setup.exe`, approve administrator access, and install the app, ready-signed driver, display service, runtime, and shortcuts. Remove it through **Windows Settings → Apps → Installed apps**. The managed virtual display is disabled at rest; installation does not leave an active second desktop. See [SIGNED_DISPLAY.md](docs/SIGNED_DISPLAY.md) for lifecycle and exact-mode handling.

Maintainers build a setup with:

```powershell
.\scripts\Get-SignedDisplayDriver.ps1
.\scripts\Build-Setup.ps1 -Version "0.3.8" -DriverMode Signed `
  -VcRedistPath "C:\Path\To\VC_redist.x64.exe"
```

The default **Signed** mode needs the app, display service, and unchanged signed upstream driver package. It validates the vendor signatures, catalog contents, and pinned hashes; our app/setup signing is optional in this mode. The optional **Release** mode retains its stricter own-driver and setup signing requirements. See [docs/SETUP.md](docs/SETUP.md) for build examples and remaining validation.

## Development Driver Install

The driver is test-signed during local development. Secure Boot normally blocks test signing, so local testing usually requires:

1. Disable Secure Boot in BIOS/UEFI.
2. Enable Windows test signing:

```powershell
bcdedit /set testsigning on
```

3. Reboot.
4. Install the driver from an elevated PowerShell:

```powershell
cd C:\Path\To\WinSideUSB
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-DevDriver.ps1
```

After install, verify that `WinSideUSB Virtual Display` is `Started`:

```powershell
pnputil /enum-devices /class Display /drivers
```

See [docs/DRIVER.md](docs/DRIVER.md) for details.

## Legacy Developer Preview Zip

The earlier developer-preview zip flow is still available, separately from the new EXE setup. Maintainers can package the app, test-signed driver, iPad source, CMD/PowerShell install helper, and license notices.

This is not a production installer. It still requires Administrator access, Windows test-signing setup, and the usual test-driver warnings.

Do not use GitHub's green **Code -> Download ZIP** button as an installer. That archive is source code only, so it does not contain `x64/Release/WinSideUSB.exe` or the built driver package. Testers should download `WinSideUSB-*-dev-preview.zip` from the GitHub Releases page.

After building the app and driver:

```powershell
.\scripts\Package-DevPreview.ps1 -Version "0.1.0-dev"
```

See [docs/DEV_PREVIEW_RELEASE.md](docs/DEV_PREVIEW_RELEASE.md).

Inside the zip, testers can start with:

```text
Install-WinSideUSBDevPreview.cmd
```

## Run

1. Install the normal setup EXE, or build/install the separate legacy development driver for source development.
2. Copy the current `WinSideUSB/swiftclientcode.swift` into Swift Playgrounds or your iOS target.
3. Launch the iPad app and wait for **İkinci ekranınız hazır.** The listener status is available under **Ayrıntılar**; the port may be `17326`, `17325`, `17324`, `17323`, `17322`, or `17321`.

4. Connect the iPad over USB and trust the computer if prompted.
5. Run `x64/Release/WinSideUSB.exe`.
6. The display connects automatically once the iPad app responds. Use **Stop display** to pause, change the existing pixel/Hz selection, and **Start display** to resume manually. Disconnecting USB or closing either app releases the second display.

## Diagnostics

Windows logs are written under:

```text
%LOCALAPPDATA%\WinSideUSB\
```

Useful files:

- `winsideusb_diag.log`: connection, display service/mode configuration, and cleanup events.
- `iproxy.log`: USB tunnel forwarding output.
- `winsideusb_tx_*.csv`: per-second sender/capture/encoder telemetry.

Use **View logs** in the Windows app to open the log folder.

iPad logs are created in the app document directory and can be shared from the overlay.

EXE setup logs and installation state are stored separately under `%ProgramData%\WinSideUSB`. See [docs/SETUP.md](docs/SETUP.md#setup-diagnostics).

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common failures.

## More Docs

- [Driver install and recovery](docs/DRIVER.md)
- [Single-EXE setup and uninstall](docs/SETUP.md)
- [iPad client notes](docs/IPAD_CLIENT.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Third-party runtime notes](docs/THIRD_PARTY.md)
- [Developer preview release notes](docs/DEV_PREVIEW_RELEASE.md)
- [Release checklist](docs/RELEASE_CHECKLIST.md)
- [GitHub upload guide](docs/GITHUB_UPLOAD.md)
- [Security notes](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Notices](NOTICE.md)

## GitHub Notes

Do not commit:

- `x64/`, `Debug/`, `Release/`, `.vs/`
- generated `.exe`, `.dll`, `.pdb`, `.cat`, `.cer`, `.pfx`
- WER dumps, CSV telemetry, ETL traces, and local logs
- bundled third-party binaries unless their licenses are included
- NVIDIA SDK headers

Use GitHub Releases for packaged builds. Include third-party notices for libimobiledevice, `iproxy`, and every bundled DLL.

## License

Original WinSideUSB project code is released under the [MIT License](LICENSE).

Microsoft IDD sample-derived driver code keeps Microsoft copyright notices and MS-PL terms. Third-party tools, SDK headers, Windows driver samples, and runtime binaries keep their own licenses. See [NOTICE.md](NOTICE.md) and [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).
