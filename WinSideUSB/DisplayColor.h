#pragma once
#include <Windows.h>
#include <atomic>
#include <string>

namespace winsideusb::display_color_detail {

// SDK packet layouts, including the Windows 11 24H2 HDR/WCG split. Keeping
// these local also permits building with SDK headers whose NTDDI defaults hide them.
struct ColorInfo2 {
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    UINT32 value, encoding, bitsPerChannel, activeMode;
};
struct SetColor { DISPLAYCONFIG_DEVICE_INFO_HEADER header; UINT32 value; };
static_assert(sizeof(ColorInfo2) == 36 && sizeof(SetColor) == 24, "Display color packet layout");
using DeviceInfoCall = LONG(WINAPI*)(DISPLAYCONFIG_DEVICE_INFO_HEADER*);
using PauseCall = void(WINAPI*)(DWORD);

struct ColorState {
    bool known = false, modern = false, hdr = false, wcg = false, active = false;
    UINT bitsPerChannel = 0;
};

inline DISPLAYCONFIG_DEVICE_INFO_HEADER Header(const DISPLAYCONFIG_PATH_INFO& path,
    UINT type, UINT size) {
    return { static_cast<DISPLAYCONFIG_DEVICE_INFO_TYPE>(type), size,
        path.targetInfo.adapterId, path.targetInfo.id };
}

inline bool Unsupported(LONG code) {
    return code == ERROR_INVALID_PARAMETER || code == ERROR_NOT_SUPPORTED || code == ERROR_INVALID_FUNCTION;
}

inline LONG Read(const DISPLAYCONFIG_PATH_INFO& path, ColorState& state,
    DeviceInfoCall get = DisplayConfigGetDeviceInfo) {
    state = {};
    ColorInfo2 info{};
    info.header = Header(path, 15, sizeof(info));
    LONG code = get(&info.header);
    if (code == ERROR_SUCCESS) {
        state.known = state.modern = true;
        state.hdr = (info.value & (1u << 5)) != 0 || info.activeMode == 2;
        state.wcg = (info.value & (1u << 7)) != 0 || info.activeMode == 1;
        state.active = (info.value & (1u << 1)) != 0 || info.activeMode != 0;
        state.bitsPerChannel = info.bitsPerChannel;
        return ERROR_SUCCESS;
    }
    if (!Unsupported(code)) return code;
    DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO legacy{};
    legacy.header = Header(path, 9, sizeof(legacy));
    code = get(&legacy.header);
    if (code == ERROR_SUCCESS) {
        state.known = true;
        state.active = state.hdr = legacy.advancedColorEnabled != 0;
        state.bitsPerChannel = legacy.bitsPerColorChannel;
    }
    // Drivers without Advanced Color support can still provide valid SDR BGRA.
    return Unsupported(code) ? ERROR_SUCCESS : code;
}

inline bool NeedsSdr(const ColorState& state) {
    return state.known && (state.hdr || state.wcg || state.active);
}

// Internal primitive: callers must first validate the exact owned PnP target.
// Injection lets tests assert both the target identity and every packet value.
inline LONG EnsureSdr(const DISPLAYCONFIG_PATH_INFO& path, bool& changed,
    const std::atomic<bool>* cancel = nullptr, DeviceInfoCall get = DisplayConfigGetDeviceInfo,
    DeviceInfoCall set = DisplayConfigSetDeviceInfo, PauseCall pause = Sleep) {
    changed = false;
    if (cancel && cancel->load()) return ERROR_CANCELLED;
    ColorState state;
    LONG code = Read(path, state, get);
    if (code != ERROR_SUCCESS || !NeedsSdr(state)) return code;
    auto disable = [&](UINT type) {
        if (cancel && cancel->load()) return static_cast<LONG>(ERROR_CANCELLED);
        SetColor packet{};
        packet.header = Header(path, type, sizeof(packet));
        const LONG result = set(&packet.header); // value=0: disable only.
        if (result == ERROR_SUCCESS) changed = true;
        return result;
    };
    if (state.modern) {
        if (state.hdr && (code = disable(16)) != ERROR_SUCCESS) return code;
        if (state.wcg && (code = disable(17)) != ERROR_SUCCESS) return code;
        if (!state.hdr && !state.wcg) return ERROR_NOT_SUPPORTED;
    } else if ((code = disable(10)) != ERROR_SUCCESS) return code;
    for (int attempt = 0; attempt < 30; ++attempt) {
        if (cancel && cancel->load()) return ERROR_CANCELLED;
        code = Read(path, state, get);
        if (code == ERROR_SUCCESS && state.known && !NeedsSdr(state)) return ERROR_SUCCESS;
        if (code == ERROR_ACCESS_DENIED) return code;
        pause(50);
    }
    return ERROR_TIMEOUT;
}

} // namespace winsideusb::display_color_detail
