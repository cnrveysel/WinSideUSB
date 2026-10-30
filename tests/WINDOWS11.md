# Real Windows 11 installer lifecycle

`Invoke-WindowsInstallLifecycle.ps1` installs and removes the actual versioned setup. It is separate from mocked Pester transactions and must run only in a disposable VM.

Prepare a fresh Windows 11 x64 VM with Secure Boot and TPM 2.0 enabled, an interactive local account named `WSTester`, and a computer name starting with `WSUSBE2E`. Keep Apple USB support, Visual C++ and WinSideUSB absent initially. Do not pass through physical disks or an iPad. Save a powered-off clean checkpoint with its matching UEFI and TPM state.

Copy the script and `WindowsInstallLifecycle.example.json` into `C:\WSTest`, naming the configuration `lifecycle-config.json`. Explicitly mark the disposable VM by creating `C:\WSTest\vm-marker.json` containing `{}`. Review the setup URL, exact SHA-256 and `TrustDriverPublisher` choice. The example explicitly selects machine-wide trust in the reviewed driver publisher; a fresh unattended installation cannot proceed without that choice. `ReportUri` may remain empty to keep all evidence local.

Run the script from elevated Windows PowerShell 5.1. After each requested reboot, sign in as `WSTester` and run the same script again. The phase file in `C:\WSTest\results` resumes the next step; do not clear it during a run. A logon agent can invoke the same script to automate this sequence.

The test covers fresh install, reboot, real PnP driver enable/disable, app launch with a limited token, uninstall while the app is open, reboot, reinstall, reboot, same-version upgrade, reboot, and final uninstall/reboot. It verifies the service, single owned device/package, shortcuts, version, Apple service, runtime, publisher ownership and cleanup. Shared Apple/VC++ support must survive removal. The app must open and respond without elevation. Both the Inno launcher and its child processes must exit before logs are inspected; the process wait has a bounded timeout.

`lifecycle-result.json` is written only after the final cleanup assertions pass. Installer logs, installed-state records and `lifecycle-events.jsonl` retain the intermediate evidence. A failed run must be investigated before resuming; for a repeat of the complete fresh-install scenario, restore the clean checkpoint and use a new `RunId`.

This verifies Windows installation and local app/driver startup. Physical USB pairing, GPU encoding, sustained display streaming, Windows N capability installation, ARM64 and S mode need their own environments. A same-version upgrade does not establish compatibility with every historical installer.
