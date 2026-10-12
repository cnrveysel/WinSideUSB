# Ready-signed display integration

The default **Signed** setup uses the original x64 DLL, INF and CAT from [Virtual Display Driver 25.7.23](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.7.23). Their hashes are pinned, the DLL and catalog have trusted SignPath Foundation signatures, and catalog verification checks the actual INF/DLL contents. The driver files are never renamed internally, patched, rebuilt or re-signed by WinSideUSB. See the [upstream MIT license](https://github.com/VirtualDrivers/Virtual-Display-Driver/blob/25.7.23/LICENSE), copied to `licenses/Virtual-Display-Driver-MIT.txt`.

This is an alternative to distributing our own development-signed IDD. Test mode and Secure Boot changes are unnecessary for this package; Windows 11 x64 remains the supported setup target. ARM64 and S mode are not included in this integration. Our app/setup executables may be unsigned; driver trust is checked independently.

## Display lifetime

Setup owns one `ROOT\MTTVDD` device instance and leaves it disabled. The native `WinSideUSBDisplayService` starts through the Windows Service Control Manager and initially disables its owned node before accepting any requests. It runs as LocalSystem because enabling and disabling a PnP device needs privileges; the desktop app continues running normally without repeated administrator prompts.

1. The Windows app detects a USB iPad and attempts the existing USB tunnel and `WSUSB_HELLO2` / `WSUSB_READY2` handshake.
2. After the iPad client confirms readiness, the installed app obtains a display lease through a local named pipe. The service checks the client image, Windows user/session and protected setup configuration before enabling its exact owned device.
3. The app finds that device's display path by identity, applies the selected pixel size and Hz, and captures the matching DXGI output on its own adapter. It does not choose a physical monitor by ordinal or fall back to mirroring.
4. USB/tunnel loss, **Stop display**, app exit, a broken lease, session end or service stop disables the device. An idle/static desktop has a separate connection watcher, so disappearance does not depend on new video frames.

The Windows app must be running, and the iPad client must be open. Connecting a cable alone without a responding client does not create a blank second desktop. Automatic attempts are paused after pressing Stop until a new USB connection is detected; Start retries manually. Closing the window exits the app and releases the display; minimizing retains the existing tray behavior.

The pipe lease is renewed every three seconds and expires after fifteen seconds if the process remains alive but stops answering. Process exit/broken-pipe detection normally releases it sooner. Service recovery starts by disabling any node left enabled by a service crash. Only setup-owned devices are controlled.

## Exact pixel size and Hz

The existing iPad database and mode selector retain their values. Setup generates upstream XML containing every supported iPad resolution and the existing 60/120 Hz choices, plus the unknown-iPad fallback resolutions. The XML is separate from the signed driver package, so configuring modes does not invalidate the signature. UMDF driver-host accounts receive read access; only administrators and SYSTEM can modify configuration.

The application selects an exact progressive 32-bit mode and verifies actual dimensions and refresh rate through GDI and DisplayConfig. It snapshots physical displays before enabling the device and verifies their resolution, refresh rate, primary status, orientation, position and display paths. A failed activation attempts to restore the original topology. Normal disconnect does not restore an old snapshot over later user changes.

If the requested mode is unavailable, connection fails with a visible message instead of silently substituting a lower resolution or refresh rate. Capture also checks dimensions/rotation/refresh rate and texture compatibility so a later Windows mode change cannot feed a wrongly sized texture to the existing encoder.

## Ownership and coexistence

Upstream uses a global configuration path and driver group. Setup refuses an unrelated existing MttVDD installation rather than changing another application's virtual monitors. Configuration and registry restoration, service removal and PnP package cleanup use recorded ownership. The original development driver and manual ZIP installer remain separate optional developer flows.

The upstream driver has its own control pipe, separate from WinSideUSB's authenticated lease pipe. WinSideUSB does not use upstream reload or configuration commands. The driver's published implementation exposes this interface more broadly than our broker and can wait for its pipe thread during unload. The signed binary cannot be patched without invalidating its signature; native disconnect/unload behavior remains part of real-device validation.

## Validation

Source builds, native display-planning/IPC tests, unchanged-payload signatures/catalog membership and setup preflight can be checked without installing a driver. These do not prove a complete hardware run. Still verify on Windows 11 x64 with Secure Boot on and test-signing off:

Local checks on 2026-10-09 passed: Release x64 app/service builds, 35 mocked setup ownership/configuration/service tests, 55 native output checks, 39 native IPC/lifetime checks and 12 USB child-process checks. A native Inno preflight-only harness passed the Signed checks with the normal protected installation directory and never entered installation. The original upstream DLL/CAT signatures and actual INF/DLL catalog contents passed verification. No driver/service was installed by these checks. Our generated setup/app remain unsigned; the bundled vendor driver is signed.

Setup 0.3.1 fixes registry descriptor reads under Windows PowerShell 5.1, which could report an existing key as missing. It also accepts the standard CREATOR OWNER inheritance placeholder on the protected SOFTWARE parent and restores only the permissions changed by setup. Eight additional registry tests cover actual disposable HKCU key/value/ACL operations and real read-only SOFTWARE permissions; all 43 setup tests pass. Test keys are removed after each run. The app/service binaries and signed vendor driver are unchanged by this packaging fix.

The actual local setup attempt revealed two further packaging problems. Published-package lookup now resolves a Windows-published OEM INF and verifies the actual stored INF/DLL/CAT bytes, rather than querying SetupAPI with an arbitrary extracted source path. Four read-only Driver Store tests pass against the already-staged package and reject altered payloads. Setup 0.3.3 also applies only the DACL when protecting a newly created registry key, preserving its trusted owner/group; a real disposable-key regression covers descriptors with owner/group changes. All 48 setup tests pass. Setup 0.3.3 subsequently completed on this local Windows 11 x64 host: finalization returned 0, the registered service is running, and the owned ROOT\MTTVDD\0000 node is disabled with Problem Code 22 before activation. This host already has developer tools and a staged vendor package, so it is not a clean-PC validation.

- Installation leaves no active second desktop without an iPad client.
- Every existing iPad mode keeps its exact pixel size and 60/120 Hz on connection.
- Unplugging while moving windows and while the desktop is static removes the display; replugging reconnects.
- Stop, app exit, session lock/logoff, service recovery and repeated connect/disconnect do not leave a display or Code 43 behind.
- Existing physical monitor settings remain intact on single/multiple GPU hosts.
- Setup upgrade, failed installation rollback, uninstall and reinstall remove only owned resources.

Setup 0.3.4 fixes ordinary-user broker validation: the client now matches the actual pipe server PID to the running own-process LocalSystem service and its exact quoted installed executable through SCM. It no longer needs to open the LocalSystem process, which returned Access Denied on this host. Eight identity regression checks and an opt-in read-only check against the real installed service pass as an ordinary user, alongside the 39 existing native IPC/lifetime checks (48 total with the opt-in check). The opt-in check sends no device requests. Launching the build-directory EXE now explains that the installed Start menu app is required.

See [SETUP.md](SETUP.md) and [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).
