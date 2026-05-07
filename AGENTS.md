# AGENTS.md

Guidance for coding agents working in this repository.

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

## Architecture

- `DuetCloneNew/WinSideUSB.cpp`: Windows app, UI, iPad detection, IDD control, capture, encode, and streaming.
- `IddSampleDriver/`: Windows Indirect Display Driver used to create/remove the virtual display.
- `DuetCloneNew/swiftclientcode.swift`: Swift iPad client source.

Runtime path:

1. App launches `iproxy.exe` to forward the USB tunnel.
2. App signals the IDD driver to connect the virtual display.
3. Desktop Duplication captures the virtual display from D3D11.
4. Native NVENC encodes H.264 from GPU textures.
5. Packet sender streams length-prefixed H.264 chunks to the iPad client.

Keep build artifacts, PDBs, certificates, logs, and bundled third-party binaries out of source commits.
