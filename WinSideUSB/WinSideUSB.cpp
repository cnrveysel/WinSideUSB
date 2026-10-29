// WinSideUSB (NVENC zero-copy GPU path — GUI edition)
// Link: ws2_32.lib d3d11.lib dxgi.lib mfplat.lib mfuuid.lib wmcodecdspuuid.lib mf.lib winmm.lib shell32.lib

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <winsock2.h>
#include <ws2tcpip.h>
#include <Windows.h>
#include <winioctl.h>
#include <shellapi.h>
#include <dbt.h>
#include <setupapi.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <objidl.h>
#include <gdiplus.h>
#include <vector>
#include <string>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <ctime>
#include <deque>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <thread>
#include <atomic>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <codecapi.h>
#include <timeapi.h>
#include <nvEncodeAPI.h>
#include "resource.h"
#include "..\\IddSampleDriver\\IddIoctl.h"
#include "SignedDisplayClient.h"
#include "SignedDisplayOutput.h"
#include "FramePacing.h"
#include "DesktopCursor.h"
#include "DisplayModes.h"

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "wmcodecdspuuid.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "uxtheme.lib")
#pragma comment(lib, "gdiplus.lib")

// ── Messages ─────────────────────────────────────────────────────────
#define WM_STREAM_STATUS  (WM_APP + 1)   // WPARAM = StreamStatus
#define WM_STREAM_FPS     (WM_APP + 2)   // WPARAM = fps * 10 (fixed-point)
#define WM_TRAY_MSG       (WM_APP + 3)
#define WM_DETECT_DONE    (WM_APP + 4)   // detection finished, update UI

#define WSUSB_LOCAL_PORT   8081
static const int WSUSB_DEVICE_PORTS[] = { 17326, 17325, 17324, 17323, 17322, 17321 };

enum StreamStatus : WPARAM {
    SS_CONNECTING,
    SS_WAITING_IPAD_APP,
    SS_CONNECTED,
    SS_DISCONNECTED,
    SS_ENCODER_GPU,
    SS_ENCODER_HW,
    SS_ENCODER_SW,
    SS_PAUSED,
};

// ── Tray / control IDs ───────────────────────────────────────────────
#define TRAY_ID            1
#define IDM_SHOW        1001
#define IDM_EXIT        1002
#define IDC_LBL_IPAD     101
#define IDC_BTN_DETECT   102
#define IDC_COMBO_MODE   103
#define IDC_LBL_STATUS   104
#define IDC_LBL_ENCODER  105
#define IDC_LBL_FPS      106
#define IDC_BTN_ACTION   107
#define IDC_TITLE        108
#define IDC_SUBTITLE     109
#define IDC_LABEL_IPAD   110
#define IDC_LABEL_MODE   111
#define IDC_LABEL_STATUS 112
#define IDC_LABEL_ENCODER 113
#define IDC_LABEL_FPS    114
#define IDC_HINT         115
#define IDC_BTN_LOGS     116

// ── iPad device database ─────────────────────────────────────────────
struct iPadDef { const char* productType; const wchar_t* displayName; int w, h, maxFPS; };

static const iPadDef g_ipadDefs[] = {
    // iPad Pro 13" / 12.9"
    { "iPad17,3",  L"iPad Pro 13\" M5 (2025)",          2752, 2064, 120 },
    { "iPad17,4",  L"iPad Pro 13\" M5 (2025)",          2752, 2064, 120 },
    { "iPad16,5",  L"iPad Pro 13\" M4 (2024)",          2752, 2064, 120 },
    { "iPad16,6",  L"iPad Pro 13\" M4 (2024)",          2752, 2064, 120 },
    { "iPad8,5",   L"iPad Pro 12.9\" 3rd gen (2018)",  2732, 2048, 120 },
    { "iPad8,6",   L"iPad Pro 12.9\" 3rd gen (2018)",  2732, 2048, 120 },
    { "iPad8,7",   L"iPad Pro 12.9\" 3rd gen (2018)",  2732, 2048, 120 },
    { "iPad8,8",   L"iPad Pro 12.9\" 3rd gen (2018)",  2732, 2048, 120 },
    { "iPad8,11",  L"iPad Pro 12.9\" 4th gen (2020)",  2732, 2048, 120 },
    { "iPad8,12",  L"iPad Pro 12.9\" 4th gen (2020)",  2732, 2048, 120 },
    { "iPad13,8",  L"iPad Pro 12.9\" 5th gen M1 (2021)", 2732, 2048, 120 },
    { "iPad13,9",  L"iPad Pro 12.9\" 5th gen M1 (2021)", 2732, 2048, 120 },
    { "iPad13,10", L"iPad Pro 12.9\" 5th gen M1 (2021)", 2732, 2048, 120 },
    { "iPad13,11", L"iPad Pro 12.9\" 5th gen M1 (2021)", 2732, 2048, 120 },
    { "iPad14,5",  L"iPad Pro 12.9\" 6th gen M2 (2022)", 2732, 2048, 120 },
    { "iPad14,6",  L"iPad Pro 12.9\" 6th gen M2 (2022)", 2732, 2048, 120 },
    { "iPad7,1",   L"iPad Pro 12.9\" 2nd gen (2017)",  2732, 2048, 120 },
    { "iPad7,2",   L"iPad Pro 12.9\" 2nd gen (2017)",  2732, 2048, 120 },
    { "iPad6,7",   L"iPad Pro 12.9\" 1st gen (2015)",  2732, 2048,  60 },
    { "iPad6,8",   L"iPad Pro 12.9\" 1st gen (2015)",  2732, 2048,  60 },

    // iPad Pro 11"
    { "iPad17,1",  L"iPad Pro 11\" M5 (2025)",          2420, 1668, 120 },
    { "iPad17,2",  L"iPad Pro 11\" M5 (2025)",          2420, 1668, 120 },
    { "iPad16,3",  L"iPad Pro 11\" M4 (2024)",          2420, 1668, 120 },
    { "iPad16,4",  L"iPad Pro 11\" M4 (2024)",          2420, 1668, 120 },
    { "iPad8,1",   L"iPad Pro 11\" 1st gen (2018)",    2388, 1668, 120 },
    { "iPad8,2",   L"iPad Pro 11\" 1st gen (2018)",    2388, 1668, 120 },
    { "iPad8,3",   L"iPad Pro 11\" 1st gen (2018)",    2388, 1668, 120 },
    { "iPad8,4",   L"iPad Pro 11\" 1st gen (2018)",    2388, 1668, 120 },
    { "iPad8,9",   L"iPad Pro 11\" 2nd gen (2020)",    2388, 1668, 120 },
    { "iPad8,10",  L"iPad Pro 11\" 2nd gen (2020)",    2388, 1668, 120 },
    { "iPad13,4",  L"iPad Pro 11\" 3rd gen M1 (2021)", 2388, 1668, 120 },
    { "iPad13,5",  L"iPad Pro 11\" 3rd gen M1 (2021)", 2388, 1668, 120 },
    { "iPad13,6",  L"iPad Pro 11\" 3rd gen M1 (2021)", 2388, 1668, 120 },
    { "iPad13,7",  L"iPad Pro 11\" 3rd gen M1 (2021)", 2388, 1668, 120 },
    { "iPad14,3",  L"iPad Pro 11\" 4th gen M2 (2022)", 2388, 1668, 120 },
    { "iPad14,4",  L"iPad Pro 11\" 4th gen M2 (2022)", 2388, 1668, 120 },
    { "iPad7,3",   L"iPad Pro 10.5\" (2017)",          2224, 1668, 120 },
    { "iPad7,4",   L"iPad Pro 10.5\" (2017)",          2224, 1668, 120 },
    { "iPad6,3",   L"iPad Pro 9.7\" (2016)",           2048, 1536,  60 },
    { "iPad6,4",   L"iPad Pro 9.7\" (2016)",           2048, 1536,  60 },

    // iPad Air
    { "iPad16,8",  L"iPad Air 11\" M4 (2026)",         2360, 1640,  60 },
    { "iPad16,9",  L"iPad Air 11\" M4 (2026)",         2360, 1640,  60 },
    { "iPad16,10", L"iPad Air 13\" M4 (2026)",         2732, 2048,  60 },
    { "iPad16,11", L"iPad Air 13\" M4 (2026)",         2732, 2048,  60 },
    { "iPad15,3",  L"iPad Air 11\" M3 (2025)",         2360, 1640,  60 },
    { "iPad15,4",  L"iPad Air 11\" M3 (2025)",         2360, 1640,  60 },
    { "iPad15,5",  L"iPad Air 13\" M3 (2025)",         2732, 2048,  60 },
    { "iPad15,6",  L"iPad Air 13\" M3 (2025)",         2732, 2048,  60 },
    { "iPad13,1",  L"iPad Air 4th gen (2020)",         2360, 1640,  60 },
    { "iPad13,2",  L"iPad Air 4th gen (2020)",         2360, 1640,  60 },
    { "iPad13,16", L"iPad Air 5th gen M1 (2022)",      2360, 1640,  60 },
    { "iPad13,17", L"iPad Air 5th gen M1 (2022)",      2360, 1640,  60 },
    { "iPad14,8",  L"iPad Air 11\" M2 (2024)",         2360, 1640,  60 },
    { "iPad14,9",  L"iPad Air 11\" M2 (2024)",         2360, 1640,  60 },
    { "iPad14,10", L"iPad Air 13\" M2 (2024)",         2732, 2048,  60 },
    { "iPad14,11", L"iPad Air 13\" M2 (2024)",         2732, 2048,  60 },
    { "iPad11,3",  L"iPad Air 3rd gen (2019)",         2224, 1668,  60 },
    { "iPad11,4",  L"iPad Air 3rd gen (2019)",         2224, 1668,  60 },
    { "iPad5,3",   L"iPad Air 2 (2014)",               2048, 1536,  60 },
    { "iPad5,4",   L"iPad Air 2 (2014)",               2048, 1536,  60 },
    { "iPad4,1",   L"iPad Air (2013)",                 2048, 1536,  60 },
    { "iPad4,2",   L"iPad Air (2013)",                 2048, 1536,  60 },
    { "iPad4,3",   L"iPad Air (2013)",                 2048, 1536,  60 },

    // iPad mini
    { "iPad11,1",  L"iPad mini 5th gen (2019)",        2048, 1536,  60 },
    { "iPad11,2",  L"iPad mini 5th gen (2019)",        2048, 1536,  60 },
    { "iPad14,1",  L"iPad mini 6th gen (2021)",        2266, 1488,  60 },
    { "iPad14,2",  L"iPad mini 6th gen (2021)",        2266, 1488,  60 },
    { "iPad16,1",  L"iPad mini 7th gen (2024)",        2266, 1488,  60 },
    { "iPad16,2",  L"iPad mini 7th gen (2024)",        2266, 1488,  60 },
    { "iPad5,1",   L"iPad mini 4 (2015)",              2048, 1536,  60 },
    { "iPad5,2",   L"iPad mini 4 (2015)",              2048, 1536,  60 },
    { "iPad4,7",   L"iPad mini 3 (2014)",              2048, 1536,  60 },
    { "iPad4,8",   L"iPad mini 3 (2014)",              2048, 1536,  60 },
    { "iPad4,9",   L"iPad mini 3 (2014)",              2048, 1536,  60 },
    { "iPad4,4",   L"iPad mini 2 (2013)",              2048, 1536,  60 },
    { "iPad4,5",   L"iPad mini 2 (2013)",              2048, 1536,  60 },
    { "iPad4,6",   L"iPad mini 2 (2013)",              2048, 1536,  60 },
    { "iPad2,5",   L"iPad mini (2012)",                1024,  768,  60 },
    { "iPad2,6",   L"iPad mini (2012)",                1024,  768,  60 },
    { "iPad2,7",   L"iPad mini (2012)",                1024,  768,  60 },

    // iPad (standard)
    { "iPad15,7",  L"iPad (A16, 2025)",                2360, 1640,  60 },
    { "iPad15,8",  L"iPad (A16, 2025)",                2360, 1640,  60 },
    { "iPad11,6",  L"iPad 8th gen (2020)",             2160, 1620,  60 },
    { "iPad11,7",  L"iPad 8th gen (2020)",             2160, 1620,  60 },
    { "iPad12,1",  L"iPad 9th gen (2021)",             2160, 1620,  60 },
    { "iPad12,2",  L"iPad 9th gen (2021)",             2160, 1620,  60 },
    { "iPad13,18", L"iPad 10th gen (2022)",            2360, 1640,  60 },
    { "iPad13,19", L"iPad 10th gen (2022)",            2360, 1640,  60 },
    { "iPad7,11",  L"iPad 7th gen (2019)",             2160, 1620,  60 },
    { "iPad7,12",  L"iPad 7th gen (2019)",             2160, 1620,  60 },
    { "iPad7,5",   L"iPad 6th gen (2018)",             2048, 1536,  60 },
    { "iPad7,6",   L"iPad 6th gen (2018)",             2048, 1536,  60 },
    { "iPad6,11",  L"iPad 5th gen (2017)",             2048, 1536,  60 },
    { "iPad6,12",  L"iPad 5th gen (2017)",             2048, 1536,  60 },
    { "iPad3,4",   L"iPad 4th gen (2012)",             2048, 1536,  60 },
    { "iPad3,5",   L"iPad 4th gen (2012)",             2048, 1536,  60 },
    { "iPad3,6",   L"iPad 4th gen (2012)",             2048, 1536,  60 },
    { "iPad3,1",   L"iPad 3rd gen (2012)",             2048, 1536,  60 },
    { "iPad3,2",   L"iPad 3rd gen (2012)",             2048, 1536,  60 },
    { "iPad3,3",   L"iPad 3rd gen (2012)",             2048, 1536,  60 },
    { "iPad2,1",   L"iPad 2 (2011)",                   1024,  768,  60 },
    { "iPad2,2",   L"iPad 2 (2011)",                   1024,  768,  60 },
    { "iPad2,3",   L"iPad 2 (2011)",                   1024,  768,  60 },
    { "iPad2,4",   L"iPad 2 (2011)",                   1024,  768,  60 },
    { "iPad1,1",   L"iPad (2010)",                     1024,  768,  60 },
};
static const int IPAD_DEF_COUNT = (int)(sizeof(g_ipadDefs) / sizeof(g_ipadDefs[0]));

using ModeOption = winsideusb::ModeOption;
static ModeOption g_modes[winsideusb::MaxDisplayModes];
static int        g_modeCount = 0;

static void AddModeOption(int w, int h, int fps,
    winsideusb::DisplayProfile profile = winsideusb::DisplayProfile::Fallback) {
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1) || (fps != 60 && fps != 120)) return;
    for (int i = 0; i < g_modeCount; i++) {
        if (g_modes[i].w == w && g_modes[i].h == h && g_modes[i].fps == fps)
            return;
    }
    if (g_modeCount < (int)(sizeof(g_modes) / sizeof(g_modes[0])))
        g_modes[g_modeCount++] = { w, h, fps, profile };
}

// ── Globals ──────────────────────────────────────────────────────────
static HWND              g_hwnd = nullptr;
static std::atomic<bool> g_stop{ false };
static NOTIFYICONDATA    g_nid{};
static bool              g_trayActive = false;
static std::thread       g_streamThread;
static std::atomic<bool> g_streaming{ false };
static int               g_targetW = 2732;
static int               g_targetH = 2048;
static std::atomic<int>  g_targetFPS{ 120 };
static int               g_nativeW = 0;
static int               g_nativeH = 0;
static std::atomic<bool> g_detecting{ false };
static std::atomic<bool> g_virtualDisplayAttached{ false };
static winsideusb::SignedDisplayClient g_displayClient;
static std::wstring      g_captureDisplayName;
static std::string       g_detectedUdid;
static std::string       g_detectedProductType;
static std::atomic<bool> g_closing{ false };
static std::thread       g_detectThread;
static bool              g_streamCompletionPending = false;
static bool              g_autoStartSuppressed = false;
static bool              g_detectionSameDevice = false;
static int               g_detectionMisses = 0;
static ULONGLONG         g_nextAutoAttempt = 0;
static ULONGLONG         g_nextPresenceCheck = 0;
static std::atomic<bool> g_deviceChangePending{ false };
static std::mutex        g_streamErrorMutex;
static std::wstring      g_streamError;

static std::wstring ModeLabel(const ModeOption& mode) {
    const wchar_t* profile = L"Fallback";
    switch (mode.profile) {
    case winsideusb::DisplayProfile::Native: profile = L"Native"; break;
    case winsideusb::DisplayProfile::Balanced: profile = L"Balanced"; break;
    case winsideusb::DisplayProfile::LaptopSize: profile = L"Laptop-size"; break;
    default: break;
    }
    return std::wstring(profile) + L" \u00b7 " + std::to_wstring(mode.w) + L" \u00d7 " +
        std::to_wstring(mode.h) + L" \u00b7 " + std::to_wstring(mode.fps) + L" Hz";
}

static const wchar_t* ModeHint(const ModeOption& mode) {
    switch (mode.profile) {
    case winsideusb::DisplayProfile::Native:
        return L"Native panel detail. Windows scaling is unchanged.";
    case winsideusb::DisplayProfile::Balanced:
        return L"Try 150% Windows scale for the iPad. Less detail than Native.";
    case winsideusb::DisplayProfile::LaptopSize:
        return L"Use 100% Windows scale for the iPad for laptop-sized windows. Less detail.";
    default:
        return L"Unknown iPad: choose a mode and check Windows display scaling.";
    }
}

// Own per-model preference only. No Windows desktop/DPI settings are written.
// The single versioned value avoids partially saved width/height/FPS tuples.
struct StoredDisplayMode { DWORD version, width, height, fps; };
static_assert(sizeof(StoredDisplayMode) == 16, "Display mode preference format changed");

static std::wstring ModePreferenceKey(const std::string& productType) {
    if (productType.empty() || productType.size() > 64) return {};
    std::wstring key = L"Software\\WinSideUSB\\DisplayModes\\";
    for (char character : productType) {
        if (!((character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') || character == ',' || character == '-' || character == '_'))
            return {};
        key += static_cast<wchar_t>(character);
    }
    return key;
}

static bool LoadModePreference(const std::string& productType, ModeOption& mode) {
    const std::wstring key = ModePreferenceKey(productType);
    if (key.empty()) return false;
    StoredDisplayMode stored{};
    DWORD size = static_cast<DWORD>(sizeof(stored));
    if (RegGetValueW(HKEY_CURRENT_USER, key.c_str(), L"SelectedMode", RRF_RT_REG_BINARY,
        nullptr, &stored, &size) != ERROR_SUCCESS || size != sizeof(stored) || stored.version != 1 ||
        !stored.width || !stored.height || stored.width > 16384 || stored.height > 16384 ||
        (stored.fps != 60 && stored.fps != 120)) return false;
    mode = {static_cast<int>(stored.width), static_cast<int>(stored.height), static_cast<int>(stored.fps)};
    return true;
}

static void SaveModePreference(const ModeOption& mode) {
    const std::wstring key = ModePreferenceKey(g_detectedProductType);
    if (key.empty()) return;
    HKEY opened = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE, nullptr, &opened, nullptr) != ERROR_SUCCESS) return;
    const StoredDisplayMode stored{1, static_cast<DWORD>(mode.w), static_cast<DWORD>(mode.h),
        static_cast<DWORD>(mode.fps)};
    RegSetValueExW(opened, L"SelectedMode", 0, REG_BINARY,
        reinterpret_cast<const BYTE*>(&stored), static_cast<DWORD>(sizeof(stored)));
    RegCloseKey(opened);
}

static int FindModeOption(const ModeOption& requested) {
    for (int index = 0; index < g_modeCount; ++index)
        if (winsideusb::SameMode(g_modes[index], requested)) return index;
    return -1;
}

static bool SelectModeOption(int selection, bool persist = true) {
    if (selection < 0 || selection >= g_modeCount || g_streaming.load() ||
        g_streamCompletionPending || g_closing.load()) return false;
    const ModeOption& mode = g_modes[selection];
    g_targetW = mode.w;
    g_targetH = mode.h;
    g_targetFPS = mode.fps;
    if (persist) SaveModePreference(mode);
    return true;
}

static void RestoreModeSelection(const ModeOption& previous, bool sameDevice) {
    int selection = sameDevice ? FindModeOption(previous) : -1;
    if (selection < 0) {
        ModeOption saved;
        if (LoadModePreference(g_detectedProductType, saved)) selection = FindModeOption(saved);
    }
    if (selection < 0 && g_modeCount > 0) selection = 0;
    SelectModeOption(selection, false);
}

static constexpr int COLOR_TEST_GOP_SECONDS = 5;
static constexpr int IDLE_HEARTBEAT_FPS = 4;

static const GUID MY_KFS = { 0x392d4a7b,0xca19,0x4873,{0x87,0x5f,0x99,0xa9,0x02,0x60,0x45,0x02} };
static const GUID MY_LL = { 0x9c57023c,0x7709,0x470d,{0x9d,0x52,0x1d,0x99,0x61,0x69,0x22,0x29} };

static inline uint8_t clampByte(int v) { return (v < 0) ? 0 : (v > 255) ? 255 : (uint8_t)v; }

static void SetCodecUI4(ICodecAPI* codec, const GUID& key, ULONG value) {
    VARIANT v; VariantInit(&v); v.vt = VT_UI4; v.ulVal = value;
    codec->SetValue(&key, &v);
    VariantClear(&v);
}

static void ApplyDesktopColorMetadata(IMFMediaType* mt) {
    if (!mt) return;
    mt->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    mt->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
    mt->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    mt->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_0_255);
}

static void ConfigureLowLatencyEncoder(IMFTransform* enc, UINT32 avgBitrate, UINT32 maxBitrate, int fps) {
    IMFAttributes* attrs = nullptr;
    if (SUCCEEDED(enc->GetAttributes(&attrs)) && attrs) {
        attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
        attrs->Release();
    }

    ICodecAPI* codec = nullptr;
    if (FAILED(enc->QueryInterface(__uuidof(ICodecAPI), (void**)&codec)) || !codec)
        return;

    UINT32 keyFrames = (UINT32)(fps * COLOR_TEST_GOP_SECONDS);
    if (keyFrames < 15) keyFrames = 15;

    SetCodecUI4(codec, CODECAPI_AVLowLatencyMode, TRUE);
    SetCodecUI4(codec, CODECAPI_AVEncCommonLowLatency, TRUE);
    SetCodecUI4(codec, CODECAPI_AVEncCommonRealTime, TRUE);
    SetCodecUI4(codec, CODECAPI_AVEncCommonAllowFrameDrops, TRUE);
    UINT32 vbvBytes = maxBitrate / 32;
    if (vbvBytes < 1024 * 1024) vbvBytes = 1024 * 1024;
    if (vbvBytes > 2 * 1024 * 1024) vbvBytes = 2 * 1024 * 1024;

    SetCodecUI4(codec, CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_LowDelayVBR);
    SetCodecUI4(codec, CODECAPI_AVEncCommonMeanBitRate, avgBitrate);
    SetCodecUI4(codec, CODECAPI_AVEncCommonMaxBitRate, maxBitrate);
    SetCodecUI4(codec, CODECAPI_AVEncCommonBufferSize, vbvBytes);
    SetCodecUI4(codec, CODECAPI_AVEncCommonQualityVsSpeed, 100);
    SetCodecUI4(codec, CODECAPI_AVEncMPVDefaultBPictureCount, 0);
    SetCodecUI4(codec, CODECAPI_AVEncVideoMaxNumRefFrame, 1);
    SetCodecUI4(codec, CODECAPI_AVEncMPVGOPOpen, FALSE);
    SetCodecUI4(codec, CODECAPI_AVEncMPVGOPSize, keyFrames);
    SetCodecUI4(codec, CODECAPI_AVEncMPVGOPSizeMin, keyFrames);
    SetCodecUI4(codec, CODECAPI_AVEncMPVGOPSizeMax, keyFrames);
    SetCodecUI4(codec, CODECAPI_AVEncVideoMaxKeyframeDistance, keyFrames);
    SetCodecUI4(codec, CODECAPI_AVEncMPVSceneDetection, eAVEncMPVSceneDetection_InsertIPicture);
    SetCodecUI4(codec, CODECAPI_AVEncNoInputCopy, TRUE);

    codec->Release();
}

static void ForceKeyFrame(IMFTransform* enc) {
    ICodecAPI* codec = nullptr;
    if (SUCCEEDED(enc->QueryInterface(__uuidof(ICodecAPI), (void**)&codec)) && codec) {
        SetCodecUI4(codec, CODECAPI_AVEncVideoForceKeyFrame, TRUE);
        codec->Release();
    }
}

static bool IsLargeDirtyFrame(IDXGIOutputDuplication* dupl, int w, int h) {
    UINT bytesNeeded = 0;
    HRESULT hr = dupl->GetFrameDirtyRects(0, nullptr, &bytesNeeded);
    if (hr != DXGI_ERROR_MORE_DATA || bytesNeeded == 0)
        return false;

    std::vector<RECT> rects((bytesNeeded + sizeof(RECT) - 1) / sizeof(RECT));
    if (FAILED(dupl->GetFrameDirtyRects((UINT)(rects.size() * sizeof(RECT)), rects.data(), &bytesNeeded)))
        return false;

    LONGLONG dirtyPixels = 0;
    UINT rectCount = bytesNeeded / sizeof(RECT);
    for (UINT i = 0; i < rectCount; i++) {
        LONG left = rects[i].left < 0 ? 0 : rects[i].left;
        LONG top = rects[i].top < 0 ? 0 : rects[i].top;
        LONG right = rects[i].right > w ? w : rects[i].right;
        LONG bottom = rects[i].bottom > h ? h : rects[i].bottom;
        if (right > left && bottom > top)
            dirtyPixels += (LONGLONG)(right - left) * (bottom - top);
    }

    return dirtyPixels > ((LONGLONG)w * h * 55) / 100;
}

// ═══════════════════════════════════════════════════════════════════
// UI helpers
// ═══════════════════════════════════════════════════════════════════

static void PostStatus(StreamStatus s) { if (g_hwnd) PostMessage(g_hwnd, WM_STREAM_STATUS, s, 0); }
static void PostFPS(double fps) { if (g_hwnd) PostMessage(g_hwnd, WM_STREAM_FPS, (WPARAM)(fps * 10.0 + 0.5), 0); }
static void DiagLog(const std::string& message);
static std::string RunIdeviceinfo(const char* key, const std::string& udid = "", bool simple = false);

static void SetStreamError(const std::wstring& message) {
    std::lock_guard<std::mutex> lock(g_streamErrorMutex);
    g_streamError = message;
}

static std::wstring GetStreamError() {
    std::lock_guard<std::mutex> lock(g_streamErrorMutex);
    return g_streamError;
}

static void RestoreFailedDisplayActivation(const winsideusb::DisplayStateSnapshot& original,
    const std::wstring& instanceId) {
    std::wstring error;
    if (winsideusb::ValidatePhysicalDisplayState(original, instanceId, error)) return;
    if (!winsideusb::RestoreDisplayState(original, error)) {
        int count = WideCharToMultiByte(CP_UTF8, 0, error.c_str(), -1, nullptr, 0, nullptr, nullptr);
        std::vector<char> text(count > 0 ? count : 1, 0);
        if (count > 0) WideCharToMultiByte(CP_UTF8, 0, error.c_str(), -1, text.data(), count, nullptr, nullptr);
        DiagLog(std::string("original display topology could not be restored: ") + text.data());
        SetStreamError(L"Windows could not restore the original display settings. Check Windows Display settings and view logs.");
    }
}

static HANDLE OpenIddControlDevice() {
    HDEVINFO devs = SetupDiGetClassDevsW(
        &GUID_DEVINTERFACE_IDD_CUSTOM, nullptr, nullptr,
        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devs == INVALID_HANDLE_VALUE) return INVALID_HANDLE_VALUE;

    HANDLE result = INVALID_HANDLE_VALUE;
    for (DWORD i = 0; result == INVALID_HANDLE_VALUE; ++i) {
        SP_DEVICE_INTERFACE_DATA ifData{};
        ifData.cbSize = sizeof(ifData);
        if (!SetupDiEnumDeviceInterfaces(devs, nullptr, &GUID_DEVINTERFACE_IDD_CUSTOM, i, &ifData)) {
            break;
        }

        DWORD needed = 0;
        SetupDiGetDeviceInterfaceDetailW(devs, &ifData, nullptr, 0, &needed, nullptr);
        if (needed == 0) continue;

        std::vector<BYTE> detailBytes(needed);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(detailBytes.data());
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
        if (!SetupDiGetDeviceInterfaceDetailW(devs, &ifData, detail, needed, nullptr, nullptr)) {
            continue;
        }

        result = CreateFileW(
            detail->DevicePath,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            nullptr);
    }

    SetupDiDestroyDeviceInfoList(devs);
    return result;
}

static bool SendIddIoctl(DWORD code, const void* input = nullptr, DWORD inputBytes = 0, DWORD* error = nullptr) {
    if (error) *error = ERROR_SUCCESS;

    HANDLE h = OpenIddControlDevice();
    if (h == INVALID_HANDLE_VALUE) {
        if (error) *error = GetLastError();
        return false;
    }

    DWORD returned = 0;
    BOOL ok = DeviceIoControl(
        h, code,
        const_cast<void*>(input), inputBytes,
        nullptr, 0,
        &returned,
        nullptr);
    if (!ok && error) *error = GetLastError();
    CloseHandle(h);
    return ok != FALSE;
}

static bool ConnectLegacyVirtualDisplay(int w, int h, int fps) {
    IddResolutionRequest req{};
    req.Width = (UINT32)w;
    req.Height = (UINT32)h;
    req.RefreshRateHz = (UINT32)fps;

    DWORD lastError = ERROR_SUCCESS;
    for (int attempt = 0; attempt < 8 && !g_stop; ++attempt) {
        DiagLog("ConnectVirtualDisplay attempt=" + std::to_string(attempt + 1));
        bool ok = SendIddIoctl(IOCTL_IDD_CONNECT_MONITOR, &req, sizeof(req), &lastError);
        if (ok) {
            g_virtualDisplayAttached.store(true);
            DiagLog("ConnectVirtualDisplay OK");
            return true;
        }
        DiagLog("ConnectVirtualDisplay failed err=" + std::to_string(lastError));
        std::this_thread::sleep_for(std::chrono::milliseconds(120 + attempt * 40));
    }

    wchar_t msg[160];
    swprintf_s(msg, L"WinSideUSB: virtual display connect failed, last error=%lu\n", lastError);
    OutputDebugStringW(msg);
    DiagLog("ConnectVirtualDisplay gave up last_error=" + std::to_string(lastError));
    g_virtualDisplayAttached.store(false);
    return false;
}

static bool SetVirtualDisplayMode(int w, int h, int fps) {
    // Signed-driver modes are applied once, after the actual iPad handshake.
    // The mode selector is disabled during streaming, as before.
    if (winsideusb::HasSignedDisplayConfiguration()) return !g_virtualDisplayAttached.load();
    IddResolutionRequest req{};
    req.Width = (UINT32)w;
    req.Height = (UINT32)h;
    req.RefreshRateHz = (UINT32)fps;

    return SendIddIoctl(IOCTL_IDD_SET_RESOLUTION, &req, sizeof(req));
}

static bool DisconnectVirtualDisplay() {
    if (winsideusb::HasSignedDisplayConfiguration()) {
        g_displayClient.Close();
        g_virtualDisplayAttached.store(false);
        return true;
    }
    bool ok = false;
    for (int attempt = 0; attempt < 3; ++attempt) {
        ok = SendIddIoctl(IOCTL_IDD_DISCONNECT_MONITOR);
        if (ok) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    g_virtualDisplayAttached.store(false);
    return ok;
}

static bool ConnectVirtualDisplay(int w, int h, int fps) {
    g_captureDisplayName.clear();
    if (!winsideusb::HasSignedDisplayConfiguration()) return ConnectLegacyVirtualDisplay(w, h, fps);

    if (!winsideusb::SignedDisplayClient::IsInstalledApp()) {
        DiagLog("signed display refused: open the installed WinSideUSB from the Start menu");
        SetStreamError(L"Open the installed WinSideUSB from the Start menu to start the display.");
        return false;
    }

    winsideusb::DisplayStateSnapshot original;
    std::wstring error, instanceId;
    if (!winsideusb::CaptureDisplayState(original, error)) {
        SetStreamError(L"Windows display settings could not be read. View logs for details.");
        return false;
    }
    DWORD serviceError = 0;
    if (!g_displayClient.Activate(instanceId, serviceError, g_stop)) {
        DiagLog("signed display activation failed err=" + std::to_string(serviceError));
        if (serviceError != ERROR_CANCELLED) SetStreamError(serviceError == ERROR_SUCCESS_REBOOT_REQUIRED ?
            L"Restart Windows to finish preparing the display driver." :
            L"The display service could not start. Run WinSideUSB setup again or view logs.");
        g_displayClient.Close();
        RestoreFailedDisplayActivation(original, instanceId);
        return false;
    }
    g_virtualDisplayAttached.store(true);
    HMONITOR monitor = nullptr;
    if (!winsideusb::ConfigureManagedDisplay(w, h, fps, instanceId,
        g_captureDisplayName, monitor, error, &original, &g_stop)) {
        int bytes = WideCharToMultiByte(CP_UTF8, 0, error.c_str(), -1, nullptr, 0, nullptr, nullptr);
        std::vector<char> detail(bytes > 0 ? bytes : 1, 0);
        if (bytes > 0) WideCharToMultiByte(CP_UTF8, 0, error.c_str(), -1, detail.data(), bytes, nullptr, nullptr);
        DiagLog(std::string("signed display mode failed: ") + detail.data());
        DisconnectVirtualDisplay();
        if (!g_stop.load()) SetStreamError(L"The selected pixel size and refresh rate could not be applied. View logs for details.");
        RestoreFailedDisplayActivation(original, instanceId);
        return false;
    }
    DiagLog("signed display configured " + std::to_string(w) + "x" + std::to_string(h) +
        "@" + std::to_string(fps) + "Hz");
    return !g_stop.load();
}

static bool RestoreCaptureSdr() {
    if (!winsideusb::HasSignedDisplayConfiguration()) return true;
    std::wstring instance, error;
    bool changed = false;
    if (!winsideusb::ReadDisplaySetting(L"ManagedDeviceInstanceId", instance) ||
        !winsideusb::EnsureManagedDisplaySdr(instance, changed, error, &g_stop)) {
        DiagLog("iPad SDR recovery failed");
        if (!g_stop.load()) SetStreamError(L"Windows could not turn HDR off for the iPad display. View logs for details.");
        return false;
    }
    if (changed) DiagLog("iPad HDR/Advanced Color disabled; SDR capture restored");
    return true;
}

struct StreamLogStats {
    std::ofstream file;
    LARGE_INTEGER freq{};
    LARGE_INTEGER start{};
    LARGE_INTEGER last{};
    int width = 0;
    int height = 0;
    int targetFPS = 0;
    double sourceHz = 0.0;
    int activeFPS = 0;
    std::string encoderName;

    ULONGLONG captureTimeouts = 0;
    ULONGLONG captureErrors = 0;
    ULONGLONG captured = 0;
    ULONGLONG throttled = 0;
    ULONGLONG accumulatedFrames = 0;
    ULONGLONG presentUpdates = 0;
    double presentDeltaMsTotal = 0.0;
    double presentDeltaMsMax = 0.0;
    ULONGLONG pointerOnlyFrames = 0;
    ULONGLONG panicEntries = 0;
    ULONGLONG panicFrames = 0;
    ULONGLONG largeDirty = 0;
    ULONGLONG forcedKeyframes = 0;
    ULONGLONG frameBuildFailures = 0;
    ULONGLONG inputFrames = 0;
    ULONGLONG inputNotAccepting = 0;
    ULONGLONG inputFailures = 0;
    ULONGLONG outputPackets = 0;
    ULONGLONG outputBytes = 0;
    ULONGLONG maxPacketBytes = 0;
    ULONGLONG sendSlow = 0;
    double sendMsTotal = 0.0;
    double sendMsMax = 0.0;
    ULONGLONG networkEnqueued = 0;
    ULONGLONG networkDropped = 0;
    ULONGLONG networkDroppedBytes = 0;
    ULONGLONG networkQueueMaxPackets = 0;
    ULONGLONG networkQueueMaxBytes = 0;

    ULONGLONG totalInputFrames = 0;
    ULONGLONG totalPackets = 0;
    ULONGLONG totalBytes = 0;
    winsideusb::StageTiming acquireTiming, copySubmitTiming, nvMapTiming, nvSubmitTiming, nvLockTiming, nativeEncodeTiming;
    double pacingLateMsMax = 0;

    void ResetInterval() {
        captureTimeouts = 0;
        captureErrors = 0;
        captured = 0;
        throttled = 0;
        accumulatedFrames = 0;
        presentUpdates = 0;
        presentDeltaMsTotal = 0.0;
        presentDeltaMsMax = 0.0;
        pointerOnlyFrames = 0;
        panicEntries = 0;
        panicFrames = 0;
        largeDirty = 0;
        forcedKeyframes = 0;
        frameBuildFailures = 0;
        inputFrames = 0;
        inputNotAccepting = 0;
        inputFailures = 0;
        outputPackets = 0;
        outputBytes = 0;
        maxPacketBytes = 0;
        sendSlow = 0;
        sendMsTotal = 0.0;
        sendMsMax = 0.0;
        networkEnqueued = 0;
        networkDropped = 0;
        networkDroppedBytes = 0;
        networkQueueMaxPackets = 0;
        networkQueueMaxBytes = 0;
        acquireTiming.Reset(); copySubmitTiming.Reset(); nvMapTiming.Reset();
        nvSubmitTiming.Reset(); nvLockTiming.Reset(); nativeEncodeTiming.Reset();
        pacingLateMsMax = 0;
    }
};

static std::string GetExeDirA() {
    char exePath[MAX_PATH] = {};
    GetModuleFileNameA(NULL, exePath, MAX_PATH);
    std::string exeDir(exePath);
    size_t sl = exeDir.find_last_of("\\/");
    if (sl != std::string::npos) exeDir = exeDir.substr(0, sl);
    else exeDir = ".";
    return exeDir;
}

static std::string GetLocalAppDirA() {
    char base[MAX_PATH] = {};
    DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", base, MAX_PATH);
    std::string dir = (n > 0 && n < MAX_PATH) ? std::string(base) + "\\WinSideUSB" : GetExeDirA() + "\\WinSideUSBData";
    CreateDirectoryA(dir.c_str(), NULL);
    return dir;
}

static void DiagLog(const std::string& message) {
    std::ofstream f(GetLocalAppDirA() + "\\winsideusb_diag.log", std::ios::app);
    if (!f) return;

    SYSTEMTIME st{};
    GetLocalTime(&st);
    f << std::setfill('0')
        << std::setw(2) << st.wHour << ":"
        << std::setw(2) << st.wMinute << ":"
        << std::setw(2) << st.wSecond << "."
        << std::setw(3) << st.wMilliseconds
        << " " << message << "\n";
}

static void StopIproxyProcess(PROCESS_INFORMATION& pi) {
    if (!pi.hProcess) return;
    DWORD exitCode = 0;
    if (GetExitCodeProcess(pi.hProcess, &exitCode))
        DiagLog("stopping iproxy current_exit_code=" + std::to_string(exitCode));
    TerminateProcess(pi.hProcess, 0);
    WaitForSingleObject(pi.hProcess, 1000);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    ZeroMemory(&pi, sizeof(pi));
}

struct BundledToolFile {
    int id;
    const char* name;
};

static const BundledToolFile kBundledToolFiles[] = {
    { IDR_TOOL_IPROXY, "iproxy.exe" },
    { IDR_TOOL_IDEVICEINFO, "ideviceinfo.exe" },
    { IDR_TOOL_BZ2_DLL, "bz2.dll" },
    { IDR_TOOL_GETOPT_DLL, "getopt.dll" },
    { IDR_TOOL_ICONV_DLL, "iconv-2.dll" },
    { IDR_TOOL_IDEVICEACTIVATION_DLL, "ideviceactivation.dll" },
    { IDR_TOOL_IMOBILEDEVICE_DLL, "imobiledevice.dll" },
    { IDR_TOOL_IMOBILEDEVICE_NET_DLL, "imobiledevice-net-lighthouse.dll" },
    { IDR_TOOL_IRECOVERY_DLL, "irecovery.dll" },
    { IDR_TOOL_LIBCRYPTO_DLL, "libcrypto-1_1-x64.dll" },
    { IDR_TOOL_LIBCURL_DLL, "libcurl.dll" },
    { IDR_TOOL_LIBSSL_DLL, "libssl-1_1-x64.dll" },
    { IDR_TOOL_LIBUSB0_DLL, "libusb0.dll" },
    { IDR_TOOL_LIBUSB10_DLL, "libusb-1.0.dll" },
    { IDR_TOOL_LIBXML2_DLL, "libxml2.dll" },
    { IDR_TOOL_LZMA_DLL, "lzma.dll" },
    { IDR_TOOL_PCRE_DLL, "pcre.dll" },
    { IDR_TOOL_PCREPOSIX_DLL, "pcreposix.dll" },
    { IDR_TOOL_PLIST_DLL, "plist.dll" },
    { IDR_TOOL_PTHREAD_DLL, "pthreadVC3.dll" },
    { IDR_TOOL_READLINE_DLL, "readline.dll" },
    { IDR_TOOL_USBMUXD_DLL, "usbmuxd.dll" },
    { IDR_TOOL_VCRUNTIME_DLL, "vcruntime140.dll" },
    { IDR_TOOL_ZIP_DLL, "zip.dll" },
    { IDR_TOOL_ZLIB_DLL, "zlib1.dll" },
};

static bool FileHasExactSizeA(const std::string& path, DWORD size) {
    WIN32_FILE_ATTRIBUTE_DATA info = {};
    if (!GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &info)) return false;
    ULONGLONG fileSize = (ULONGLONG(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    return fileSize == size;
}

static bool ExtractBundledResourceA(int id, const std::string& outPath) {
    HMODULE module = GetModuleHandleA(NULL);
    HRSRC res = FindResourceA(module, MAKEINTRESOURCEA(id), MAKEINTRESOURCEA(10));
    if (!res) return false;

    DWORD size = SizeofResource(module, res);
    if (size == 0) return false;
    if (FileHasExactSizeA(outPath, size)) return true;

    HGLOBAL loaded = LoadResource(module, res);
    if (!loaded) return false;

    const void* data = LockResource(loaded);
    if (!data) return false;

    std::ofstream f(outPath.c_str(), std::ios::binary | std::ios::trunc);
    if (!f.is_open()) return false;
    f.write(reinterpret_cast<const char*>(data), size);
    return f.good();
}

static bool gBundledToolsReady = false;
static std::string gBundledToolsDir;
static std::once_flag gBundledToolsOnce;

static void EnsureBundledToolsOnce() {
    std::string toolsDir = GetLocalAppDirA() + "\\tools";
    CreateDirectoryA(toolsDir.c_str(), NULL);

    bool ok = true;
    for (const auto& file : kBundledToolFiles) {
        std::string outPath = toolsDir + "\\" + file.name;
        if (!ExtractBundledResourceA(file.id, outPath)) {
            ok = false;
            break;
        }
    }

    if (ok) {
        gBundledToolsDir = toolsDir;
        gBundledToolsReady = true;
    }
}

static std::string EnsureBundledToolsDirA() {
    std::call_once(gBundledToolsOnce, EnsureBundledToolsOnce);
    return gBundledToolsReady ? gBundledToolsDir : GetExeDirA();
}

static std::string MakeTxLogPath() {
    std::string dir = GetLocalAppDirA();
    return dir + "\\winsideusb_tx_" + std::to_string((long long)std::time(nullptr)) + ".csv";
}

static void OpenStreamLog(StreamLogStats& stats, int w, int h, int fps, const char* encoderName, double sourceHz) {
    QueryPerformanceFrequency(&stats.freq);
    QueryPerformanceCounter(&stats.start);
    stats.last = stats.start;
    stats.width = w;
    stats.height = h;
    stats.targetFPS = fps;
    stats.sourceHz = sourceHz;
    stats.activeFPS = fps;
    stats.encoderName = encoderName;
    stats.ResetInterval();

    stats.file.open(MakeTxLogPath().c_str(), std::ios::out | std::ios::trunc);
    if (!stats.file.is_open()) return;

    stats.file << "t,width,height,target_fps,source_hz,encoder,"
        "capture_timeouts,capture_errors,captured,throttled,accumulated_frames,present_updates,present_delta_ms_avg,present_delta_ms_max,pointer_only,panic_entries,panic_frames,active_fps,large_dirty,forced_keyframes,"
        "frame_build_failures,input_frames,input_not_accepting,input_failures,"
        "output_packets,output_bytes,max_packet,send_slow,send_ms_total,send_ms_max,"
        "network_enqueued,network_dropped,network_dropped_bytes,network_queue_max_packets,network_queue_max_bytes,"
        "total_input_frames,total_packets,total_bytes,"
        "acquire_ms_avg,acquire_ms_max,copy_submit_ms_avg,nvenc_map_ms_avg,nvenc_submit_ms_avg,nvenc_lock_ms_avg,nvenc_total_ms_avg,nvenc_total_ms_max,pacing_late_ms_max\n";
    stats.file << "0.000," << w << "," << h << "," << fps << "," << std::fixed << std::setprecision(3) << sourceHz << "," << encoderName
        << ",0,0,0,0,0,0,0.000,0.000,0,0,0," << fps << ",0,0,0,0,0,0,0,0,0,0.000,0.000,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n";
}

static void LogStreamStatsIfNeeded(StreamLogStats& stats) {
    if (!stats.file.is_open()) return;

    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    LONGLONG elapsedCounts = now.QuadPart - stats.last.QuadPart;
    if (elapsedCounts < stats.freq.QuadPart) return;

    double t = (double)(now.QuadPart - stats.start.QuadPart) / (double)stats.freq.QuadPart;
    stats.file << std::fixed << std::setprecision(3)
        << t << ","
        << stats.width << ","
        << stats.height << ","
        << stats.targetFPS << ","
        << stats.sourceHz << ","
        << stats.encoderName << ","
        << stats.captureTimeouts << ","
        << stats.captureErrors << ","
        << stats.captured << ","
        << stats.throttled << ","
        << stats.accumulatedFrames << ","
        << stats.presentUpdates << ","
        << (stats.presentUpdates ? (stats.presentDeltaMsTotal / (double)stats.presentUpdates) : 0.0) << ","
        << stats.presentDeltaMsMax << ","
        << stats.pointerOnlyFrames << ","
        << stats.panicEntries << ","
        << stats.panicFrames << ","
        << stats.activeFPS << ","
        << stats.largeDirty << ","
        << stats.forcedKeyframes << ","
        << stats.frameBuildFailures << ","
        << stats.inputFrames << ","
        << stats.inputNotAccepting << ","
        << stats.inputFailures << ","
        << stats.outputPackets << ","
        << stats.outputBytes << ","
        << stats.maxPacketBytes << ","
        << stats.sendSlow << ","
        << stats.sendMsTotal << ","
        << stats.sendMsMax << ","
        << stats.networkEnqueued << ","
        << stats.networkDropped << ","
        << stats.networkDroppedBytes << ","
        << stats.networkQueueMaxPackets << ","
        << stats.networkQueueMaxBytes << ","
        << stats.totalInputFrames << ","
        << stats.totalPackets << ","
        << stats.totalBytes << ","
        << stats.acquireTiming.AverageMs() << "," << stats.acquireTiming.maxMs << ","
        << stats.copySubmitTiming.AverageMs() << "," << stats.nvMapTiming.AverageMs() << ","
        << stats.nvSubmitTiming.AverageMs() << "," << stats.nvLockTiming.AverageMs() << ","
        << stats.nativeEncodeTiming.AverageMs() << "," << stats.nativeEncodeTiming.maxMs << ","
        << stats.pacingLateMsMax << "\n";
    stats.file.flush();
    stats.last = now;
    stats.ResetInterval();
}

// ═══════════════════════════════════════════════════════════════════
// NETWORK
// ═══════════════════════════════════════════════════════════════════

static bool sendAll(SOCKET s, const uint8_t* data, int len) {
    int sent = 0;
    while (sent < len) {
        int r = send(s, (const char*)data + sent, len - sent, 0);
        if (r == SOCKET_ERROR) {
            int err = WSAGetLastError();
            if (err == WSAEWOULDBLOCK) {
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(s, &wfds);
                timeval tv{};
                tv.tv_sec = 0;
                tv.tv_usec = 1000;
                select(0, nullptr, &wfds, nullptr, &tv);
                continue;
            }
            return false;
        }
        if (r <= 0) return false;
        sent += r;
    }
    return true;
}

static bool sendPacket(SOCKET s, const uint8_t* p, uint32_t sz) {
    uint8_t h[4]; uint32_t be = htonl(sz); memcpy(h, &be, 4);
    return sendAll(s, h, 4) && sendAll(s, p, (int)sz);
}

static bool sendPacketTimed(SOCKET s, const uint8_t* p, uint32_t sz, StreamLogStats& stats) {
    LARGE_INTEGER a{}, b{};
    QueryPerformanceCounter(&a);
    bool ok = sendPacket(s, p, sz);
    QueryPerformanceCounter(&b);

    double ms = (double)(b.QuadPart - a.QuadPart) * 1000.0 / (double)stats.freq.QuadPart;
    stats.sendMsTotal += ms;
    if (ms > stats.sendMsMax) stats.sendMsMax = ms;
    if (ms > 4.0) stats.sendSlow++;
    return ok;
}

static bool PacketContainsIDR(const uint8_t* data, size_t size) {
    if (!data || size < 5) return false;

    auto nalIsIDR = [](uint8_t b) { return (b & 0x1F) == 5; };
    bool annexB = (size >= 4 && data[0] == 0 && data[1] == 0 &&
        ((data[2] == 1) || (data[2] == 0 && data[3] == 1)));

    if (annexB) {
        size_t i = 0;
        while (i + 4 < size) {
            size_t start = size;
            for (; i + 3 < size; i++) {
                if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
                    start = i + 3;
                    break;
                }
                if (i + 4 < size && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
                    start = i + 4;
                    break;
                }
            }
            if (start >= size) break;
            if (nalIsIDR(data[start])) return true;
            i = start + 1;
        }
        return false;
    }

    size_t off = 0;
    while (off + 5 <= size) {
        uint32_t len = ((uint32_t)data[off] << 24) | ((uint32_t)data[off + 1] << 16) |
            ((uint32_t)data[off + 2] << 8) | (uint32_t)data[off + 3];
        off += 4;
        if (len == 0 || off + len > size) return false;
        if (nalIsIDR(data[off])) return true;
        off += len;
    }
    return false;
}

class PacketSender {
public:
    void Start(SOCKET socket) {
        sock = socket;
        u_long nonBlocking = 1;
        ioctlsocket(sock, FIONBIO, &nonBlocking);
        QueryPerformanceFrequency(&freq);
        worker = std::thread(&PacketSender::Run, this);
    }

    void Stop() {
        {
            std::lock_guard<std::mutex> lock(m);
            stopping = true;
            DropQueueLocked();
        }
        cv.notify_all();
        if (sock != INVALID_SOCKET) shutdown(sock, SD_BOTH);
        if (worker.joinable()) worker.join();
    }

    bool EnqueueConfig(const uint8_t* data, DWORD size) {
        if (!data || size == 0) return false;
        if (failed.load()) return false;

        std::vector<uint8_t> copy(data, data + size);
        {
            std::lock_guard<std::mutex> lock(m);
            if (stopping || failed.load()) return false;

            DropQueueLocked();
            Item item;
            item.data = std::move(copy);
            item.config = true;
            item.generation = dropGeneration.load();
            QueryPerformanceCounter(&item.enqueuedQPC);
            queuedBytes += item.data.size();
            q.push_back(std::move(item));
            dropUntilIDR = true;
            forceKeyframe.store(true);
            RecordEnqueueStatsLocked();
        }
        cv.notify_one();
        return true;
    }

    bool Enqueue(const uint8_t* data, DWORD size, bool& queued) {
        queued = false;
        if (!data || size == 0) return true;
        if (failed.load()) return false;

        bool isIDR = PacketContainsIDR(data, size);
        std::vector<uint8_t> copy(data, data + size);

        {
            std::lock_guard<std::mutex> lock(m);
            if (stopping || failed.load()) return false;

            if (!isIDR && copy.size() > MAX_NON_IDR_PACKET_BYTES) {
                DropQueuedFramesLocked();
                RecordDropLocked(1, (ULONGLONG)copy.size());
                dropUntilIDR = true;
                forceKeyframe.store(true);
                return true;
            }

            if (dropUntilIDR) {
                if (!isIDR) {
                    RecordDropLocked(1, size);
                    forceKeyframe.store(true);
                    return true;
                }
                DropQueuedFramesLocked();
                dropUntilIDR = false;
            }

            if (queuedBytes + copy.size() > MAX_QUEUE_BYTES || q.size() >= MAX_QUEUE_PACKETS) {
                DropQueuedFramesLocked();
                forceKeyframe.store(true);
                if (!isIDR) {
                    dropUntilIDR = true;
                    RecordDropLocked(1, (ULONGLONG)copy.size());
                    return true;
                }
            }

            Item item;
            item.data = std::move(copy);
            item.config = false;
            item.idr = isIDR;
            item.frameId = nextFrameId++;
            item.generation = dropGeneration.load();
            QueryPerformanceCounter(&item.enqueuedQPC);
            queuedBytes += item.data.size();
            q.push_back(std::move(item));
            queued = true;
            RecordEnqueueStatsLocked();
        }
        cv.notify_one();
        return true;
    }

    bool ConsumeKeyframeRequest() {
        return forceKeyframe.exchange(false);
    }

    void RequestKeyframe() {
        forceKeyframe.store(true);
    }

    bool Failed() const {
        return failed.load();
    }

    void CollectStats(StreamLogStats& out) {
        std::lock_guard<std::mutex> lock(statsM);
        out.outputPackets += stats.outputPackets;
        out.outputBytes += stats.outputBytes;
        if (stats.maxPacketBytes > out.maxPacketBytes) out.maxPacketBytes = stats.maxPacketBytes;
        out.sendSlow += stats.sendSlow;
        out.sendMsTotal += stats.sendMsTotal;
        if (stats.sendMsMax > out.sendMsMax) out.sendMsMax = stats.sendMsMax;
        out.networkEnqueued += stats.networkEnqueued;
        out.networkDropped += stats.networkDropped;
        out.networkDroppedBytes += stats.networkDroppedBytes;
        if (stats.networkQueueMaxPackets > out.networkQueueMaxPackets) out.networkQueueMaxPackets = stats.networkQueueMaxPackets;
        if (stats.networkQueueMaxBytes > out.networkQueueMaxBytes) out.networkQueueMaxBytes = stats.networkQueueMaxBytes;
        out.totalPackets += stats.outputPackets;
        out.totalBytes += stats.outputBytes;
        stats = {};
    }

private:
    struct Item {
        std::vector<uint8_t> data;
        bool config = false;
        bool idr = false;
        ULONGLONG frameId = 0;
        ULONGLONG generation = 0;
        LARGE_INTEGER enqueuedQPC{};
    };

    struct IntervalStats {
        ULONGLONG outputPackets = 0;
        ULONGLONG outputBytes = 0;
        ULONGLONG maxPacketBytes = 0;
        ULONGLONG sendSlow = 0;
        double sendMsTotal = 0.0;
        double sendMsMax = 0.0;
        ULONGLONG networkEnqueued = 0;
        ULONGLONG networkDropped = 0;
        ULONGLONG networkDroppedBytes = 0;
        ULONGLONG networkQueueMaxPackets = 0;
        ULONGLONG networkQueueMaxBytes = 0;
    };

    static const size_t MAX_QUEUE_BYTES = 768 * 1024;
    static const size_t MAX_QUEUE_PACKETS = 8;
    static const size_t MAX_NON_IDR_PACKET_BYTES = 512 * 1024;
    static const size_t CHUNK_PAYLOAD_BYTES = 4 * 1024;
    static constexpr double NON_IDR_STALE_MS = 10.0;
    static constexpr double IDR_STALE_MS = 25.0;

    SOCKET sock = INVALID_SOCKET;
    LARGE_INTEGER freq{};
    std::thread worker;
    std::mutex m;
    std::condition_variable cv;
    std::deque<Item> q;
    size_t queuedBytes = 0;
    bool stopping = false;
    bool dropUntilIDR = false;
    std::atomic<bool> failed{ false };
    std::atomic<bool> forceKeyframe{ false };
    std::atomic<ULONGLONG> dropGeneration{ 0 };
    ULONGLONG nextFrameId = 1;
    std::mutex statsM;
    IntervalStats stats;

    void RecordEnqueueStatsLocked() {
        std::lock_guard<std::mutex> statsLock(statsM);
        stats.networkEnqueued++;
        if (q.size() > stats.networkQueueMaxPackets) stats.networkQueueMaxPackets = (ULONGLONG)q.size();
        if (queuedBytes > stats.networkQueueMaxBytes) stats.networkQueueMaxBytes = (ULONGLONG)queuedBytes;
    }

    void RecordDropLocked(ULONGLONG packets, ULONGLONG bytes) {
        std::lock_guard<std::mutex> statsLock(statsM);
        stats.networkDropped += packets;
        stats.networkDroppedBytes += bytes;
    }

    void DropQueueLocked() {
        dropGeneration.fetch_add(1);
        if (q.empty()) return;
        ULONGLONG packets = (ULONGLONG)q.size();
        ULONGLONG bytes = (ULONGLONG)queuedBytes;
        q.clear();
        queuedBytes = 0;
        RecordDropLocked(packets, bytes);
    }

    void DropQueuedFramesLocked() {
        dropGeneration.fetch_add(1);
        if (q.empty()) return;

        ULONGLONG packets = 0;
        ULONGLONG bytes = 0;
        for (auto it = q.begin(); it != q.end();) {
            if (!it->config) {
                packets++;
                bytes += (ULONGLONG)it->data.size();
                queuedBytes -= it->data.size();
                it = q.erase(it);
            }
            else {
                ++it;
            }
        }
        if (packets > 0) RecordDropLocked(packets, bytes);
    }

    static void WriteBE32(uint8_t* dst, uint32_t value) {
        dst[0] = (uint8_t)((value >> 24) & 0xFF);
        dst[1] = (uint8_t)((value >> 16) & 0xFF);
        dst[2] = (uint8_t)((value >> 8) & 0xFF);
        dst[3] = (uint8_t)(value & 0xFF);
    }

    void AddDropStats(ULONGLONG packets, ULONGLONG bytes) {
        std::lock_guard<std::mutex> statsLock(statsM);
        stats.networkDropped += packets;
        stats.networkDroppedBytes += bytes;
    }

    bool ShouldAbortFrame(const Item& item) const {
        return item.generation != dropGeneration.load();
    }

    double MsSince(const LARGE_INTEGER& t) const {
        LARGE_INTEGER now{};
        QueryPerformanceCounter(&now);
        return (double)(now.QuadPart - t.QuadPart) * 1000.0 / (double)freq.QuadPart;
    }

    bool HasNewerFrameQueued(const Item& item) {
        std::lock_guard<std::mutex> lock(m);
        for (const auto& queued : q) {
            if (!queued.config && queued.frameId > item.frameId)
                return true;
        }
        return false;
    }

    bool ShouldCancelFrame(const Item& item) {
        if (item.config) return false;
        if (!HasNewerFrameQueued(item)) return false;
        double budgetMs = item.idr ? IDR_STALE_MS : NON_IDR_STALE_MS;
        return MsSince(item.enqueuedQPC) > budgetMs;
    }

    void CancelFrameAndRequestIDR(const Item& item, size_t remainingBytes) {
        {
            std::lock_guard<std::mutex> lock(m);
            DropQueuedFramesLocked();
            dropUntilIDR = true;
            forceKeyframe.store(true);
        }
        AddDropStats(1, (ULONGLONG)remainingBytes);
    }

    bool WaitWritable(int waitMs) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(sock, &wfds);
        timeval tv{};
        tv.tv_sec = 0;
        tv.tv_usec = waitMs * 1000;
        int r = select(0, nullptr, &wfds, nullptr, &tv);
        return r > 0 && FD_ISSET(sock, &wfds);
    }

    bool SendBufferNonBlocking(const uint8_t* wire, size_t wireSize, double& sendMs, const Item* cancellableItem = nullptr, bool* cancelled = nullptr) {
        LARGE_INTEGER a{}, b{};
        QueryPerformanceCounter(&a);
        if (cancelled) *cancelled = false;
        size_t sent = 0;
        while (sent < wireSize) {
            int remaining = (int)(wireSize - sent);
            int r = send(sock, (const char*)wire + sent, remaining, 0);
            if (r > 0) {
                sent += (size_t)r;
                continue;
            }
            if (r == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) {
                if (sent == 0 && cancellableItem && ShouldCancelFrame(*cancellableItem)) {
                    if (cancelled) *cancelled = true;
                    QueryPerformanceCounter(&b);
                    sendMs = (double)(b.QuadPart - a.QuadPart) * 1000.0 / (double)freq.QuadPart;
                    return true;
                }
                WaitWritable(1);
                continue;
            }
            return false;
        }
        QueryPerformanceCounter(&b);
        sendMs = (double)(b.QuadPart - a.QuadPart) * 1000.0 / (double)freq.QuadPart;
        return true;
    }

    bool SendWireNonBlocking(const uint8_t* payload, uint32_t payloadSize, double& sendMs) {
        std::vector<uint8_t> wire(4 + payloadSize);
        uint32_t be = htonl(payloadSize);
        memcpy(wire.data(), &be, 4);
        memcpy(wire.data() + 4, payload, payloadSize);
        return SendBufferNonBlocking(wire.data(), wire.size(), sendMs);
    }

    bool SendConfigPacket(const Item& item) {
        double sendMs = 0.0;
        return SendWireNonBlocking(item.data.data(), (uint32_t)item.data.size(), sendMs);
    }

    bool SendChunkMessage(const Item& item, size_t offset, size_t chunkSize, bool last, double& sendMs, bool& cancelled) {
        const uint32_t payloadSize = (uint32_t)(20 + chunkSize);
        std::vector<uint8_t> wire(4 + payloadSize);
        uint32_t be = htonl(payloadSize);
        memcpy(wire.data(), &be, 4);
        uint8_t* msg = wire.data() + 4;
        msg[0] = 'D'; msg[1] = 'C'; msg[2] = '2'; msg[3] = 'F';
        msg[4] = 1; // frame chunk
        msg[5] = (uint8_t)((item.idr ? 0x01 : 0x00) | (last ? 0x02 : 0x00));
        msg[6] = 0; msg[7] = 0;
        WriteBE32(msg + 8, (uint32_t)item.frameId);
        WriteBE32(msg + 12, (uint32_t)offset);
        WriteBE32(msg + 16, (uint32_t)item.data.size());
        memcpy(msg + 20, item.data.data() + offset, chunkSize);

        return SendBufferNonBlocking(wire.data(), wire.size(), sendMs, &item, &cancelled);
    }

    bool SendFrameChunked(const Item& item) {
        double frameSendMsTotal = 0.0;
        double frameSendMsMax = 0.0;
        ULONGLONG frameSendSlow = 0;
        size_t sentPayload = 0;
        auto recordPartialTiming = [&]() {
            if (frameSendMsTotal <= 0.0 && frameSendMsMax <= 0.0 && frameSendSlow == 0)
                return;
            std::lock_guard<std::mutex> statsLock(statsM);
            stats.sendMsTotal += frameSendMsTotal;
            if (frameSendMsMax > stats.sendMsMax) stats.sendMsMax = frameSendMsMax;
            stats.sendSlow += frameSendSlow;
            frameSendMsTotal = 0.0;
            frameSendMsMax = 0.0;
            frameSendSlow = 0;
        };

        while (sentPayload < item.data.size()) {
            if (ShouldAbortFrame(item)) {
                recordPartialTiming();
                AddDropStats(1, (ULONGLONG)(item.data.size() - sentPayload));
                return true;
            }
            if (ShouldCancelFrame(item)) {
                recordPartialTiming();
                CancelFrameAndRequestIDR(item, item.data.size() - sentPayload);
                return true;
            }

            size_t remaining = item.data.size() - sentPayload;
            size_t chunkSize = remaining < CHUNK_PAYLOAD_BYTES ? remaining : CHUNK_PAYLOAD_BYTES;
            bool last = (sentPayload + chunkSize) == item.data.size();
            double sendMs = 0.0;
            bool cancelled = false;
            if (!SendChunkMessage(item, sentPayload, chunkSize, last, sendMs, cancelled))
                return false;

            frameSendMsTotal += sendMs;
            if (sendMs > frameSendMsMax) frameSendMsMax = sendMs;
            if (sendMs > 4.0) frameSendSlow++;
            if (cancelled) {
                recordPartialTiming();
                CancelFrameAndRequestIDR(item, item.data.size() - sentPayload);
                return true;
            }
            sentPayload += chunkSize;
        }

        std::lock_guard<std::mutex> statsLock(statsM);
        stats.outputPackets++;
        stats.outputBytes += (ULONGLONG)item.data.size();
        if (item.data.size() > stats.maxPacketBytes) stats.maxPacketBytes = (ULONGLONG)item.data.size();
        stats.sendMsTotal += frameSendMsTotal;
        if (frameSendMsMax > stats.sendMsMax) stats.sendMsMax = frameSendMsMax;
        stats.sendSlow += frameSendSlow;
        return true;
    }

    void Run() {
        while (true) {
            Item item;
            {
                std::unique_lock<std::mutex> lock(m);
                cv.wait(lock, [&] { return stopping || !q.empty(); });
                if (stopping && q.empty()) break;
                item = std::move(q.front());
                queuedBytes -= item.data.size();
                q.pop_front();
            }

            bool ok = item.config ? SendConfigPacket(item) : SendFrameChunked(item);
            if (!ok) {
                failed.store(true);
                cv.notify_all();
                break;
            }
        }
    }
};

static SOCKET connectToIPad(const char* ip, int port, DWORD timeoutMs) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in sa{}; sa.sin_family = AF_INET; sa.sin_port = htons((u_short)port);
    inet_pton(AF_INET, ip, &sa.sin_addr);
    PostStatus(SS_CONNECTING);
    DiagLog("connecting to local iproxy port");
    ULONGLONG deadline = GetTickCount64() + timeoutMs;
    while (!g_stop && GetTickCount64() < deadline) {
        if (connect(s, (SOCKADDR*)&sa, sizeof(sa)) == 0) {
            PostStatus(SS_WAITING_IPAD_APP);
            DiagLog("local iproxy TCP connect OK");
            return s;
        }
        DiagLog("local iproxy TCP connect failed WSA=" + std::to_string(WSAGetLastError()));
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        closesocket(s);
        s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    }
    DiagLog("local iproxy TCP connect timed out");
    closesocket(s);
    return INVALID_SOCKET;
}

static bool SendTextHandshake(SOCKET s, const char* text) {
    DiagLog(std::string("sending text handshake: ") + text);
    const char* p = text;
    int remaining = (int)strlen(text);
    while (remaining > 0 && !g_stop) {
        int n = send(s, p, remaining, 0);
        if (n <= 0) {
            DiagLog("text handshake send failed WSA=" + std::to_string(WSAGetLastError()));
            return false;
        }
        p += n;
        remaining -= n;
    }
    DiagLog("text handshake sent");
    return remaining == 0;
}

static bool WaitForIPadReady(SOCKET s, DWORD timeoutMs) {
    const char* ready = "WSUSB_READY2\n";
    std::string buf;
    ULONGLONG deadline = GetTickCount64() + timeoutMs;
    DiagLog("waiting for iPad READY");

    while (!g_stop && GetTickCount64() < deadline) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(s, &rfds);

        timeval tv{};
        tv.tv_sec = 0;
        tv.tv_usec = 100000;

        int sel = select(0, &rfds, nullptr, nullptr, &tv);
        if (sel == SOCKET_ERROR) {
            DiagLog("READY select failed WSA=" + std::to_string(WSAGetLastError()));
            return false;
        }
        if (sel == 0) continue;

        char tmp[64];
        int n = recv(s, tmp, sizeof(tmp), 0);
        if (n <= 0) {
            DiagLog("READY recv closed/failed n=" + std::to_string(n) + " WSA=" + std::to_string(WSAGetLastError()));
            return false;
        }

        buf.append(tmp, tmp + n);
        DiagLog("READY recv bytes=" + std::to_string(n) + " total=" + std::to_string(buf.size()));
        if (buf.find(ready) != std::string::npos) {
            DiagLog("iPad READY received");
            return true;
        }
        if (buf.size() > 256)
            buf.erase(0, buf.size() - 256);
    }

    DiagLog("READY wait timed out");
    return false;
}

// ═══════════════════════════════════════════════════════════════════
// CPU FALLBACK: BGRA → NV12
// ═══════════════════════════════════════════════════════════════════

static void BGRA_to_NV12(const uint8_t* bgra, int rp, uint8_t* nv12, int w, int h) {
    uint8_t* Y = nv12, * UV = nv12 + w * h;
    for (int y = 0; y < h; y += 2) {
        const uint8_t* r0 = bgra + y * rp;
        const uint8_t* r1 = (y + 1 < h) ? (bgra + (y + 1) * rp) : r0;
        uint8_t* y0 = Y + y * w;
        uint8_t* y1 = (y + 1 < h) ? (Y + (y + 1) * w) : y0;
        uint8_t* uv = UV + (y / 2) * w;
        for (int x = 0; x < w; x += 2) {
            int x1 = (x + 1 < w) ? x + 1 : x;

            int B00 = r0[x * 4], G00 = r0[x * 4 + 1], R00 = r0[x * 4 + 2];
            int B01 = r0[x1 * 4], G01 = r0[x1 * 4 + 1], R01 = r0[x1 * 4 + 2];
            int B10 = r1[x * 4], G10 = r1[x * 4 + 1], R10 = r1[x * 4 + 2];
            int B11 = r1[x1 * 4], G11 = r1[x1 * 4 + 1], R11 = r1[x1 * 4 + 2];

            y0[x] = clampByte(((66 * R00 + 129 * G00 + 25 * B00 + 128) >> 8) + 16);
            if (x1 != x) y0[x1] = clampByte(((66 * R01 + 129 * G01 + 25 * B01 + 128) >> 8) + 16);
            if (y + 1 < h) {
                y1[x] = clampByte(((66 * R10 + 129 * G10 + 25 * B10 + 128) >> 8) + 16);
                if (x1 != x) y1[x1] = clampByte(((66 * R11 + 129 * G11 + 25 * B11 + 128) >> 8) + 16);
            }

            int R = (R00 + R01 + R10 + R11) >> 2;
            int G = (G00 + G01 + G10 + G11) >> 2;
            int B = (B00 + B01 + B10 + B11) >> 2;
            uv[x] = clampByte(((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128);
            if (x + 1 < w)
                uv[x + 1] = clampByte(((112 * R - 94 * G - 18 * B + 128) >> 8) + 128);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// SEND CONFIG
// ═══════════════════════════════════════════════════════════════════

// Native NVENC path: bypass Media Foundation's H.264 MFT and feed the
// D3D11 BGRA texture directly to the NVIDIA driver.
typedef NVENCSTATUS(NVENCAPI* PFNNvEncodeAPICreateInstance)(NV_ENCODE_API_FUNCTION_LIST* functionList);
typedef NVENCSTATUS(NVENCAPI* PFNNvEncodeAPIGetMaxSupportedVersion)(uint32_t* version);

class NativeNvencEncoder {
public:
    ~NativeNvencEncoder() { Shutdown(); }

    bool Init(ID3D11Device* device, ID3D11Texture2D* inputTexture, int w, int h, int fps,
        UINT32 avgBitrate, UINT32 maxBitrate) {
        Shutdown();
        if (!device || !inputTexture || w <= 0 || h <= 0 || fps <= 0) return false;

        width = w;
        height = h;
        frameRate = fps;

        dll = LoadLibraryA("nvEncodeAPI64.dll");
        if (!dll) return false;

        auto createInstance = (PFNNvEncodeAPICreateInstance)GetProcAddress(dll, "NvEncodeAPICreateInstance");
        if (!createInstance) return false;

        auto getMaxVersion = (PFNNvEncodeAPIGetMaxSupportedVersion)GetProcAddress(dll, "NvEncodeAPIGetMaxSupportedVersion");
        if (getMaxVersion) {
            uint32_t driverVersion = 0;
            if (getMaxVersion(&driverVersion) != NV_ENC_SUCCESS)
                return false;
        }

        nv = {};
        nv.version = NV_ENCODE_API_FUNCTION_LIST_VER;
        if (createInstance(&nv) != NV_ENC_SUCCESS)
            return false;

        NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open{};
        open.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        open.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
        open.device = device;
        open.apiVersion = NVENCAPI_VERSION;
        if (nv.nvEncOpenEncodeSessionEx(&open, &encoder) != NV_ENC_SUCCESS || !encoder)
            return false;

        NV_ENC_PRESET_CONFIG preset{};
        preset.version = NV_ENC_PRESET_CONFIG_VER;
        preset.presetCfg.version = NV_ENC_CONFIG_VER;
        NVENCSTATUS presetStatus = NV_ENC_ERR_GENERIC;
        if (nv.nvEncGetEncodePresetConfigEx) {
            presetStatus = nv.nvEncGetEncodePresetConfigEx(encoder, NV_ENC_CODEC_H264_GUID,
                NV_ENC_PRESET_P1_GUID, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset);
        }

        encConfig = {};
        if (presetStatus == NV_ENC_SUCCESS)
            encConfig = preset.presetCfg;
        encConfig.version = NV_ENC_CONFIG_VER;
        encConfig.profileGUID = NV_ENC_H264_PROFILE_MAIN_GUID;
        const uint32_t gopFrames = (uint32_t)(fps * COLOR_TEST_GOP_SECONDS);
        encConfig.gopLength = gopFrames;
        encConfig.frameIntervalP = 1;
        encConfig.frameFieldMode = NV_ENC_PARAMS_FRAME_FIELD_MODE_FRAME;
        encConfig.mvPrecision = NV_ENC_MV_PRECISION_QUARTER_PEL;

        UINT32 vbvBits = maxBitrate / (UINT32)fps;
        if (vbvBits < 256000) vbvBits = 256000;
        encConfig.rcParams.version = NV_ENC_RC_PARAMS_VER;
        encConfig.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CBR;
        encConfig.rcParams.averageBitRate = avgBitrate;
        encConfig.rcParams.maxBitRate = maxBitrate;
        encConfig.rcParams.vbvBufferSize = vbvBits;
        encConfig.rcParams.vbvInitialDelay = vbvBits;
        encConfig.rcParams.enableLookahead = 0;
        encConfig.rcParams.lookaheadDepth = 0;
        encConfig.rcParams.enableAQ = 0;
        encConfig.rcParams.enableTemporalAQ = 0;
        encConfig.rcParams.zeroReorderDelay = 1;
        encConfig.rcParams.enableNonRefP = 0;
        encConfig.rcParams.multiPass = NV_ENC_MULTI_PASS_DISABLED;
        encConfig.rcParams.lowDelayKeyFrameScale = 1;

        NV_ENC_CONFIG_H264& h264 = encConfig.encodeCodecConfig.h264Config;
        h264.level = NV_ENC_LEVEL_AUTOSELECT;
        h264.idrPeriod = gopFrames;
        h264.repeatSPSPPS = 1;
        h264.outputAUD = 1;
        h264.chromaFormatIDC = 1;
        h264.maxNumRefFrames = 1;
        h264.numRefL0 = NV_ENC_NUM_REF_FRAMES_1;
        h264.numRefL1 = NV_ENC_NUM_REF_FRAMES_AUTOSELECT;
        h264.entropyCodingMode = NV_ENC_H264_ENTROPY_CODING_MODE_CABAC;
        h264.h264VUIParameters.videoSignalTypePresentFlag = 1;
        h264.h264VUIParameters.videoFormat = NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED;
        h264.h264VUIParameters.videoFullRangeFlag = 1;
        h264.h264VUIParameters.colourDescriptionPresentFlag = 1;
        h264.h264VUIParameters.colourPrimaries = NV_ENC_VUI_COLOR_PRIMARIES_BT709;
        h264.h264VUIParameters.transferCharacteristics = NV_ENC_VUI_TRANSFER_CHARACTERISTIC_BT709;
        h264.h264VUIParameters.colourMatrix = NV_ENC_VUI_MATRIX_COEFFS_BT709;

        NV_ENC_INITIALIZE_PARAMS init{};
        init.version = NV_ENC_INITIALIZE_PARAMS_VER;
        init.encodeGUID = NV_ENC_CODEC_H264_GUID;
        init.presetGUID = NV_ENC_PRESET_P1_GUID;
        init.encodeWidth = (uint32_t)w;
        init.encodeHeight = (uint32_t)h;
        init.darWidth = (uint32_t)w;
        init.darHeight = (uint32_t)h;
        init.frameRateNum = (uint32_t)fps;
        init.frameRateDen = 1;
        init.enableEncodeAsync = 0;
        init.enablePTD = 1;
        init.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
        init.maxEncodeWidth = (uint32_t)w;
        init.maxEncodeHeight = (uint32_t)h;
        init.encodeConfig = &encConfig;
        if (nv.nvEncInitializeEncoder(encoder, &init) != NV_ENC_SUCCESS)
            return false;

        NV_ENC_CREATE_BITSTREAM_BUFFER bitstreamParams{};
        bitstreamParams.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
        if (nv.nvEncCreateBitstreamBuffer(encoder, &bitstreamParams) != NV_ENC_SUCCESS)
            return false;
        bitstream = bitstreamParams.bitstreamBuffer;

        NV_ENC_REGISTER_RESOURCE reg{};
        reg.version = NV_ENC_REGISTER_RESOURCE_VER;
        reg.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
        reg.width = (uint32_t)w;
        reg.height = (uint32_t)h;
        reg.pitch = 0;
        reg.subResourceIndex = 0;
        reg.resourceToRegister = inputTexture;
        reg.bufferFormat = NV_ENC_BUFFER_FORMAT_ARGB;
        reg.bufferUsage = NV_ENC_INPUT_IMAGE;
        if (nv.nvEncRegisterResource(encoder, &reg) != NV_ENC_SUCCESS)
            return false;
        registeredInput = reg.registeredResource;

        std::vector<uint8_t> header(4096);
        uint32_t headerSize = 0;
        NV_ENC_SEQUENCE_PARAM_PAYLOAD seq{};
        seq.version = NV_ENC_SEQUENCE_PARAM_PAYLOAD_VER;
        seq.inBufferSize = (uint32_t)header.size();
        seq.spsppsBuffer = header.data();
        seq.outSPSPPSPayloadSize = &headerSize;
        if (nv.nvEncGetSequenceParams(encoder, &seq) != NV_ENC_SUCCESS || headerSize == 0)
            return false;
        config.assign(header.data(), header.data() + headerSize);
        return true;
    }

    void Shutdown() {
        if (encoder && registeredInput && nv.nvEncUnregisterResource) {
            nv.nvEncUnregisterResource(encoder, registeredInput);
            registeredInput = nullptr;
        }
        if (encoder && bitstream && nv.nvEncDestroyBitstreamBuffer) {
            nv.nvEncDestroyBitstreamBuffer(encoder, bitstream);
            bitstream = nullptr;
        }
        if (encoder && nv.nvEncDestroyEncoder) {
            nv.nvEncDestroyEncoder(encoder);
            encoder = nullptr;
        }
        if (dll) {
            FreeLibrary(dll);
            dll = nullptr;
        }
        nv = {};
        config.clear();
        frameIndex = 0;
    }

    const std::vector<uint8_t>& Config() const { return config; }

    bool Encode(bool forceIDR, std::vector<uint8_t>& out, StreamLogStats* stats = nullptr) {
        winsideusb::ScopedStageTimer totalTiming(stats ? &stats->nativeEncodeTiming : nullptr,
            stats ? stats->freq.QuadPart : 0);
        out.clear();
        if (!encoder || !registeredInput || !bitstream) return false;

        NV_ENC_MAP_INPUT_RESOURCE map{};
        map.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
        map.registeredResource = registeredInput;
        NVENCSTATUS st;
        {
            winsideusb::ScopedStageTimer timing(stats ? &stats->nvMapTiming : nullptr, stats ? stats->freq.QuadPart : 0);
            st = nv.nvEncMapInputResource(encoder, &map);
        }
        if (st != NV_ENC_SUCCESS)
            return false;

        bool mapped = true;
        auto unmap = [&]() {
            if (mapped) {
                nv.nvEncUnmapInputResource(encoder, map.mappedResource);
                mapped = false;
            }
        };

        NV_ENC_PIC_PARAMS pic{};
        pic.version = NV_ENC_PIC_PARAMS_VER;
        pic.inputWidth = (uint32_t)width;
        pic.inputHeight = (uint32_t)height;
        pic.inputPitch = (uint32_t)width;
        pic.inputBuffer = map.mappedResource;
        pic.outputBitstream = bitstream;
        pic.bufferFmt = map.mappedBufferFmt;
        pic.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
        pic.frameIdx = (uint32_t)frameIndex;
        pic.inputTimeStamp = frameIndex;
        pic.inputDuration = 1;
        if (forceIDR) {
            pic.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
            pic.pictureType = NV_ENC_PIC_TYPE_IDR;
        }

        frameIndex++;
        {
            winsideusb::ScopedStageTimer timing(stats ? &stats->nvSubmitTiming : nullptr, stats ? stats->freq.QuadPart : 0);
            st = nv.nvEncEncodePicture(encoder, &pic);
        }
        if (st == NV_ENC_ERR_NEED_MORE_INPUT) {
            unmap();
            return true;
        }
        if (st != NV_ENC_SUCCESS) {
            unmap();
            return false;
        }

        NV_ENC_LOCK_BITSTREAM lock{};
        lock.version = NV_ENC_LOCK_BITSTREAM_VER;
        lock.outputBitstream = bitstream;
        lock.doNotWait = 0;
        {
            winsideusb::ScopedStageTimer timing(stats ? &stats->nvLockTiming : nullptr, stats ? stats->freq.QuadPart : 0);
            st = nv.nvEncLockBitstream(encoder, &lock);
        }
        if (st == NV_ENC_SUCCESS) {
            if (lock.bitstreamBufferPtr && lock.bitstreamSizeInBytes > 0) {
                const uint8_t* src = (const uint8_t*)lock.bitstreamBufferPtr;
                out.assign(src, src + lock.bitstreamSizeInBytes);
            }
            nv.nvEncUnlockBitstream(encoder, bitstream);
        }

        unmap();
        return st == NV_ENC_SUCCESS || st == NV_ENC_ERR_LOCK_BUSY;
    }

private:
    HMODULE dll = nullptr;
    NV_ENCODE_API_FUNCTION_LIST nv{};
    void* encoder = nullptr;
    NV_ENC_CONFIG encConfig{};
    NV_ENC_OUTPUT_PTR bitstream = nullptr;
    NV_ENC_REGISTERED_PTR registeredInput = nullptr;
    std::vector<uint8_t> config;
    uint64_t frameIndex = 0;
    int width = 0;
    int height = 0;
    int frameRate = 0;
};

static bool trySendConfig(IMFTransform* enc, PacketSender& sender, bool& sent) {
    if (sent) return true;
    IMFMediaType* t = nullptr;
    if (FAILED(enc->GetOutputCurrentType(0, &t)) || !t) return false;
    UINT32 sz = 0;
    if (SUCCEEDED(t->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &sz)) && sz > 0) {
        std::vector<BYTE> a(sz); UINT32 g = 0;
        if (SUCCEEDED(t->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, a.data(), sz, &g)) && g == sz)
            if (sender.EnqueueConfig(a.data(), (DWORD)a.size())) sent = true;
    }
    t->Release();
    return sent;
}

// ═══════════════════════════════════════════════════════════════════
// DRAIN ENCODER OUTPUT
// ═══════════════════════════════════════════════════════════════════

static bool drainEncoder(IMFTransform* enc, PacketSender& sender, bool& configSent, ULONGLONG& fc, StreamLogStats& stats) {
    while (true) {
        MFT_OUTPUT_DATA_BUFFER odb{}; MFT_OUTPUT_STREAM_INFO osi{};
        enc->GetOutputStreamInfo(0, &osi); DWORD st = 0;
        IMFSample* os = nullptr;
        IMFMediaBuffer* ob = nullptr;
        if (!(osi.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
            MFCreateSample(&os);
            DWORD as = (osi.cbSize > 0) ? osi.cbSize : (2 * 1024 * 1024);
            MFCreateMemoryBuffer(as, &ob); os->AddBuffer(ob); odb.pSample = os;
        }
        HRESULT pr = enc->ProcessOutput(0, 1, &odb, &st);
        if (pr == MF_E_TRANSFORM_NEED_MORE_INPUT) { if (ob) ob->Release(); if (os) os->Release(); break; }
        if (pr == MF_E_TRANSFORM_STREAM_CHANGE) {
            if (ob) ob->Release(); if (os) os->Release();
            IMFMediaType* nt = nullptr;
            if (SUCCEEDED(enc->GetOutputAvailableType(0, 0, &nt))) { enc->SetOutputType(0, nt, 0); nt->Release(); }
            configSent = false; continue;
        }
        if (FAILED(pr)) { if (ob) ob->Release(); if (os) os->Release(); break; }
        IMFSample* rs = odb.pSample;
        if (!rs) { if (ob) ob->Release(); if (os) os->Release(); break; }
        IMFMediaBuffer* cn = nullptr; rs->ConvertToContiguousBuffer(&cn);
        BYTE* d = nullptr; DWORD cb = 0; cn->Lock(&d, NULL, &cb);
        bool ok = true;
        if (configSent && cb > 0) {
            bool queued = false;
            ok = sender.Enqueue(d, cb, queued);
            if (ok && queued) {
                fc++;
            }
        }
        cn->Unlock(); cn->Release(); if (ob) ob->Release(); rs->Release();
        if (!ok) return false;
    }
    return true;
}

// ═══════════════════════════════════════════════════════════════════
// STREAM THREAD
// ═══════════════════════════════════════════════════════════════════

static void StreamThread() {
    const int W = g_targetW, H = g_targetH, FPS = g_targetFPS.load();
    const UINT32 HW_AVG_BITRATE = 50000000;
    const UINT32 HW_MAX_BITRATE = 65000000;
    const UINT32 SW_AVG_BITRATE = 30000000;
    const UINT32 SW_MAX_BITRATE = 40000000;

    SOCKET                  cS = INVALID_SOCKET;
    IDXGIFactory1* factory = nullptr;
    IDXGIAdapter1* adapter = nullptr;
    IDXGIOutput* output = nullptr;
    ID3D11Device* dev = nullptr;
    ID3D11DeviceContext* ctx = nullptr;
    IDXGIOutput1* output1 = nullptr;
    IDXGIOutputDuplication* dupl = nullptr;
    IMFDXGIDeviceManager* devMgr = nullptr;
    ID3D11Texture2D* gpuTex = nullptr;
    ID3D11Texture2D* sTex = nullptr;
    bool duplicationFrameOwned = false;
    winsideusb::CaptureThreadScheduling captureScheduling;
    winsideusb::FrameDeadlineWaiter frameWaiter;
    winsideusb::DesktopCursor desktopCursor;
    HRESULT lastPointerError = S_OK;
    bool cursorDrawLogged = false;
    IMFTransform* enc = nullptr;
    NativeNvencEncoder     nativeEnc;
    bool                    nativeEncoder = false;
    bool                    hwEncoder = false;
    bool                    useGPUInput = false;
    const char* encoderName = "unknown";
    double                  sourceHz = 0.0;
    D3D_FEATURE_LEVEL       fl = {};
    UINT                    resetToken = 0;
    PROCESS_INFORMATION     iproxyPI = {};
    StreamLogStats          streamLog;
    PacketSender            packetSender;
    bool                    packetSenderStarted = false;
    const std::string       streamUdid = g_detectedUdid;
    std::atomic<bool>        watchStop{ false };
    std::thread             connectionWatch;

    // ── QPC setup ───────────────────────────────────────────────────
    // Used everywhere instead of GetTickCount64() to avoid the ~15 ms
    // resolution cap that GetTickCount64 has (it ignores timeBeginPeriod).
    LARGE_INTEGER qpfFreq;
    QueryPerformanceFrequency(&qpfFreq);
    DiagLog(std::string("capture pacing: high resolution timer=") + (frameWaiter.HighResolution() ? "yes" : "fallback") +
        ", MMCSS Capture=" + (captureScheduling.Active() ? "yes" : "unavailable"));

    timeBeginPeriod(1);
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    MFStartup(MF_VERSION);
    WSADATA wd{}; WSAStartup(MAKEWORD(2, 2), &wd);

    // ── Auto-launch iproxy ───────────────────────────────────────────
    {
        std::string toolDir = EnsureBundledToolsDirA();
        std::string iproxyLogPath = GetLocalAppDirA() + "\\iproxy.log";

        for (int devicePort : WSUSB_DEVICE_PORTS) {
            if (g_stop) break;

            StopIproxyProcess(iproxyPI);
            std::string cmdLine = "\"" + toolDir + "\\iproxy.exe\"";
            if (!streamUdid.empty()) cmdLine += " -u " + streamUdid;
            cmdLine += " " + std::to_string(WSUSB_LOCAL_PORT) + " " + std::to_string(devicePort);
            std::vector<char> cmd(cmdLine.begin(), cmdLine.end());
            cmd.push_back('\0');
            SECURITY_ATTRIBUTES sa{};
            sa.nLength = sizeof(sa);
            sa.bInheritHandle = TRUE;
            HANDLE iproxyLog = CreateFileA(iproxyLogPath.c_str(), GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, CREATE_ALWAYS,
                FILE_ATTRIBUTE_NORMAL, nullptr);

            STARTUPINFOA si{}; si.cb = sizeof(si); si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
            BOOL inheritHandles = FALSE;
            if (iproxyLog != INVALID_HANDLE_VALUE) {
                si.dwFlags |= STARTF_USESTDHANDLES;
                si.hStdOutput = iproxyLog;
                si.hStdError = iproxyLog;
                si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
                inheritHandles = TRUE;
            }

            DiagLog("starting iproxy: " + cmdLine);
            if (!CreateProcessA(NULL, cmd.data(), NULL, NULL, inheritHandles, CREATE_NO_WINDOW,
                NULL, toolDir.c_str(), &si, &iproxyPI)) {
                DiagLog("iproxy CreateProcess failed err=" + std::to_string(GetLastError()));
                if (iproxyLog != INVALID_HANDLE_VALUE) CloseHandle(iproxyLog);
                continue;
            }

            DiagLog("iproxy started pid=" + std::to_string(iproxyPI.dwProcessId) +
                " device_port=" + std::to_string(devicePort) + " log=" + iproxyLogPath);
            if (iproxyLog != INVALID_HANDLE_VALUE) CloseHandle(iproxyLog);
            std::this_thread::sleep_for(std::chrono::milliseconds(500));

            cS = connectToIPad("127.0.0.1", WSUSB_LOCAL_PORT, 1800);
            if (cS == INVALID_SOCKET) {
                StopIproxyProcess(iproxyPI);
                continue;
            }

            int one = 1;
            setsockopt(cS, IPPROTO_TCP, TCP_NODELAY, (const char*)&one, sizeof(one));
            if (SendTextHandshake(cS, "WSUSB_HELLO2\n") && WaitForIPadReady(cS, 2200)) {
                DiagLog("selected iPad device port " + std::to_string(devicePort));
                break;
            }

            closesocket(cS);
            cS = INVALID_SOCKET;
            StopIproxyProcess(iproxyPI);
        }
    }

    if (cS == INVALID_SOCKET) goto CLEANUP;
    PostStatus(SS_CONNECTED);

    {
        int one = 1;          setsockopt(cS, IPPROTO_TCP, TCP_NODELAY, (const char*)&one, sizeof(one));
        int sndbuf = 64 * 1024; setsockopt(cS, SOL_SOCKET, SO_SNDBUF, (const char*)&sndbuf, sizeof(sndbuf));
    }
    packetSender.Start(cS);
    packetSenderStarted = true;

    // A static desktop may produce no frames. Check the tunnel independently of
    // encoding so unplugging still closes the lease and removes the monitor.
    connectionWatch = std::thread([&]() {
        ULONGLONG lastPing = GetTickCount64(), lastProbe = lastPing;
        int missingProbes = 0;
        while (!watchStop.load() && !g_stop.load()) {
            fd_set readable;
            FD_ZERO(&readable); FD_SET(cS, &readable);
            timeval timeout{ 0, 100000 };
            int ready = select(0, &readable, nullptr, nullptr, &timeout);
            if (ready == SOCKET_ERROR) {
                DiagLog("connection watcher: tunnel read failed"); g_stop = true; break;
            }
            if (ready > 0) {
                char byte = 0;
                int received = recv(cS, &byte, 1, MSG_PEEK);
                if (received == 0 || (received == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK)) {
                    DiagLog("connection watcher: iPad tunnel closed"); g_stop = true; break;
                }
                if (received > 0) Sleep(100);
            }
            if (iproxyPI.hProcess && WaitForSingleObject(iproxyPI.hProcess, 0) == WAIT_OBJECT_0) {
                DiagLog("connection watcher: USB proxy exited"); g_stop = true; break;
            }
            ULONGLONG now = GetTickCount64();
            if (winsideusb::HasSignedDisplayConfiguration() && g_virtualDisplayAttached.load() &&
                now - lastPing >= WinSideUSBDisplay::HeartbeatIntervalMs) {
                DWORD error = 0;
                if (!g_displayClient.Ping(error, g_stop)) {
                    DiagLog("connection watcher: display lease failed err=" + std::to_string(error));
                    if (!g_stop.load()) SetStreamError(L"The display service stopped. Run setup again or view logs.");
                    g_stop = true; break;
                }
                lastPing = now;
            }
            if (!streamUdid.empty() && (g_deviceChangePending.exchange(false) || now - lastProbe >= 2000)) {
                std::string present = RunIdeviceinfo("UniqueDeviceID", streamUdid, true);
                missingProbes = present == streamUdid ? 0 : missingProbes + 1;
                if (missingProbes >= 2) {
                    DiagLog("connection watcher: selected USB iPad is absent"); g_stop = true; break;
                }
                lastProbe = GetTickCount64();
            }
        }
        if (g_stop.load()) DisconnectVirtualDisplay();
    });

    if (!g_stop) {
        if (!ConnectVirtualDisplay(W, H, FPS))
            goto CLEANUP;

        for (int i = 0; i < 16 && !g_stop; ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    // ── D3D11 + Desktop Duplication ──────────────────────────────────
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&factory))) goto CLEANUP;
    if (!g_captureDisplayName.empty()) {
        if (!winsideusb::FindDXGIOutput(factory, g_captureDisplayName, &adapter, &output)) {
            SetStreamError(L"The iPad display could not be captured. View logs for details.");
            goto CLEANUP;
        }
    } else {
        // Retain the original local development-driver path.
        if (FAILED(factory->EnumAdapters1(0, &adapter))) goto CLEANUP;
        for (UINT i = 0; ; i++) {
            IDXGIOutput* o = nullptr;
            if (FAILED(adapter->EnumOutputs(i, &o)) || !o) break;
            if (i == 0) { output = o; continue; }
            if (output) output->Release();
            output = o;
            break;
        }
    }

    if (FAILED(D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, 0,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
        0, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx))) goto CLEANUP;
    {
        ID3D10Multithread* mt = nullptr;
        if (SUCCEEDED(dev->QueryInterface(__uuidof(ID3D10Multithread), (void**)&mt)))
        {
            mt->SetMultithreadProtected(TRUE); mt->Release();
        }
    }

    if (!output) goto CLEANUP;
    output->QueryInterface(__uuidof(IDXGIOutput1), (void**)&output1);
    if (!output1) goto CLEANUP;
    while (!g_stop && FAILED(output1->DuplicateOutput(dev, &dupl))) {
        PostStatus(SS_PAUSED);
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
    if (!dupl) goto CLEANUP;
    {
        DXGI_OUTDUPL_DESC dd{};
        dupl->GetDesc(&dd);
        if (!winsideusb::IsExactDuplicationMode(dd, W, H, FPS)) {
            SetStreamError(L"Windows changed the iPad display size or refresh rate. Reconnect to apply your selected mode.");
            goto CLEANUP;
        }
        if (dd.ModeDesc.RefreshRate.Denominator != 0) {
            sourceHz = (double)dd.ModeDesc.RefreshRate.Numerator /
                (double)dd.ModeDesc.RefreshRate.Denominator;
        }
    }

    MFCreateDXGIDeviceManager(&resetToken, &devMgr);
    devMgr->ResetDevice(dev, resetToken);

    // GPU texture (BGRA, stays on GPU for NVENC zero-copy)
    {
        D3D11_TEXTURE2D_DESC d{};
        d.Width = W; d.Height = H; d.MipLevels = 1; d.ArraySize = 1;
        d.Format = DXGI_FORMAT_B8G8R8A8_UNORM; d.SampleDesc.Count = 1;
        d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        dev->CreateTexture2D(&d, NULL, &gpuTex);
    }

    // CPU staging texture (software fallback path only)
    {
        D3D11_TEXTURE2D_DESC d{};
        d.Width = W; d.Height = H; d.MipLevels = 1; d.ArraySize = 1;
        d.Format = DXGI_FORMAT_B8G8R8A8_UNORM; d.SampleDesc.Count = 1;
        d.Usage = D3D11_USAGE_STAGING; d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        dev->CreateTexture2D(&d, NULL, &sTex);
    }

    {
        HRESULT hr = desktopCursor.Initialize(dev, ctx, gpuTex);
        if (FAILED(hr)) {
            DiagLog("cursor compositor initialization failed hr=" + std::to_string(static_cast<unsigned long>(hr)));
            SetStreamError(L"Windows could not initialize the mouse cursor renderer. View logs for details.");
            goto CLEANUP;
        }
        DiagLog("cursor compositor ready (GPU, color/monochrome/masked)");
    }

    // ── Create Encoder ───────────────────────────────────────────────
    nativeEncoder = nativeEnc.Init(dev, gpuTex, W, H, FPS, HW_AVG_BITRATE, HW_MAX_BITRATE);
    if (nativeEncoder) {
        hwEncoder = true;
        useGPUInput = true;
    }

    if (!nativeEncoder) {
        MFT_REGISTER_TYPE_INFO outInfo{};
        outInfo.guidMajorType = MFMediaType_Video; outInfo.guidSubtype = MFVideoFormat_H264;
        IMFActivate** acts = nullptr; UINT32 cnt = 0;
        HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
            nullptr, &outInfo, &acts, &cnt);

        if (SUCCEEDED(hr) && cnt > 0) {
            IMFTransform* hw = nullptr;
            acts[0]->ActivateObject(__uuidof(IMFTransform), (void**)&hw);
            if (hw) {
                IMFAttributes* attrs = nullptr;
                if (SUCCEEDED(hw->GetAttributes(&attrs)) && attrs) {
                    UINT32 af = 0;
                    if (SUCCEEDED(attrs->GetUINT32(MF_TRANSFORM_ASYNC, &af)) && af)
                        attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
                    attrs->Release();
                }
                hr = hw->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)devMgr);
                if (SUCCEEDED(hr)) {
                    IMFMediaType* ot = nullptr; MFCreateMediaType(&ot);
                    ot->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
                    ot->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
                    ot->SetUINT32(MF_MT_AVG_BITRATE, HW_AVG_BITRATE);
                    MFSetAttributeSize(ot, MF_MT_FRAME_SIZE, W, H);
                    MFSetAttributeRatio(ot, MF_MT_FRAME_RATE, FPS, 1);
                    ApplyDesktopColorMetadata(ot);
                    ot->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                    ot->SetUINT32(MF_MT_MPEG2_PROFILE, 77);
                    hr = hw->SetOutputType(0, ot, 0); ot->Release();

                    if (SUCCEEDED(hr)) {
                        ConfigureLowLatencyEncoder(hw, HW_AVG_BITRATE, HW_MAX_BITRATE, FPS);

                        bool hasARGB = false, hasNV12 = false;
                        DWORD argbIdx = 0, nv12Idx = 0;
                        for (DWORD i = 0; i < 30; i++) {
                            IMFMediaType* av = nullptr;
                            if (FAILED(hw->GetInputAvailableType(0, i, &av))) break;
                            GUID sub{}; av->GetGUID(MF_MT_SUBTYPE, &sub);
                            if (sub == MFVideoFormat_ARGB32) { hasARGB = true; argbIdx = i; }
                            if (sub == MFVideoFormat_NV12) { hasNV12 = true; nv12Idx = i; }
                            av->Release();
                        }

                        bool inputOk = false;
                        if (hasARGB) {
                            IMFMediaType* av = nullptr; hw->GetInputAvailableType(0, argbIdx, &av);
                            if (av) {
                                MFSetAttributeSize(av, MF_MT_FRAME_SIZE, W, H);
                                MFSetAttributeRatio(av, MF_MT_FRAME_RATE, FPS, 1);
                                ApplyDesktopColorMetadata(av);
                                av->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                                if (SUCCEEDED(hw->SetInputType(0, av, 0))) { inputOk = true; useGPUInput = true; }
                                av->Release();
                            }
                        }
                        if (!inputOk && hasNV12) {
                            IMFMediaType* av = nullptr; hw->GetInputAvailableType(0, nv12Idx, &av);
                            if (av) {
                                MFSetAttributeSize(av, MF_MT_FRAME_SIZE, W, H);
                                MFSetAttributeRatio(av, MF_MT_FRAME_RATE, FPS, 1);
                                ApplyDesktopColorMetadata(av);
                                av->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                                if (SUCCEEDED(hw->SetInputType(0, av, 0))) inputOk = true;
                                av->Release();
                            }
                        }

                        if (inputOk) { enc = hw; hwEncoder = true; }
                        else { hw->Release(); }
                    }
                    else { hw->Release(); }
                }
                else { hw->Release(); }
            }
            for (UINT32 i = 0; i < cnt; i++) acts[i]->Release(); CoTaskMemFree(acts);
        }
    }

    // Software fallback
    if (!nativeEncoder && !enc) {
        CoCreateInstance(CLSID_CMSH264EncoderMFT, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enc));
        if (!enc) goto CLEANUP;

        IMFMediaType* ot = nullptr; MFCreateMediaType(&ot);
        ot->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video); ot->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        ot->SetUINT32(MF_MT_AVG_BITRATE, SW_AVG_BITRATE);
        MFSetAttributeSize(ot, MF_MT_FRAME_SIZE, W, H); MFSetAttributeRatio(ot, MF_MT_FRAME_RATE, FPS, 1);
        ApplyDesktopColorMetadata(ot);
        ot->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        ot->SetUINT32(MF_MT_MPEG2_PROFILE, 66);
        enc->SetOutputType(0, ot, 0); ot->Release();

        ConfigureLowLatencyEncoder(enc, SW_AVG_BITRATE, SW_MAX_BITRATE, FPS);

        IMFMediaType* it = nullptr; MFCreateMediaType(&it);
        it->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video); it->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(it, MF_MT_FRAME_SIZE, W, H); MFSetAttributeRatio(it, MF_MT_FRAME_RATE, FPS, 1);
        ApplyDesktopColorMetadata(it);
        it->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        enc->SetInputType(0, it, 0); it->Release();
    }

    encoderName = nativeEncoder ? "native_nvenc_bt709_full_gop5" : (hwEncoder ? (useGPUInput ? "nvenc_gpu_bt709_full_gop5" : "nvenc_cpu_convert_bt709_full_gop5") : "software_bt709_full_gop5");
    if (hwEncoder && useGPUInput) PostStatus(SS_ENCODER_GPU);
    else if (hwEncoder)                PostStatus(SS_ENCODER_HW);
    else                               PostStatus(SS_ENCODER_SW);
    OpenStreamLog(streamLog, W, H, FPS, encoderName, sourceHz);

    if (!nativeEncoder) {
        enc->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        enc->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    }

    {
        const int nv12Size = W * H * 3 / 2;
        std::vector<uint8_t> nv12Buf(nv12Size);
        bool        configSent = false;
        ULONGLONG   frameCount = 0;
        LONGLONG activeFrameIntervalCounts = qpfFreq.QuadPart / FPS;
        const bool forceFullRefresh = nativeEncoder && FPS >= 100;
        const int panicFPS = forceFullRefresh ? FPS : ((FPS >= 100) ? 60 : FPS);
        const UINT acquireTimeoutMs = (FPS >= 100) ? 10 : 16;

        // QPC-based timing anchors
        LARGE_INTEGER startQPC, nextFrameQPC, lastStatQPC;
        QueryPerformanceCounter(&startQPC);
        nextFrameQPC = startQPC;
        lastStatQPC = startQPC;
        LARGE_INTEGER previousPresentQPC{};
        LARGE_INTEGER panicUntilQPC{};
        LARGE_INTEGER lastForcedKeyframeQPC = startQPC;
        lastForcedKeyframeQPC.QuadPart -= qpfFreq.QuadPart;
        LARGE_INTEGER lastIdleHeartbeatQPC = startQPC;
        const LONGLONG idleHeartbeatIntervalCounts = qpfFreq.QuadPart / IDLE_HEARTBEAT_FPS;
        bool haveLastNativeFrame = false;
        bool previousFrameLargeDirty = false;
        int colorRecoveryAttempts = 0;
        auto advanceNextFrame = [&](const LARGE_INTEGER& now) {
            if (now.QuadPart - nextFrameQPC.QuadPart > activeFrameIntervalCounts * 2) {
                nextFrameQPC = now;
                nextFrameQPC.QuadPart += activeFrameIntervalCounts;
                return;
            }
            nextFrameQPC.QuadPart += activeFrameIntervalCounts;
        };
        auto updatePacingMode = [&](const LARGE_INTEGER& now) {
            int fpsNow = (panicUntilQPC.QuadPart > now.QuadPart) ? panicFPS : FPS;
            activeFrameIntervalCounts = qpfFreq.QuadPart / fpsNow;
            streamLog.activeFPS = fpsNow;
        };
        auto enterPanicMode = [&](const LARGE_INTEGER& now) {
            if (panicFPS >= FPS) return;
            if (panicUntilQPC.QuadPart <= now.QuadPart)
                streamLog.panicEntries++;
            panicUntilQPC.QuadPart = now.QuadPart + (qpfFreq.QuadPart / 2);
            streamLog.activeFPS = panicFPS;
            activeFrameIntervalCounts = qpfFreq.QuadPart / panicFPS;
            LONGLONG earliestNext = now.QuadPart + activeFrameIntervalCounts;
            if (nextFrameQPC.QuadPart < earliestNext)
                nextFrameQPC.QuadPart = earliestNext;
        };
        auto flushLog = [&]() {
            packetSender.CollectStats(streamLog);
            LogStreamStatsIfNeeded(streamLog);
        };

        // ── Main capture/encode/send loop ────────────────────────────
        while (!g_stop) {
            if (packetSender.Failed()) break;
            if (!nativeEncoder && !drainEncoder(enc, packetSender, configSent, frameCount, streamLog))
                break;
            if (!dupl) {
                LARGE_INTEGER retryQPC{};
                if (!RestoreCaptureSdr()) break;
                HRESULT dupHr = output1->DuplicateOutput(dev, &dupl);
                if (FAILED(dupHr) || !dupl) {
                    PostStatus(SS_PAUSED);
                    streamLog.captureErrors++;
                    QueryPerformanceCounter(&retryQPC);
                    nextFrameQPC = retryQPC;
                    nextFrameQPC.QuadPart += activeFrameIntervalCounts;
                    flushLog();
                    std::this_thread::sleep_for(std::chrono::milliseconds(200));
                    continue;
                }
                DXGI_OUTDUPL_DESC resumed{};
                dupl->GetDesc(&resumed);
                if (!winsideusb::IsExactDuplicationMode(resumed, W, H, FPS)) {
                    SetStreamError(L"Windows changed the iPad display mode. Reconnect to apply your selected mode.");
                    break;
                }
                PostStatus(SS_CONNECTED);
                previousPresentQPC = {};
                desktopCursor.ResetPointer();
                packetSender.RequestKeyframe();
            }

            // ── Frame-rate throttle (QPC, sub-millisecond resolution) ──
            // ── Acquire next DXGI frame ────────────────────────────────
            LARGE_INTEGER nowQPC;
            QueryPerformanceCounter(&nowQPC);
            updatePacingMode(nowQPC);
            if (nowQPC.QuadPart + activeFrameIntervalCounts / 8 < nextFrameQPC.QuadPart) {
                streamLog.throttled++;
                if (!frameWaiter.WaitUntil(nextFrameQPC.QuadPart - activeFrameIntervalCounts / 8,
                    qpfFreq.QuadPart, g_stop)) break;
            }
            QueryPerformanceCounter(&nowQPC);
            if (nowQPC.QuadPart > nextFrameQPC.QuadPart)
                streamLog.pacingLateMsMax = (std::max)(streamLog.pacingLateMsMax,
                    (double)(nowQPC.QuadPart - nextFrameQPC.QuadPart) * 1000 / qpfFreq.QuadPart);

            DXGI_OUTDUPL_FRAME_INFO fi{}; IDXGIResource* res = nullptr;
            // Retain ownership through GPU submission/encoding and pacing;
            // minimize the gap where DXGI copies intermediate desktop updates.
            if (duplicationFrameOwned) { dupl->ReleaseFrame(); duplicationFrameOwned = false; }
            HRESULT got;
            {
                winsideusb::ScopedStageTimer timing(&streamLog.acquireTiming, qpfFreq.QuadPart);
                got = dupl->AcquireNextFrame(acquireTimeoutMs, &fi, &res);
            }

            if (got == DXGI_ERROR_WAIT_TIMEOUT) {
                if (!nativeEncoder && !drainEncoder(enc, packetSender, configSent, frameCount, streamLog))
                    break;
                streamLog.captureTimeouts++;
                QueryPerformanceCounter(&nowQPC);
                // No frame was produced: do not add another pacing wait after
                // DXGI already waited for the source. Resume promptly on motion.
                nextFrameQPC = nowQPC;
                if (nativeEncoder && configSent && haveLastNativeFrame &&
                    nowQPC.QuadPart - lastIdleHeartbeatQPC.QuadPart >= idleHeartbeatIntervalCounts) {
                    bool forceHeartbeatKeyframe = packetSender.ConsumeKeyframeRequest();
                    std::vector<uint8_t> encoded;
                    if (nativeEnc.Encode(forceHeartbeatKeyframe, encoded, &streamLog)) {
                        streamLog.inputFrames++;
                        streamLog.totalInputFrames++;
                        if (forceHeartbeatKeyframe) {
                            lastForcedKeyframeQPC = nowQPC;
                            streamLog.forcedKeyframes++;
                        }
                        if (!encoded.empty()) {
                            bool queued = false;
                            if (!packetSender.Enqueue(encoded.data(), (DWORD)encoded.size(), queued))
                                break;
                            if (queued) frameCount++;
                        }
                    }
                    else {
                        streamLog.inputFailures++;
                    }
                    lastIdleHeartbeatQPC = nowQPC;
                }
                flushLog();
                continue;
            }
            else if (FAILED(got)) {
                streamLog.captureErrors++;
                flushLog();
                if (res) res->Release();
                if (dupl) { dupl->Release(); dupl = nullptr; }
                PostStatus(SS_PAUSED);
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                continue;
            }

            QueryPerformanceCounter(&nowQPC);
            duplicationFrameOwned = true;
            {
                HRESULT pointerHr = desktopCursor.UpdateFrame(dupl, fi);
                if (FAILED(pointerHr) && pointerHr != lastPointerError)
                    DiagLog("cursor shape update failed hr=" + std::to_string(static_cast<unsigned long>(pointerHr)));
                lastPointerError = pointerHr;
            }
            updatePacingMode(nowQPC);
            streamLog.captured++;
            if (streamLog.activeFPS < FPS) streamLog.panicFrames++;
            if (fi.AccumulatedFrames > 1)
                streamLog.accumulatedFrames += (ULONGLONG)(fi.AccumulatedFrames - 1);
            if (fi.LastPresentTime.QuadPart != 0) {
                if (previousPresentQPC.QuadPart != 0) {
                    double deltaMs = (double)(fi.LastPresentTime.QuadPart - previousPresentQPC.QuadPart) *
                        1000.0 / (double)qpfFreq.QuadPart;
                    if (deltaMs >= 0.0 && deltaMs < 1000.0) {
                        streamLog.presentUpdates++;
                        streamLog.presentDeltaMsTotal += deltaMs;
                        if (deltaMs > streamLog.presentDeltaMsMax) streamLog.presentDeltaMsMax = deltaMs;
                    }
                }
                previousPresentQPC = fi.LastPresentTime;
            }
            else if (fi.LastMouseUpdateTime.QuadPart != 0) {
                streamLog.pointerOnlyFrames++;
            }
            advanceNextFrame(nowQPC);

            // ── Build input sample ─────────────────────────────────────
            if (nativeEncoder) {
                if (!configSent) {
                    const std::vector<uint8_t>& cfg = nativeEnc.Config();
                    if (!cfg.empty()) {
                        if (!packetSender.EnqueueConfig(cfg.data(), (DWORD)cfg.size()))
                            break;
                        configSent = true;
                    }
                }
            }
            else if (!trySendConfig(enc, packetSender, configSent) && packetSender.Failed()) {
                break;
            }

            IMFSample* inSample = nullptr;
            if (!nativeEncoder) {
                MFCreateSample(&inSample);
                LONGLONG sampleQPC = fi.LastPresentTime.QuadPart != 0 ? fi.LastPresentTime.QuadPart : nowQPC.QuadPart;
                LONGLONG ts = ((sampleQPC - startQPC.QuadPart) * 10000000LL) / qpfFreq.QuadPart;
                if (ts < 0) ts = 0;
                inSample->SetSampleTime(ts);
                inSample->SetSampleDuration(10000000LL / FPS);
            }

            bool frameOk = false;

            ID3D11Texture2D* tex = nullptr;
            if (res) res->QueryInterface(__uuidof(ID3D11Texture2D), (void**)&tex);
            if (!tex) {
                streamLog.frameBuildFailures++;
                flushLog();
                if (res) res->Release();
                dupl->ReleaseFrame(); duplicationFrameOwned = false;
                if (inSample) inSample->Release();
                continue;
            }
            D3D11_TEXTURE2D_DESC capturedTexture{};
            tex->GetDesc(&capturedTexture);
            if (!winsideusb::IsExactCaptureTexture(capturedTexture, W, H)) {
                const bool colorTransition = capturedTexture.Width == static_cast<UINT>(W) &&
                    capturedTexture.Height == static_cast<UINT>(H) &&
                    (capturedTexture.Format == DXGI_FORMAT_R16G16B16A16_FLOAT ||
                        capturedTexture.Format == DXGI_FORMAT_R10G10B10A2_UNORM);
                tex->Release();
                if (res) res->Release();
                dupl->ReleaseFrame(); duplicationFrameOwned = false;
                if (inSample) inSample->Release();
                if (colorTransition && colorRecoveryAttempts++ < 5) {
                    DiagLog("HDR capture surface detected; recreating SDR duplication");
                    dupl->Release(); dupl = nullptr;
                    haveLastNativeFrame = false;
                    desktopCursor.ResetPointer();
                    Sleep(100);
                    continue;
                }
                SetStreamError(colorTransition ?
                    L"Windows could not restore SDR capture. Turn HDR off for the iPad virtual display and reconnect." :
                    L"Windows changed the captured display size. Reconnect to apply your selected mode.");
                break;
            }
            colorRecoveryAttempts = 0;

            {
                winsideusb::ScopedStageTimer timing(&streamLog.copySubmitTiming, qpfFreq.QuadPart);
                // Always start with the clean captured desktop, including
                // pointer-only updates, so moving/hiding leaves no cursor trail.
                ctx->CopyResource(gpuTex, tex);
                if (desktopCursor.Draw() && !cursorDrawLogged) {
                    DiagLog("cursor overlay first frame composited");
                    cursorDrawLogged = true;
                }
            }
            if (nativeEncoder) {
                // NvEncMapInputResource synchronizes prior D3D work. Keep
                // the duplication frame alive until Encode has completed.
                ctx->Flush();
                haveLastNativeFrame = true;
            }
            else if (!useGPUInput) {
                // Software encoding must receive the same composited cursor.
                ctx->CopyResource(sTex, gpuTex);
            }

            bool largeDirtyFrame = IsLargeDirtyFrame(dupl, W, H);
            if (largeDirtyFrame) streamLog.largeDirty++;

            if (tex) tex->Release();
            res->Release();
            if (!nativeEncoder) { dupl->ReleaseFrame(); duplicationFrameOwned = false; }

            if (nativeEncoder) {
                frameOk = true;
            }
            else if (useGPUInput) {
                IMFMediaBuffer* dxgiBuf = nullptr;
                if (SUCCEEDED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D),
                    gpuTex,
                    0, FALSE, &dxgiBuf)))
                {
                    inSample->AddBuffer(dxgiBuf); dxgiBuf->Release();
                    frameOk = true;
                }
            }
            else {
                D3D11_MAPPED_SUBRESOURCE map{};
                if (SUCCEEDED(ctx->Map(sTex, 0, D3D11_MAP_READ, 0, &map))) {
                    BGRA_to_NV12((const uint8_t*)map.pData, (int)map.RowPitch, nv12Buf.data(), W, H);
                    ctx->Unmap(sTex, 0);
                    IMFMediaBuffer* inBuf = nullptr; MFCreateMemoryBuffer(nv12Size, &inBuf);
                    BYTE* dst = nullptr; inBuf->Lock(&dst, NULL, NULL);
                    memcpy(dst, nv12Buf.data(), nv12Size);
                    inBuf->Unlock(); inBuf->SetCurrentLength(nv12Size);
                    inSample->AddBuffer(inBuf); inBuf->Release();
                    frameOk = true;
                }
            }

            if (!frameOk) {
                streamLog.frameBuildFailures++;
                flushLog();
                if (inSample) inSample->Release();
                continue;
            }

            bool periodicNativeKeyframe =
                nativeEncoder && (nowQPC.QuadPart - lastForcedKeyframeQPC.QuadPart > qpfFreq.QuadPart * COLOR_TEST_GOP_SECONDS);
            bool forceIFrame = periodicNativeKeyframe ||
                (largeDirtyFrame && !previousFrameLargeDirty) ||
                packetSender.ConsumeKeyframeRequest();
            previousFrameLargeDirty = largeDirtyFrame;
            bool forceThisFrame = false;
            if (forceIFrame && nowQPC.QuadPart - lastForcedKeyframeQPC.QuadPart > qpfFreq.QuadPart / 4) {
                forceThisFrame = true;
                if (!nativeEncoder)
                    ForceKeyFrame(enc);
                lastForcedKeyframeQPC = nowQPC;
                streamLog.forcedKeyframes++;
            }

            if (nativeEncoder) {
                std::vector<uint8_t> encoded;
                if (nativeEnc.Encode(forceThisFrame, encoded, &streamLog)) {
                    streamLog.inputFrames++;
                    streamLog.totalInputFrames++;
                    if (!encoded.empty() && configSent) {
                        bool queued = false;
                        if (!packetSender.Enqueue(encoded.data(), (DWORD)encoded.size(), queued))
                            break;
                        if (queued) {
                            frameCount++;
                            lastIdleHeartbeatQPC = nowQPC;
                        }
                    }
                }
                else {
                    streamLog.inputFailures++;
                    LARGE_INTEGER panicQPC{};
                    QueryPerformanceCounter(&panicQPC);
                    enterPanicMode(panicQPC);
                }
            }
            else {
                if (!drainEncoder(enc, packetSender, configSent, frameCount, streamLog)) {
                    inSample->Release();
                    break;
                }

                HRESULT inHr = E_FAIL;
                LARGE_INTEGER inputStartQPC{};
                QueryPerformanceCounter(&inputStartQPC);
                const double maxInputWaitMs = forceIFrame ? 12.0 : 6.5;
                int frameNotAccepting = 0;
                for (int inputAttempt = 0; inputAttempt < 16; inputAttempt++) {
                    inHr = enc->ProcessInput(0, inSample, 0);
                    if (SUCCEEDED(inHr)) break;
                    if (inHr != MF_E_NOTACCEPTING) break;

                    frameNotAccepting++;
                    streamLog.inputNotAccepting++;
                    if (!drainEncoder(enc, packetSender, configSent, frameCount, streamLog))
                        break;

                    LARGE_INTEGER retryQPC{};
                    QueryPerformanceCounter(&retryQPC);
                    double sampleAgeMs = (double)(retryQPC.QuadPart - inputStartQPC.QuadPart) *
                        1000.0 / (double)qpfFreq.QuadPart;
                    if (sampleAgeMs > maxInputWaitMs)
                        break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                if (frameNotAccepting >= 3 || FAILED(inHr)) {
                    LARGE_INTEGER panicQPC{};
                    QueryPerformanceCounter(&panicQPC);
                    enterPanicMode(panicQPC);
                }
                if (SUCCEEDED(inHr)) {
                    streamLog.inputFrames++;
                    streamLog.totalInputFrames++;
                }
                else {
                    streamLog.inputFailures++;
                }
                if (!drainEncoder(enc, packetSender, configSent, frameCount, streamLog)) {
                    inSample->Release(); break;
                }
                inSample->Release();
            }

            // ── Per-second FPS stat ────────────────────────────────────
            QueryPerformanceCounter(&nowQPC);
            LONGLONG elapsedStat = nowQPC.QuadPart - lastStatQPC.QuadPart;
            if (elapsedStat >= qpfFreq.QuadPart) {
                double elapsed = (double)elapsedStat / (double)qpfFreq.QuadPart;
                PostFPS(frameCount / elapsed);
                frameCount = 0;
                lastStatQPC = nowQPC;
            }
            flushLog();
        }
    }

CLEANUP:
    DiagLog("stream cleanup begin");
    watchStop = true;
    if (connectionWatch.joinable()) connectionWatch.join();
    timeEndPeriod(1);
    if (packetSenderStarted) packetSender.Stop();
    StopIproxyProcess(iproxyPI);
    nativeEnc.Shutdown();
    desktopCursor.Shutdown();
    if (enc)     enc->Release();
    if (devMgr)  devMgr->Release();
    if (dupl && duplicationFrameOwned) { dupl->ReleaseFrame(); duplicationFrameOwned = false; }
    if (gpuTex)  gpuTex->Release();
    if (sTex)    sTex->Release();
    if (dupl)    dupl->Release();
    if (output1) output1->Release();
    if (output)  output->Release();
    if (adapter) adapter->Release();
    if (factory) factory->Release();
    if (ctx)     ctx->Release();
    if (dev)     dev->Release();
    DisconnectVirtualDisplay();
    if (cS != INVALID_SOCKET) closesocket(cS);
    WSACleanup(); MFShutdown(); CoUninitialize();
    g_streaming.store(false);
    PostStatus(SS_DISCONNECTED);
    DiagLog("stream cleanup end");
}

// ═══════════════════════════════════════════════════════════════════
// DEVICE DETECTION
// ═══════════════════════════════════════════════════════════════════

static bool ValidDeviceUdid(const std::string& udid) {
    if (udid.empty() || udid.size() > 64) return false;
    for (char c : udid) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
        (c >= 'A' && c <= 'F') || c == '-')) return false;
    return true;
}

static std::string RunIdeviceinfo(const char* key, const std::string& udid, bool simple) {
    if (!udid.empty() && !ValidDeviceUdid(udid)) return "";
    std::string toolDir = EnsureBundledToolsDirA();
    std::string cmdLine = "\"" + toolDir + "\\ideviceinfo.exe\" -k " + key;
    if (!udid.empty()) cmdLine += " -u " + udid;
    if (simple) cmdLine += " -s";
    std::vector<char> cmd(cmdLine.begin(), cmdLine.end());
    cmd.push_back('\0');

    SECURITY_ATTRIBUTES sa{}; sa.nLength = sizeof(sa); sa.bInheritHandle = TRUE;
    HANDLE hR, hW;
    if (!CreatePipe(&hR, &hW, &sa, 0)) return "";
    SetHandleInformation(hR, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si{}; si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.hStdOutput = hW; si.hStdError = hW; si.wShowWindow = SW_HIDE;

    PROCESS_INFORMATION pi{};
    std::string result;
    if (CreateProcessA(NULL, cmd.data(), NULL, NULL, TRUE,
        CREATE_NO_WINDOW, NULL, toolDir.c_str(), &si, &pi)) {
        CloseHandle(hW);
        ULONGLONG deadline = GetTickCount64() + 2000;
        bool finished = false;
        while (!g_closing.load() && GetTickCount64() < deadline) {
            DWORD available = 0;
            if (!PeekNamedPipe(hR, nullptr, 0, nullptr, &available, nullptr)) {
                // A tool can close stdout just before its process exits. Wait
                // within the same deadline so valid output is not discarded.
                if (GetLastError() == ERROR_BROKEN_PIPE &&
                    WaitForSingleObject(pi.hProcess, 25) == WAIT_TIMEOUT) continue;
                break;
            }
            if (available) {
                char buf[256]; DWORD count = 0;
                if (!ReadFile(hR, buf, (std::min)(available, (DWORD)sizeof(buf)), &count, nullptr)) break;
                result.append(buf, count);
                if (result.size() > 4096) break;
            } else if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) {
                finished = true; break;
            } else Sleep(25);
        }
        finished = WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0;
        DWORD exitCode = STILL_ACTIVE;
        GetExitCodeProcess(pi.hProcess, &exitCode);
        if (!finished || exitCode != 0 || result.size() > 4096) {
            if (exitCode == STILL_ACTIVE) {
                TerminateProcess(pi.hProcess, ERROR_CANCELLED);
                WaitForSingleObject(pi.hProcess, 1000);
            }
            result.clear();
        }
        CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    }
    else { CloseHandle(hW); }
    CloseHandle(hR);

    while (!result.empty() && (result.back() == '\n' || result.back() == '\r' || result.back() == ' '))
        result.pop_back();
    return result;
}

static std::wstring g_detectedName;
static bool         g_detectFound = false;

static void DetectThread(HWND target) {
    const ModeOption previous{g_targetW, g_targetH, g_targetFPS.load()};
    const std::string previousProductType = g_detectedProductType;
    std::string pt = RunIdeviceinfo("ProductType");
    std::string udid = pt.rfind("iPad", 0) == 0 ? RunIdeviceinfo("UniqueDeviceID") : "";
    if (!ValidDeviceUdid(udid)) { pt.clear(); udid.clear(); }
    g_detectionSameDevice = !udid.empty() && udid == g_detectedUdid;
    if (pt.empty() && g_detectFound && ++g_detectionMisses < 2) {
        g_detectionSameDevice = true;
        PostMessage(target, WM_DETECT_DONE, 0, 0);
        return;
    }
    if (!pt.empty()) g_detectionMisses = 0;
    g_detectedUdid = udid;

    g_detectFound = false;
    g_modeCount = 0;
    g_nativeW = 0;
    g_nativeH = 0;
    g_detectedProductType.clear();

    for (int i = 0; i < IPAD_DEF_COUNT; i++) {
        if (pt == g_ipadDefs[i].productType) {
            const iPadDef& d = g_ipadDefs[i];
            g_detectedName = d.displayName;
            g_detectFound = true;
            g_detectedProductType = pt;
            g_nativeW = d.w;
            g_nativeH = d.h;
            const auto choices = winsideusb::BuildKnownModes(d.w, d.h, d.maxFPS);
            for (int index = 0; index < choices.count; ++index) {
                const ModeOption& mode = choices.modes[index];
                AddModeOption(mode.w, mode.h, mode.fps, mode.profile);
            }
            break;
        }
    }

    if (!g_detectFound) {
        if (pt.rfind("iPad", 0) == 0) {
            g_detectedName = L"Unknown iPad (";
            for (char c : pt) g_detectedName += (wchar_t)c;
            g_detectedName += L")";
            g_detectFound = true;
            g_detectedProductType = pt;
            AddModeOption(2360, 1640, 60);
            AddModeOption(2048, 1536, 60);
            AddModeOption(1920, 1080, 60);
            AddModeOption(1024, 768, 60);
        }
        else if (!pt.empty()) {
            g_detectedName = L"Unknown (";
            for (char c : pt) g_detectedName += (wchar_t)c;
            g_detectedName += L")";
        }
        else {
            g_detectedName = L"No device found";
        }
        if (!g_detectFound)
            DisconnectVirtualDisplay();
    }

    if (g_detectFound)
        RestoreModeSelection(previous, g_detectionSameDevice && pt == previousProductType);
    PostMessage(target, WM_DETECT_DONE, 0, 0);
}

static void OnDetectionStarted(HWND hwnd);
static void OnStreamStarting(HWND hwnd);
static void OnStreamStopping(HWND hwnd);
static void OnUiStreamEnded(HWND hwnd);

static void TriggerDetect(HWND hwnd, bool quiet = false) {
    if (g_streaming.load() || g_streamCompletionPending || g_closing.load()) return;
    bool expected = false;
    if (!g_detecting.compare_exchange_strong(expected, true)) return;
    if (g_detectThread.joinable()) g_detectThread.join();
    if (!quiet) OnDetectionStarted(hwnd);
    g_detectThread = std::thread(DetectThread, hwnd);
}

// ═══════════════════════════════════════════════════════════════════
// STREAM CONTROL
// ═══════════════════════════════════════════════════════════════════

static void StartStream(HWND hwnd) {
    if (g_streaming.load() || g_streamCompletionPending || g_detecting.load() ||
        g_closing.load() || !g_detectFound || g_modeCount <= 0) return;
    if (g_streamThread.joinable()) g_streamThread.join();
    g_stop = false;
    SetStreamError(L"");
    g_streamCompletionPending = true;
    g_streaming.store(true);
    OnStreamStarting(hwnd);
    g_streamThread = std::thread(StreamThread);
}

static void StopStream(HWND hwnd) {
    g_autoStartSuppressed = true;
    g_stop = true;
    if (g_streaming.load()) OnStreamStopping(hwnd);
    if (!g_streamCompletionPending) DisconnectVirtualDisplay();
}

static void OnStreamEnded(HWND hwnd) {
    DisconnectVirtualDisplay();
    g_streamCompletionPending = false;
    g_nextAutoAttempt = GetTickCount64() + 3000;
    OnUiStreamEnded(hwnd);
}

// ═══════════════════════════════════════════════════════════════════
// TRAY
// ═══════════════════════════════════════════════════════════════════

static void AddTrayIcon(HWND hwnd) {
    if (g_trayActive) return;
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = hwnd;
    g_nid.uID = TRAY_ID;
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    g_nid.uCallbackMessage = WM_TRAY_MSG;
    g_nid.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    lstrcpyW(g_nid.szTip, L"WinSideUSB");
    Shell_NotifyIconW(NIM_ADD, &g_nid);
    g_trayActive = true;
}

static void RemoveTrayIcon() {
    if (!g_trayActive) return;
    Shell_NotifyIconW(NIM_DELETE, &g_nid);
    g_trayActive = false;
}

static void ShowTrayMenu(HWND hwnd) {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, IDM_SHOW, L"Show");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, IDM_EXIT, L"Exit");
    SetForegroundWindow(hwnd);
    POINT pt; GetCursorPos(&pt);
    TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_LEFTALIGN, pt.x, pt.y, 0, hwnd, nullptr);
    DestroyMenu(menu);
}

// ═══════════════════════════════════════════════════════════════════
// WINDOW
// ═══════════════════════════════════════════════════════════════════

#include "WindowUI.h"

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int nShow) {
    HANDLE instanceMutex = CreateMutexW(nullptr, TRUE, L"Local\\WinSideUSB.App");
    if (instanceMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND existing = FindWindowW(L"WinSideUSBWnd", nullptr);
        if (existing) { ShowWindow(existing, SW_RESTORE); SetForegroundWindow(existing); }
        CloseHandle(instanceMutex);
        return 0;
    }
    // Match native controls, typography and vector artwork to the current monitor.
    typedef BOOL(WINAPI* DpiAwarenessFn)(DPI_AWARENESS_CONTEXT);
    DpiAwarenessFn setDpi = (DpiAwarenessFn)GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetProcessDpiAwarenessContext");
    if (!setDpi || !setDpi(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) SetProcessDPIAware();
    g_uiDpi = WindowDpi(nullptr);
    INITCOMMONCONTROLSEX controls{ sizeof(controls), ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&controls);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = L"WinSideUSBWnd";
    wc.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
    RegisterClassExW(&wc);

    RECT r = { 0, 0, Dip(WIN_W), Dip(WIN_H) };
    typedef BOOL(WINAPI* AdjustDpiFn)(LPRECT, DWORD, BOOL, DWORD, UINT);
    AdjustDpiFn adjustDpi = (AdjustDpiFn)GetProcAddress(GetModuleHandleW(L"user32.dll"), "AdjustWindowRectExForDpi");
    if (adjustDpi) adjustDpi(&r, UI_WINDOW_STYLE, FALSE, 0, g_uiDpi);
    else AdjustWindowRectEx(&r, UI_WINDOW_STYLE, FALSE, 0);

    g_hwnd = CreateWindowExW(0, L"WinSideUSBWnd", L"WinSideUSB",
        UI_WINDOW_STYLE | WS_CLIPCHILDREN,
        CW_USEDEFAULT, CW_USEDEFAULT,
        r.right - r.left, r.bottom - r.top,
        nullptr, nullptr, hInst, nullptr);

    ShowWindow(g_hwnd, nShow);
    UpdateWindow(g_hwnd);

    MSG m{};
    while (GetMessage(&m, nullptr, 0, 0)) {
        if (IsDialogMessageW(g_hwnd, &m)) continue;
        TranslateMessage(&m);
        DispatchMessage(&m);
    }

    g_stop = true;
    g_closing = true;
    if (g_streamThread.joinable()) g_streamThread.join();
    if (g_detectThread.joinable()) g_detectThread.join();
    DisconnectVirtualDisplay();
    if (instanceMutex) CloseHandle(instanceMutex);
    return (int)m.wParam;
}
