# GitHub Release Checklist

## Before The First Push

- Decide whether the repository is private or public.
- If public, keep `LICENSE`, `SECURITY.md`, and third-party notices up to date.
- Keep generated build output out of git.
- Keep test certificates and private keys out of git.
- Keep third-party binaries out of git unless license notices are included.
- Keep NVIDIA SDK headers out of git.
- Make sure `README.md` still matches the current handshake, ports, and driver install flow.
- Make sure `docs/DRIVER.md` documents the current driver recovery steps.

## Files To Commit

- source files
- `.sln`, `.vcxproj`, `.filters`, `.rc`, `.inf`
- `README.md`
- `docs/`
- `scripts/Install-DevDriver.ps1`
- `.gitignore`
- `.gitattributes`
- `LICENSE`
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

Before making a release zip:

1. Build `IddSampleDriver.sln` Release x64.
2. Install the driver with `scripts/Install-DevDriver.ps1`.
3. Confirm `WinSideUSB Virtual Display` is `Started`.
4. Build `WinSideUSB.sln` Release x64.
5. Run the iPad Swift client.
6. Press Start in `WinSideUSB.exe`.
7. Confirm iPad shows streaming.
8. Stop streaming.
9. Start again to confirm the IDD lifecycle does not regress.
10. Confirm no new `Code 43` appears.

## Release Zip Contents

For a downloadable development build:

- `WinSideUSB.exe`
- libimobiledevice runtime files if not embedded
- iPad Swift client source
- driver package only if users are expected to install a development test driver
- clear warning that test-signed driver install requires test-signing setup
- third-party notices

For a normal public release, do not ship the driver until it is properly signed for distribution.

## Public Repository Notes

- Make clear that the project is experimental.
- Make clear that development driver installs may require test-signing mode.
- Do not imply affiliation with Apple or any commercial display product.
- Prefer source-only publishing until the driver signing and third-party runtime packaging story is settled.
