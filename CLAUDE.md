# CLAUDE.md

Guidance for Claude Code or similar coding agents working in this repository.

## Build

Set the NVENC header path, then build the app:

```bat
set NVENC_INCLUDE_DIR=C:\Path\To\Video_Codec_SDK\Interface
msbuild WinSideUSB.sln /p:Configuration=Release /p:Platform=x64
```

Build the driver:

```bat
msbuild IddSampleDriver.sln /p:Configuration=Release /p:Platform=x64
```

## Notes

- Main app source: `DuetCloneNew/WinSideUSB.cpp`
- IDD driver source: `IddSampleDriver/`
- iPad Swift client source: `DuetCloneNew/swiftclientcode.swift`
- Do not commit generated binaries, PDBs, test certificates, logs, CSVs, or local editor state.
