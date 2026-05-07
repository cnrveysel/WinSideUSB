# Third-Party Runtime Notes

WinSideUSB depends on several third-party components at build or runtime.

This document is a packaging reminder, not a complete license inventory.

## NVIDIA Video Codec SDK

The Windows app includes `nvEncodeAPI.h` from the NVIDIA Video Codec SDK.

Do not commit NVIDIA SDK headers unless the license permits it. Instead set:

```powershell
$env:NVENC_INCLUDE_DIR = "C:\Path\To\Video_Codec_SDK\Interface"
```

## libimobiledevice / iproxy

The app uses `iproxy.exe` and libimobiledevice DLLs to forward a local Windows TCP port to the iPad over USB.

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

Do not commit these binaries unless you intentionally vendor them and include all required license notices.

## Microsoft IDD Sample Code

The virtual display driver is based on the Microsoft Indirect Display Driver sample structure. Keep its original copyright notices.

## Release Packaging

If you publish a GitHub Release zip, include:

- `WinSideUSB.exe`
- required libimobiledevice runtime files or an installer step
- the driver package only if it has a distributable signature
- third-party notices for every bundled binary

For a source-only repo, keep third-party binaries out of git and document how to provide them locally.
