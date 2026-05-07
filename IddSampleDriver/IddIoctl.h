#pragma once

// Shared between IddSampleDriver and WinSideUSB.
// Both projects must include this file so the IOCTL code and struct stay in sync.

// Device interface GUID — app uses this to find and open the driver.
// {9D4D8B5E-A9C9-4E96-9C5B-1B5A6E7D8F9A}
static const GUID GUID_DEVINTERFACE_IDD_CUSTOM =
    { 0x9d4d8b5e, 0xa9c9, 0x4e96, { 0x9c, 0x5b, 0x1b, 0x5a, 0x6e, 0x7d, 0x8f, 0x9a } };

// IOCTL: app → driver, set virtual display resolution and refresh rate.
#define IOCTL_IDD_SET_RESOLUTION \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

// IOCTL: app -> driver, report the virtual monitor as connected.
// Input buffer is optional; when present it is an IddResolutionRequest.
#define IOCTL_IDD_CONNECT_MONITOR \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

// IOCTL: app -> driver, report the virtual monitor as disconnected.
#define IOCTL_IDD_DISCONNECT_MONITOR \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)

#pragma pack(push, 1)
struct IddResolutionRequest
{
    UINT32 Width;
    UINT32 Height;
    UINT32 RefreshRateHz;
};
#pragma pack(pop)
