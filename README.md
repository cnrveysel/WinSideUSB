# WinSideUSB

WinSideUSB is an open-source, experimental Windows-to-iPad USB display streamer.

It creates a Windows virtual display with an Indirect Display Driver (IDD), captures that display on the GPU, encodes the frames with a low-latency H.264 path, and sends video to an iPad over a USB-tunneled TCP connection.

The primary tested target is an iPad Pro 12.9-inch M2-class display at `2732x2048` and up to `120 Hz`.

## Status

This is a personal research project. It is not production-ready commercial display software yet.

The fastest path is designed for NVIDIA GPUs with NVENC, but the app also has Windows Media Foundation hardware/software fallback paths for non-NVIDIA systems. The driver is still development-signed and must be installed manually. Public distribution would require proper Microsoft driver signing.

This project is not affiliated with Apple or any commercial display product. iPad is a trademark of Apple Inc.

Development note: WinSideUSB was built by Veysel as a personal engineering project with ChatGPT used as an AI pair-programming and research assistant for debugging, profiling, documentation, and iterative implementation work.

## Features

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
docs/                          Driver, iPad, troubleshooting, and release notes
```

## Requirements

### Windows host

- Windows 10 or Windows 11.
- Visual Studio 2022 with Desktop development with C++.
- Windows SDK.
- Windows Driver Kit (WDK), required for building the IDD driver.
- NVIDIA GPU and driver for the native NVENC path. AMD and Intel systems may use the Media Foundation fallback path, but that path is less tested and may have higher latency or lower smoothness.
- NVIDIA Video Codec SDK header `nvEncodeAPI.h` for building the native NVENC path.
- Test-signing enabled for the development driver.

### iPad

- iPad with USB connection to the Windows host.
- Swift Playgrounds or an iOS app target that can run `WinSideUSB/swiftclientcode.swift`.
- The iPad app must be open before pressing Start in the Windows app.

### USB tools

The Windows app can embed `iproxy.exe`, `ideviceinfo.exe`, and required libimobiledevice DLLs as resources. These binaries are third-party runtime files and are not committed to the repository by default.

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

Build the driver:

```powershell
& "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\amd64\MSBuild.exe" IddSampleDriver.sln /p:Configuration=Release /p:Platform=x64
```

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

## Run

1. Build or install the IDD driver.
2. Copy the current `WinSideUSB/swiftclientcode.swift` into Swift Playgrounds or your iOS target.
3. Launch the iPad app and wait for:

```text
BSD socket listener v2
Port 17326 acik - PC bekleniyor...
```

The exact port may be `17326`, `17325`, `17324`, `17323`, `17322`, or `17321`.

4. Connect the iPad over USB and trust the computer if prompted.
5. Run `x64/Release/WinSideUSB.exe`.
6. Press Start.

## Diagnostics

Windows logs are written under:

```text
%LOCALAPPDATA%\WinSideUSB\
```

Useful files:

- `winsideusb_diag.log`: connection, driver IOCTL, and cleanup events.
- `iproxy.log`: USB tunnel forwarding output.
- `winsideusb_tx_*.csv`: per-second sender/capture/encoder telemetry.

iPad logs are created in the app document directory and can be shared from the overlay.

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common failures.

## More Docs

- [Driver install and recovery](docs/DRIVER.md)
- [iPad client notes](docs/IPAD_CLIENT.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Third-party runtime notes](docs/THIRD_PARTY.md)
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
