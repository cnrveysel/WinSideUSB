# Windows 0.3.12: clean Windows 11 installer validation

[Download the Windows x64 setup](https://github.com/cnrveysel/WinSideUSB/releases/download/v0.3.12/WinSideUSB-0.3.12-Setup.exe). Keep the prerequisite options enabled. On the publisher page, explicitly select **Trust SignPath Foundation on this PC** for automatic driver installation, or approve the normal Windows publisher prompt yourself. Complete a requested restart before opening the app.

The clean-PC test of 0.3.11 found a real installation blocker: the correctly signed upstream driver still prompted for publisher approval, blocking an unattended setup. Version 0.3.12 adds a separate, unchecked publisher-trust option. It verifies the pinned driver bytes, catalog membership, trusted signatures and exact reviewed signer before adding its leaf certificate to `LocalMachine\TrustedPublisher`. This affects other drivers signed by that certificate. It does not add a root certificate. Existing trust is preserved; setup records and removes only trust it introduced, when no other driver package needs it. Silent installation requires `/TRUSTDISPLAYPUBLISHER=1` or existing publisher trust, and otherwise stops at the initial check. See [setup details](SETUP.md) and Microsoft's [publisher-trust guidance](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/trusted-publishers-certificate-store).

## Actual Windows 11 test

On 30 October 2026, the actual release candidate completed the installer lifecycle in an isolated QEMU/KVM VM: **Windows 11 Enterprise Evaluation 26H2, build 26300**, x64, 4 vCPUs, 6 GB RAM, UEFI Secure Boot on and TPM 2.0 ready. The initial OS had no WinSideUSB, Apple USB service, vendor display package or Visual C++ runtime. Windows was installed from Microsoft's [evaluation media](https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise); no physical disk or iPad was passed into the VM.

| Check | Observed result |
| --- | --- |
| Fresh setup | Exit 0; actual Apple USB download/MSI installation, VC++ runtime, app, service and shortcuts ready |
| First reboot | Display service running automatically as LocalSystem; exactly one owned device/package, disabled at idle (Code 22) |
| Driver load | Global/current-profile SetupAPI enable loaded the actual driver with Code 0; disabling restored Code 22 |
| Installed app | Three launches produced a responsive native window with a non-elevated token |
| First uninstall with app open | Exit 0; reboot confirmed no app, service, owned PnP node/package, installed-app registration or shortcuts |
| Publisher cleanup | Exclusively owned TrustedPublisher leaf removed; no leaf was added to Root |
| Reinstall | Exit 0; reboot and normal app launch passed; shared prerequisites reused |
| Same-version upgrade with app open | Exit 0; reboot confirmed one owned device/package and another normal app launch |
| Final uninstall with app open | Exit 0; final reboot and complete cleanup assertions passed |
| Shared dependencies | Apple USB service remained running and VC++ remained installed after both removals |

The harness requested five reboots. Testing resumed from its recorded phase after the WSL VM host stopped. Two harness issues were corrected: waiting for Inno's child process tree before reading its log, and using the persistent global/profile device-enable operation instead of only enabling a live devnode. Raw event history retains those attempts. The final failed-phase retry and all remaining product checks passed; `lifecycle-result.json` was written only after the last cleanup checks.

The [reproducible harness](../tests/WINDOWS11.md), [recorded result](../tests/results/windows11-0.3.12.json) and release evidence ZIP document the scope. Setup transactions also passed **72 Pester tests**, including new publisher selection, pre-existing trust, incorrect signer, silent rejection, rollback and uninstall cases. The [source-check run](https://github.com/cnrveysel/WinSideUSB/actions/runs/40985641584) passed Windows native/IPC/EDID checks and Swift helpers.

## Artifact identity and limits

The tested setup is **29,316,954 bytes**, SHA-256:

```text
8985D5FE4344FBA099CF63ED133B6804AA81F958C3E52175DBE9AB187FBEAF55
```

The release publishes those same tested bytes. The candidate was served locally to the isolated VM; the public download digest is checked after publication. The manifest records the payload snapshot built before this test report was written.

The Windows video executable, display service and iPad 1.1 (5) source are byte-for-byte identical to 0.3.11's pre-audio payload. This release changes setup and its tests. iPad distribution remains separate.

The VM validates Windows installation, local app startup, driver loading and removal. Physical USB pairing/streaming, GPU encoding, other Windows builds/editions, Windows N capability installation, ARM64 and S mode are outside this test. The app/setup remain unsigned, so downloaded executables can still receive Windows reputation/publisher warnings. The [remaining machine matrix](RELEASE_CHECKLIST.md) and [macOS helper limitation](CI.md) still apply.
