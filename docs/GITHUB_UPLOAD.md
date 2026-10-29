# GitHub Publishing

The repository is [cnrveysel/WinSideUSB](https://github.com/cnrveysel/WinSideUSB); its default branch is `main`.

## Source and local files

Run Git from the project root and check the exact staged changes before committing:

```powershell
git rev-parse --show-toplevel
git status --short
git diff --cached --stat
git diff --cached --check
```

Commit source, build/setup scripts, tests, workflows, documentation and license notices. `.gitignore` excludes Windows build output, installers, runtime DLLs, driver packages, private signing material, personal iPad provisioning, Python caches, local environment files and assistant state. Never force-add those files to bypass an ignore rule.

Keep work for a later release in a separate branch or working tree. Build release assets from the intended source commit so local experiments cannot enter a setup by accident.

## Setup assets

Build the Windows app and display service in Release x64, then follow [SETUP.md](SETUP.md) to build the signed-driver setup. Upload these generated files from `dist/` to a GitHub Release:

- `WinSideUSB-<version>-Setup.exe`
- `WinSideUSB-<version>-Setup.exe.sha256`
- `WinSideUSB-<version>-Setup.exe.manifest.json`

The ready-signed driver and the WinSideUSB app/setup have separate signature status. Record the actual status in release notes. Do not publish personal Apple-signed IPAs or provisioning profiles.

Use a version tag pointing to the exact source commit. GitHub automatically supplies source ZIP/TAR archives; these archives do not contain a built installer. Link the release Assets from the README.

## Checks

[Source checks](../.github/workflows/checks.yml) runs Windows native helpers, installer transactions, EDID checks and Swift production helpers on pushes and pull requests. Full Windows builds additionally need the external NVENC header and 25 USB runtime files described in [THIRD_PARTY.md](THIRD_PARTY.md); CI does not vendor or redistribute these dependencies.

Use [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for real-machine verification and third-party distribution requirements. Automated helper tests do not substitute for clean-PC setup, unplug/reconnect and physical iPad display checks.
