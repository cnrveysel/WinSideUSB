# Windows 0.3.10 / iPad 1.1 (5)

This release packages the last saved video-only baseline, `cb35f27`, with repository and distribution housekeeping. Audio development is outside this release.

## Included behavior

- Windows virtual display with per-model resolution choices and the existing 60/120 Hz modes.
- Improved capture pacing, DXGI cursor compositing and recovery from a saved HDR setting on the owned iPad display.
- iPad USB listener recovery, automatic reconnect and matching Playgrounds/native client sources.
- iPad frame-arrival and display-callback diagnostics, asynchronous logs and display FPS estimates.
- Single-EXE setup with the unchanged upstream signed display driver, display service, Visual C++ runtime, documentation and iPad Swift source.

## Downloads and installation

Use `WinSideUSB-0.3.10-Setup.exe` from [release Assets](https://github.com/cnrveysel/WinSideUSB/releases/tag/v0.3.10). The adjacent `.sha256` file checks the downloaded installer; `.manifest.json` lists hashes for the packaged files. GitHub's automatic ZIP/TAR downloads contain source code.

On Windows, verify the installer before opening it:

```powershell
Get-FileHash .\WinSideUSB-0.3.10-Setup.exe -Algorithm SHA256
Get-Content .\WinSideUSB-0.3.10-Setup.exe.sha256
```

Windows 11 x64 and Apple's USB support are required. The display driver has its upstream trusted signature. WinSideUSB's app and installer are unsigned. Secure Boot can stay enabled and Windows test-signing is unnecessary. Follow [SETUP.md](SETUP.md) and [IPAD_CLIENT.md](IPAD_CLIENT.md). The iPad client requires a compatible app build and your own Apple signing; personal provisioning profiles are excluded from the release.

## Validation scope

The source-check workflow exercises native display-mode, cursor, pacing, USB probe and IPC helpers, mocked installer ownership/rollback transactions, EDID configuration, and extracted production Swift transport/logging helpers. These checks do not install a driver or change a live display.

Local verification on 30 October 2026 passed the Windows Release x64 solution build with zero warnings/errors, the unsigned arm64 iPadOS production build, 44 setup transaction/registry tests, all native helper and IPC checks, four EDID tests, seven transport scenarios and the available Swift performance helper checks. The CoreMedia attachment runtime check requires an Apple runtime and was skipped under WSL. The iPad build was compiled in a separate directory and was not installed on a device.

This remains an experimental project. Clean-PC install/uninstall, non-development hardware and physical iPad performance checks remain as recorded in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). See [THIRD_PARTY.md](THIRD_PARTY.md) for upstream runtime licensing and the remaining distribution inventory work. Published setup assets are an experimental preview of the saved baseline.
