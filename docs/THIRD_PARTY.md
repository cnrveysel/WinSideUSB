# Third-Party Runtime Notes

WinSideUSB depends on several third-party components at build or runtime.

This document is a packaging reminder, not a complete license inventory.

Original WinSideUSB project code is MIT licensed, but third-party components keep their own licenses.

## NVIDIA Video Codec SDK

The Windows app includes `nvEncodeAPI.h` from the NVIDIA Video Codec SDK.

Do not commit NVIDIA SDK headers unless the license permits it. Instead set:

```powershell
$env:NVENC_INCLUDE_DIR = "C:\Path\To\Video_Codec_SDK\Interface"
```

## libimobiledevice / iproxy

The app uses the third-party `iproxy.exe` tool and libimobiledevice DLLs to forward a local Windows TCP port to the iPad over USB.

Attribution:

- libimobiledevice project: <https://libimobiledevice.org/>
- libimobiledevice repository: <https://github.com/libimobiledevice/libimobiledevice>
- libusbmuxd repository, which provides `iproxy`: <https://github.com/libimobiledevice/libusbmuxd>

License notes:

- libimobiledevice is LGPL-2.1.
- libusbmuxd is LGPL-2.1.
- `iproxy` is GPL-2.0.

If a Windows release embeds or bundles `iproxy.exe`, treat that release as GPL-runtime packaging work: include the GPL-2.0 text, preserve notices, and provide the corresponding upstream source/access required by the license. If this is not desirable, keep the public repository source-only and require users to provide the tools locally.

The repository includes local copies of `licenses/GPL-2.0.txt` and `licenses/LGPL-2.1.txt` so developer-preview zips can include the relevant license texts alongside the bundled runtime.

The current app resource file expects these files under `x64/Release/` at build time:

```text
iproxy.exe
ideviceinfo.exe
bz2.dll
getopt.dll
iconv-2.dll
ideviceactivation.dll
imobiledevice.dll
imobiledevice-net-lighthouse.dll
irecovery.dll
libcrypto-1_1-x64.dll
libcurl.dll
libssl-1_1-x64.dll
libusb0.dll
libusb-1.0.dll
libxml2.dll
lzma.dll
pcre.dll
pcreposix.dll
plist.dll
pthreadVC3.dll
readline.dll
usbmuxd.dll
vcruntime140.dll
zip.dll
zlib1.dll
```

Do not commit these binaries unless you intentionally vendor them and include all required license notices. If a release zip or installer includes them, ship the upstream license texts and a third-party notice alongside the build.

## Microsoft IDD Sample Code

The default Signed setup uses the unchanged ready-signed [Virtual Display Driver 25.7.23](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.7.23) x64 package instead of building our separate development driver. This upstream package is MIT licensed; preserve `licenses/Virtual-Display-Driver-MIT.txt` and the attribution in `NOTICE.md`. Packaging verifies the exact pinned INF/DLL/CAT and their trusted signatures/catalog membership. Configuration XML is generated independently and does not change signed driver bytes.

The virtual display driver is based on the Microsoft Indirect Display Driver sample structure. Keep its original copyright notices.

The Microsoft Windows Driver Samples repository is licensed under the Microsoft Public License (MS-PL). A copy is included at `licenses/Microsoft-Public-License.txt`.

## Release Packaging

### Apple USB prerequisite acquisition

Windows setup 0.3.11 can download Apple's unmodified x64 iTunes installer directly from `secure-appldnld.apple.com` if Apple USB support is missing. The prerequisite task identifies iTunes and acceptance of Apple's terms; setup links to [Apple's software license agreements](https://www.apple.com/legal/sla/). This installer is not embedded or redistributed in the WinSideUSB EXE. It is downloaded into the user's setup temporary directory, checked against a pinned SHA-256 and a trusted Apple publisher signature, and run with `/quiet /norestart`. Existing usable Apple USB support is reused; shared Apple software remains after WinSideUSB uninstall.

The reviewed version, x64 URL and SHA-256 are in `scripts/AppleUsbPrerequisite.json`, sourced from [Microsoft's Apple.iTunes 12.13.12.3 manifest](https://github.com/microsoft/winget-pkgs/blob/master/manifests/a/Apple/iTunes/12.13.12.3/Apple.iTunes.installer.yaml). Updating that file requires reviewing a new official download, its exact hash, signature and installer behavior. Do not silently follow a moving latest-version URL in the released setup.

If you publish a GitHub Release zip, include:

- `WinSideUSB.exe`
- required libimobiledevice runtime files or an installer step
- the driver package only if it has a distributable signature
- third-party notices for every bundled binary

For a source-only repo, keep third-party binaries out of git and document how to provide them locally.
