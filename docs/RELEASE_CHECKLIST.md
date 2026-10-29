# GitHub Release Checklist

## Before The First Push

- Decide whether the repository is private or public.
- If public, keep `LICENSE`, `SECURITY.md`, and third-party notices up to date.
- Keep generated build output out of git.
- Keep test certificates and private keys out of git.
- Keep third-party binaries out of git unless license notices are included.
- If a release bundles `iproxy.exe`, include GPL-2.0 notices and upstream source/access information.
- Keep NVIDIA SDK headers out of git.
- Make sure `README.md` still matches the current handshake, ports, and driver install flow.
- Make sure `docs/DRIVER.md` documents the current driver recovery steps.
- Make sure [SETUP.md](SETUP.md) matches `Build-Setup.ps1`, installer behavior, and the driver INF's Windows 11 x64 minimum.

## Files To Commit

- source files
- `.sln`, `.vcxproj`, `.filters`, `.rc`, `.inf`
- `README.md`
- `docs/`
- `scripts/Install-DevDriver.ps1`
- `scripts/Install-WinSideUSBDevPreview.ps1`
- `scripts/Uninstall-WinSideUSBDevPreview.ps1`
- `scripts/Package-DevPreview.ps1`
- `scripts/Build-Setup.ps1`
- `scripts/Get-SignedDisplayDriver.ps1`
- `WinSideUSBDisplayService/`, signed display client/output/protocol/service sources, and `tests/`
- `scripts/Setup-Driver.ps1`, `scripts/Setup-DriverSupport.psm1`, and `scripts/Setup-Prerequisites.ps1`
- `scripts/Setup-PrerequisitesSupport.psm1` and the reviewed `scripts/AppleUsbPrerequisite.json`
- `installer/WinSideUSB.iss`
- `Install-WinSideUSBDevPreview.cmd`
- `.gitignore`
- `.gitattributes`
- `LICENSE`
- `NOTICE.md`
- `SECURITY.md`
- `CONTRIBUTING.md`
- `licenses/`

## Files To Avoid

- `.vs/`, `.vscode/`
- `x64/`, `Debug/`, `Release/`
- `*.exe`, `*.dll`, `*.lib`, `*.exp`
- `*.pdb`, `*.ilk`, `*.obj`
- `*.cat`, `*.cer`, `*.pfx`, `*.pvk`, `*.spc`
- `*.csv`, `*.etl`, `*.evtx`, `*.dmp`, `*.mdmp`, `*.hdmp`
- `output_test.mp4`
- `*_New.cpp`
- local assistant/editor folders

## Local Smoke Test

Before packaging a setup EXE or legacy release zip:

1. Build `WinSideUSB.sln` Release x64, including the display service.
2. Fetch the pinned unchanged upstream driver and build the Signed setup.
3. Run installer ownership tests and native display/IPC tests without changing devices.
4. On a Windows 11 x64 test machine with Secure Boot on and test-signing off, install the normal setup.
5. Confirm the managed device is disabled and no extra desktop exists while idle.
6. Open the Windows and iPad apps and connect USB; confirm automatic streaming.
7. Confirm selected dimensions/Hz and unchanged physical monitor settings.
8. Unplug while streaming and while the desktop is static; confirm removal and replug recovery.
9. Test Stop, restart, exit, lock/logout and service crash recovery.
10. Uninstall and reinstall; confirm no orphaned devices/services or Code 43.

The original `IddSampleDriver.sln` and manual test-driver install remain a separate development workflow.

## Setup EXE Packaging

- Build the Windows app with all 25 USB tool/runtime resources expected by `WinSideUSB.rc`.
- For default Signed mode, use `Get-SignedDisplayDriver.ps1` to verify upstream 25.7.23; preserve original INF/DLL/CAT bytes and include its MIT notice. Build the native display service. For Development mode, supply our matching test certificate.
- Obtain the official Microsoft Visual C++ x64 Redistributable, at least as recent as the app's MSVC toolset. Verify its origin and signature before packaging.
- Build with `scripts/Build-Setup.ps1` and Inno Setup 6.7+; the source is `installer/WinSideUSB.iss`. See [SETUP.md](SETUP.md) for parameters and examples.
- Confirm `WinSideUSB-<version>-Development-Setup.exe` is explicitly labeled Development and requires test-signing on/Secure Boot off without changing either setting.
- Signed mode produces `WinSideUSB-<version>-Setup.exe` with a trusted upstream driver; our app/setup may be unsigned. Optional Release mode requires trusted app/own-driver signatures and `-SigningCertificateThumbprint` to sign setup/uninstaller. Record actual signature status instead of implying our unsigned setup is signed.
- Include project license texts, Microsoft sample notices, iPad Swift source, and the setup/driver/client documentation.
- Complete the third-party binary/version/source inventory for every embedded DLL/tool. Generic GPL/LGPL texts alone do not complete the corresponding-source and attribution work.
- Keep Apple installers/DLLs out of the payload. Setup downloads the reviewed original iTunes package directly from Apple when USB support is missing, requires its pinned hash and trusted Apple signature, and identifies acceptance of Apple's terms in the selected task. Review new versions and silent installer behavior before changing the pinned definition.
- Keep source archives, checksums, and signature verification results with release build records. Keep private signing keys out of every artifact.

## Setup Verification Matrix

These are release gates to execute on test machines, not a record of completed tests:

- [ ] Clean Windows 11 x64 installation without Visual Studio/WDK.
- [ ] Missing Apple Mobile Device Service downloads and installs the original Apple package with progress/cancellation; a stopped/disabled service is prepared automatically. Unselected automatic prerequisites block completion clearly.
- [ ] Corrupted download, untrusted/non-Apple signature, offline download, failed iTunes installation and a missing post-install service cannot produce a successful setup.
- [ ] Windows 11 N without Media Feature Pack prepares the capability through Windows Update and requests a restart; unavailable capability or organizational policy failures remain actionable.
- [ ] Absent/outdated Visual C++ runtime is installed; an existing newer shared runtime is preserved.
- [ ] Development setup checks test-signing on and Secure Boot off; blocked prerequisites do not cause security-setting changes.
- [ ] Default Signed setup installs and streams with Secure Boot on and test-signing off.
- [ ] No extra desktop exists while idle; exact pixel/Hz settings and all physical monitors survive activation and disconnect.
- [ ] Unrelated MttVDD installations are preserved and rejected before mutations; owned configuration, registry values and permissions are restored on uninstall.
- [ ] Stop, static-desktop USB loss, process death, lock/logoff and service recovery release the managed display.
- [ ] Administrator cancellation, driver trust failures, malformed/missing files, and interrupted installation do not report success.
- [ ] Driver rollback removes only devices, packages, and certificates owned by the failed operation.
- [ ] Upgrading preserves a usable installation and records the correct driver package/device identity.
- [ ] Settings → Apps → Installed apps invokes the registered WinSideUSB uninstaller.
- [ ] Uninstall removes owned app files, shortcuts, virtual device, and driver package; shared Apple software, runtimes, and unrelated devices remain intact.
- [ ] Only development certificates imported by this installation are considered for removal; pre-existing/shared certificates remain intact.
- [ ] Driver cleanup happens before app-file removal. Failures and restart-required status preserve the app/helper scripts, and uninstall can be retried after recovery/restart; driver exit code `3010` is treated as restart required.
- [ ] Repeated uninstall, partial-install uninstall, and install → uninstall → reinstall work.
- [ ] Physical iPad streams after setup, stops/restarts, and reconnects after USB removal without `Code 43`.
- [ ] Retained setup state/logs in `%ProgramData%\WinSideUSB` and user streaming logs in `%LOCALAPPDATA%\WinSideUSB` match documented behavior.

## Legacy Release Zip Contents

For a downloadable development build:

- `x64/Release/WinSideUSB.exe`
- `x64/Release/IddSampleDriver/`
- `x64/Release/IddSampleDriver.cer`
- `scripts/Install-DevDriver.ps1`
- `scripts/Install-WinSideUSBDevPreview.ps1`
- `scripts/Uninstall-WinSideUSBDevPreview.ps1`
- `Install-WinSideUSBDevPreview.cmd`
- `WinSideUSB/swiftclientcode.swift`
- libimobiledevice runtime files if not embedded, or GPL/LGPL notices if embedded
- iPad Swift client source
- driver package only if users are expected to install a development test driver
- clear warning that test-signed driver install requires test-signing setup
- third-party notices
- GPL-2.0 notice/source-access information if `iproxy.exe` is bundled

Use `scripts/Package-DevPreview.ps1` to create the zip under `dist/`.

This ZIP/CMD/PowerShell flow is separate from the single-EXE installer. Verify its installed uninstall-script path before publishing a legacy preview.

For a normal public release, use the verified unchanged signed upstream package and complete the hardware/clean-machine gates above.

## Public Repository Notes

- Make clear that the project is experimental.
- Make clear that development driver installs may require test-signing mode.
- Do not imply affiliation with Apple or any commercial display product.
- Complete hardware validation and third-party runtime/source inventory before public binary distribution.
