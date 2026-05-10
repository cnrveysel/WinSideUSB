# Contributing

Thanks for checking out WinSideUSB.

This is an experimental Windows-to-iPad USB display streamer. Contributions are welcome, but please keep changes focused and practical.

## Before Opening a PR

- Keep generated binaries out of git.
- Do not commit driver certificates, private keys, SDK headers, logs, dumps, or telemetry CSVs.
- Test Windows app changes with `Release | x64` when possible.
- Document driver, transport, or iPad client behavior changes in `README.md` or `docs/`.
- Keep third-party runtime binaries out of source commits unless licensing has been reviewed.

## Good First Areas

- Documentation and setup clarity.
- Better build scripts.
- iPad client polish.
- Telemetry and diagnostics.
- Encoder/transport experiments with measured before/after logs.

## Development Notes

The Windows app currently expects the NVIDIA Video Codec SDK header through `NVENC_INCLUDE_DIR`.

The app can embed libimobiledevice runtime files from `x64/Release/` during local builds, but these binaries are intentionally not tracked in git.
