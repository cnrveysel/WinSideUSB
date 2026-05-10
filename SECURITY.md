# Security Policy

WinSideUSB is experimental software that includes a Windows virtual display driver.

## Supported Versions

This repository does not have stable releases yet. Security fixes are handled on the current development branch until a release process exists.

## Driver Safety

- Do not install driver packages from people you do not trust.
- Do not publish private signing keys, test certificates, or `.pfx` files.
- Development driver installs may require Windows test-signing mode and Secure Boot changes.
- Anti-cheat and protected software may refuse to run while Windows test-signing mode is enabled.
- Public driver distribution should use proper Microsoft driver signing.

## Reporting Issues

For now, open a GitHub issue with:

- Windows version
- GPU model and driver version
- iPad model and iPadOS version
- whether test signing is enabled
- relevant logs from `%LOCALAPPDATA%\WinSideUSB\`

Do not attach private keys, certificates, crash dumps with personal data, or full device identifiers unless you have reviewed them first.
