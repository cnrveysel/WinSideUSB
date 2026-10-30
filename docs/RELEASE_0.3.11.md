# Windows 0.3.11: setup prepares the Windows host

Download `WinSideUSB-0.3.11-Setup.exe` from [release Assets](https://github.com/cnrveysel/WinSideUSB/releases/tag/v0.3.11), approve administrator access, leave the prerequisite options enabled and finish setup. No manual driver/DLL copies, Visual Studio or PowerShell commands are needed for installation.

## Setup behavior

- Installs WinSideUSB, its display service, the unchanged upstream signed display driver, Visual C++ runtime, Start menu entry and default desktop shortcut.
- Reuses working Apple USB support. When absent, downloads Apple's original iTunes 12.13.12.3 x64 package (about 200 MB) in a progress/cancellation page, checks its pinned SHA-256 and trusted Apple signature, then independently verifies and installs only Apple Mobile Device Support 20.0.1.47 without a forced reboot. iTunes itself is not installed. The task identifies Apple USB support and acceptance of Apple's linked terms. Apple's installer is downloaded at setup time, outside our distributable EXE.
- Starts an installed Apple USB service and restores automatic startup if disabled.
- Prepares missing Windows N media components through Windows Update. A genuine restart requirement disables app launch until Windows restarts; installation failures remain visible.
- Opens WinSideUSB at the end when a restart is unnecessary. Uninstall keeps shared Apple software and the Visual C++ runtime.

An existing iPad client can then connect by USB. iPad app distribution is a separate follow-up. Windows video behavior and the iPad 1.1 (5) source retain the pre-audio baseline.

## Verification

The reviewed Apple installer was actually downloaded from Apple's pinned URL; its exact SHA-256 and Windows-trusted Apple publisher signature passed the same verifier used by setup. Automated prerequisite tests cover existing/missing support, failed or falsely successful installers, post-install service checks, checksum/signature/publisher failures, Windows N capability preparation and restart handling. Existing driver ownership, rollback, registry and native display/USB tests remain in the source-check workflow.

The manual-dispatch workflow additionally runs a real Apple USB MSI installation and service-start smoke test on a disposable Windows Server 2025 runner, saving logs. This tests the Apple dependency chain; it does not establish Windows 11 display-driver or physical iPad compatibility. See the latest [workflow runs](https://github.com/cnrveysel/WinSideUSB/actions/workflows/checks.yml) for execution results.

On 30 October 2026, [all three hosted jobs passed](https://github.com/cnrveysel/WinSideUSB/actions/runs/40977443018): Windows native/IPC/EDID checks and 66 setup tests, Swift helpers, and the real Apple USB installation. The Apple test began without installed USB support, verified/extracted the actual Apple package, installed the MSI and confirmed its service was running. Its [installer logs and readiness record](https://github.com/cnrveysel/WinSideUSB/actions/runs/40977443018/artifacts/12942963415) are retained as build evidence. The local Windows installer also compiled successfully; its welcome/terms text was inspected in a non-installing preview.

Clean Windows 11 / Windows 11 N installation, reboot, uninstall and physical USB streaming still need the machine matrix in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). WinSideUSB's app and setup remain unsigned; the upstream display driver is trusted-signed. The standalone macOS transport finding remains documented in [CI.md](CI.md).

The installer, its checksum and the manifest under release Assets belong to the exact versioned source. Source ZIP/TAR archives do not include a built Windows setup.
