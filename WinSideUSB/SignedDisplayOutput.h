#pragma once

#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>
#include "DisplayColor.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "dxgi.lib")

namespace winsideusb {

struct ManagedDisplayTarget {
    DISPLAYCONFIG_PATH_INFO path{};
    std::wstring instanceId;
    std::wstring adapterDevicePath;
    std::wstring gdiName;
};

struct DisplayDeviceState {
    std::wstring gdiName;
    DEVMODEW mode{};
    bool primary = false;
};

// Capture before the service enables the managed device. Restore is for a failed
// activation only; restoring on normal disconnect would overwrite user changes.
struct DisplayStateSnapshot {
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    std::vector<DisplayDeviceState> devices;
};

namespace display_detail {

inline bool EqualName(const std::wstring& left, const std::wstring& right) {
    return !left.empty() && !right.empty() && _wcsicmp(left.c_str(), right.c_str()) == 0;
}

inline bool EqualLuid(const LUID& left, const LUID& right) {
    return left.HighPart == right.HighPart && left.LowPart == right.LowPart;
}

inline bool ExactRefresh(UINT32 numerator, UINT32 denominator, int fps) {
    return fps > 0 && denominator != 0 &&
        static_cast<std::uint64_t>(numerator) ==
        static_cast<std::uint64_t>(fps) * denominator;
}

inline bool EqualRefresh(const DISPLAYCONFIG_RATIONAL& left,
    const DISPLAYCONFIG_RATIONAL& right) {
    return left.Denominator != 0 && right.Denominator != 0 &&
        static_cast<std::uint64_t>(left.Numerator) * right.Denominator ==
        static_cast<std::uint64_t>(right.Numerator) * left.Denominator;
}

inline bool ExactMode(const DEVMODEW& mode, int width, int height, int fps) {
    const DWORD required = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;
    return width > 0 && height > 0 && fps > 0 &&
        (mode.dmFields & required) == required && mode.dmPelsWidth == static_cast<DWORD>(width) &&
        mode.dmPelsHeight == static_cast<DWORD>(height) &&
        mode.dmDisplayFrequency == static_cast<DWORD>(fps) && mode.dmBitsPerPel == 32 &&
        (mode.dmDisplayFlags & DM_INTERLACED) == 0 && mode.dmDisplayOrientation == DMDO_DEFAULT;
}

// Adjacent to the rightmost monitor, rather than the top-right corner of a
// bounding box (which can be empty for diagonally arranged physical monitors).
inline bool PlanRightPosition(const std::vector<DisplayDeviceState>& devices,
    const std::wstring& excludedGdiName, POINTL& position) {
    bool found = false;
    std::int64_t rightmost = (std::numeric_limits<std::int64_t>::min)();
    LONG top = 0;
    for (const auto& device : devices) {
        if (EqualName(device.gdiName, excludedGdiName) ||
            device.mode.dmPelsWidth == 0 || device.mode.dmPelsHeight == 0) continue;
        const auto right = static_cast<std::int64_t>(device.mode.dmPosition.x) + device.mode.dmPelsWidth;
        if (!found || right > rightmost || (right == rightmost && device.mode.dmPosition.y < top)) {
            rightmost = right;
            top = device.mode.dmPosition.y;
            found = true;
        }
    }
    if (!found || rightmost > (std::numeric_limits<LONG>::max)() ||
        rightmost < (std::numeric_limits<LONG>::min)()) return false;
    position.x = static_cast<LONG>(rightmost);
    position.y = top;
    return true;
}

inline bool SameDeviceState(const DisplayDeviceState& left, const DisplayDeviceState& right) {
    return EqualName(left.gdiName, right.gdiName) && left.primary == right.primary &&
        left.mode.dmPelsWidth == right.mode.dmPelsWidth && left.mode.dmPelsHeight == right.mode.dmPelsHeight &&
        left.mode.dmPosition.x == right.mode.dmPosition.x && left.mode.dmPosition.y == right.mode.dmPosition.y &&
        left.mode.dmBitsPerPel == right.mode.dmBitsPerPel &&
        left.mode.dmDisplayFrequency == right.mode.dmDisplayFrequency &&
        left.mode.dmDisplayOrientation == right.mode.dmDisplayOrientation &&
        left.mode.dmDisplayFlags == right.mode.dmDisplayFlags &&
        left.mode.dmDisplayFixedOutput == right.mode.dmDisplayFixedOutput;
}

inline std::wstring ErrorCode(const wchar_t* operation, LONG code) {
    return std::wstring(operation) + L" (error " + std::to_wstring(code) + L")";
}

inline bool QueryPaths(UINT32 kind, DisplayStateSnapshot& snapshot, std::wstring& error) {
    const UINT32 flags = kind | QDC_VIRTUAL_MODE_AWARE | QDC_VIRTUAL_REFRESH_RATE_AWARE;
    for (int retry = 0; retry < 6; ++retry) {
        UINT32 pathCount = 0, modeCount = 0;
        LONG code = GetDisplayConfigBufferSizes(flags, &pathCount, &modeCount);
        if (code != ERROR_SUCCESS) { error = ErrorCode(L"GetDisplayConfigBufferSizes", code); return false; }
        // QueryDisplayConfig requires non-null buffers even for zero counts.
        snapshot.paths.resize((std::max)(pathCount, 1u));
        snapshot.modes.resize((std::max)(modeCount, 1u));
        code = QueryDisplayConfig(flags, &pathCount, snapshot.paths.data(), &modeCount,
            snapshot.modes.data(), nullptr);
        if (code == ERROR_INSUFFICIENT_BUFFER) continue;
        if (code != ERROR_SUCCESS) { error = ErrorCode(L"QueryDisplayConfig", code); return false; }
        snapshot.paths.resize(pathCount);
        snapshot.modes.resize(modeCount);
        return true;
    }
    error = L"The display topology kept changing while it was being read.";
    return false;
}

inline bool AdapterName(const LUID& adapter, std::wstring& name) {
    DISPLAYCONFIG_ADAPTER_NAME info{};
    info.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME;
    info.header.size = sizeof(info);
    info.header.adapterId = adapter;
    if (DisplayConfigGetDeviceInfo(&info.header) != ERROR_SUCCESS) return false;
    name = info.adapterDevicePath;
    return !name.empty();
}

inline bool SourceName(const DISPLAYCONFIG_PATH_INFO& path, std::wstring& name) {
    DISPLAYCONFIG_SOURCE_DEVICE_NAME info{};
    info.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    info.header.size = sizeof(info);
    info.header.adapterId = path.sourceInfo.adapterId;
    info.header.id = path.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo(&info.header) != ERROR_SUCCESS) return false;
    name = info.viewGdiDeviceName;
    return !name.empty();
}

inline bool ManagedAdapterInterfaces(const std::wstring& instance,
    std::vector<std::wstring>& names, std::wstring& error) {
    // GUID_DEVINTERFACE_DISPLAY_ADAPTER, without depending on an external GUID definition.
    const GUID interfaceGuid = { 0x5b45201d, 0xf2f2, 0x4f3b, { 0x85, 0xbb, 0x30, 0xff, 0x1f, 0x95, 0x35, 0x99 } };
    HDEVINFO devices = SetupDiGetClassDevsW(&interfaceGuid, nullptr, nullptr,
        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devices == INVALID_HANDLE_VALUE) { error = ErrorCode(L"SetupDiGetClassDevs", GetLastError()); return false; }
    names.clear();
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA iface{};
        iface.cbSize = sizeof(iface);
        if (!SetupDiEnumDeviceInterfaces(devices, nullptr, &interfaceGuid, index, &iface)) {
            const DWORD code = GetLastError();
            SetupDiDestroyDeviceInfoList(devices);
            if (code != ERROR_NO_MORE_ITEMS) { error = ErrorCode(L"SetupDiEnumDeviceInterfaces", code); return false; }
            if (names.empty()) { error = L"The managed display adapter is not available yet."; return false; }
            return true;
        }
        DWORD bytes = 0;
        SetupDiGetDeviceInterfaceDetailW(devices, &iface, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<BYTE> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        SP_DEVINFO_DATA device{};
        device.cbSize = sizeof(device);
        if (!SetupDiGetDeviceInterfaceDetailW(devices, &iface, detail, bytes, nullptr, &device)) continue;
        wchar_t actual[MAX_DEVICE_ID_LEN]{};
        if (SetupDiGetDeviceInstanceIdW(devices, &device, actual, MAX_DEVICE_ID_LEN, nullptr) &&
            EqualName(instance, actual)) names.emplace_back(detail->DevicePath);
    }
}

inline bool IsManagedPath(const DISPLAYCONFIG_PATH_INFO& path,
    const std::vector<std::wstring>& interfaces) {
    std::wstring name;
    if (!AdapterName(path.targetInfo.adapterId, name)) return false;
    for (const auto& iface : interfaces) if (EqualName(iface, name)) return true;
    return false;
}

inline bool SamePathIdentity(const DISPLAYCONFIG_PATH_INFO& left, const DISPLAYCONFIG_PATH_INFO& right) {
    return EqualLuid(left.sourceInfo.adapterId, right.sourceInfo.adapterId) &&
        left.sourceInfo.id == right.sourceInfo.id && EqualLuid(left.targetInfo.adapterId, right.targetInfo.adapterId) &&
        left.targetInfo.id == right.targetInfo.id;
}

inline const DISPLAYCONFIG_MODE_INFO* PathMode(const DisplayStateSnapshot& state,
    const DISPLAYCONFIG_PATH_INFO& path, bool source) {
    const bool virtualMode = (path.flags & DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE) != 0;
    const UINT32 index = source ? (virtualMode ? path.sourceInfo.sourceModeInfoIdx : path.sourceInfo.modeInfoIdx) :
        (virtualMode ? path.targetInfo.targetModeInfoIdx : path.targetInfo.modeInfoIdx);
    if (index >= state.modes.size()) return nullptr;
    const auto& mode = state.modes[index];
    if (mode.infoType != (source ? DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE : DISPLAYCONFIG_MODE_INFO_TYPE_TARGET)) return nullptr;
    return &mode;
}

inline bool ExactPathMode(const DisplayStateSnapshot& state, const DISPLAYCONFIG_PATH_INFO& path,
    int width, int height, int fps) {
    const auto* source = PathMode(state, path, true);
    const auto* target = PathMode(state, path, false);
    if (!source || !target || width <= 0 || height <= 0 ||
        path.targetInfo.rotation != DISPLAYCONFIG_ROTATION_IDENTITY ||
        !ExactRefresh(path.targetInfo.refreshRate.Numerator, path.targetInfo.refreshRate.Denominator, fps)) return false;
    const auto& signal = target->targetMode.targetVideoSignalInfo;
    return source->sourceMode.width == static_cast<UINT32>(width) &&
        source->sourceMode.height == static_cast<UINT32>(height) &&
        signal.activeSize.cx == static_cast<UINT32>(width) && signal.activeSize.cy == static_cast<UINT32>(height) &&
        ExactRefresh(signal.vSyncFreq.Numerator, signal.vSyncFreq.Denominator, fps) &&
        signal.scanLineOrdering == DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
}

inline bool SamePathState(const DisplayStateSnapshot& before, const DISPLAYCONFIG_PATH_INFO& left,
    const DisplayStateSnapshot& after, const DISPLAYCONFIG_PATH_INFO& right) {
    if (!SamePathIdentity(left, right) || left.targetInfo.rotation != right.targetInfo.rotation ||
        left.targetInfo.scaling != right.targetInfo.scaling ||
        !EqualRefresh(left.targetInfo.refreshRate, right.targetInfo.refreshRate) ||
        left.targetInfo.scanLineOrdering != right.targetInfo.scanLineOrdering) return false;
    const auto* leftSource = PathMode(before, left, true);
    const auto* rightSource = PathMode(after, right, true);
    const auto* leftTarget = PathMode(before, left, false);
    const auto* rightTarget = PathMode(after, right, false);
    if (!leftSource || !rightSource || !leftTarget || !rightTarget) return false;
    const auto& a = leftSource->sourceMode;
    const auto& b = rightSource->sourceMode;
    if (a.width != b.width || a.height != b.height || a.pixelFormat != b.pixelFormat ||
        a.position.x != b.position.x || a.position.y != b.position.y) return false;
    const auto& x = leftTarget->targetMode.targetVideoSignalInfo;
    const auto& y = rightTarget->targetMode.targetVideoSignalInfo;
    return x.activeSize.cx == y.activeSize.cx && x.activeSize.cy == y.activeSize.cy &&
        x.totalSize.cx == y.totalSize.cx && x.totalSize.cy == y.totalSize.cy && x.pixelRate == y.pixelRate &&
        EqualRefresh(x.vSyncFreq, y.vSyncFreq) && EqualRefresh(x.hSyncFreq, y.hSyncFreq) &&
        x.scanLineOrdering == y.scanLineOrdering;
}

inline bool Cancelled(const std::atomic<bool>* cancel) { return cancel && cancel->load(); }

inline bool PlanManagedTopology(const DisplayStateSnapshot& original,
    const ManagedDisplayTarget& target, int width, int height, int fps,
    POINTL position, DisplayStateSnapshot& planned, std::wstring& error) {
    if (original.paths.empty() || original.modes.empty() || width <= 0 || height <= 0 || fps <= 0 ||
        original.modes.size() >= DISPLAYCONFIG_PATH_SOURCE_MODE_IDX_INVALID ||
        !EqualLuid(target.path.sourceInfo.adapterId, target.path.targetInfo.adapterId)) {
        error = L"The supplied display topology is invalid.";
        return false;
    }
    for (const auto& path : original.paths) {
        if (!(path.flags & DISPLAYCONFIG_PATH_ACTIVE) || !PathMode(original, path, true) ||
            !PathMode(original, path, false) || SamePathIdentity(path, target.path)) {
            error = L"The original physical display modes are incomplete or already include the managed screen.";
            return false;
        }
    }
    planned = original;
    auto path = target.path;
    path.flags = DISPLAYCONFIG_PATH_ACTIVE | (path.flags & DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE);
    path.sourceInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
    path.targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
    const UINT32 sourceIndex = static_cast<UINT32>(planned.modes.size());
    if (path.flags & DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE)
        path.sourceInfo.sourceModeInfoIdx = sourceIndex;
    else path.sourceInfo.modeInfoIdx = sourceIndex;
    path.targetInfo.rotation = DISPLAYCONFIG_ROTATION_IDENTITY;
    path.targetInfo.scaling = DISPLAYCONFIG_SCALING_IDENTITY;
    path.targetInfo.refreshRate = {static_cast<UINT32>(fps), 1};
    path.targetInfo.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    path.targetInfo.targetAvailable = TRUE;
    DISPLAYCONFIG_MODE_INFO source{};
    source.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE;
    source.adapterId = path.sourceInfo.adapterId;
    source.id = path.sourceInfo.id;
    source.sourceMode.width = static_cast<UINT32>(width);
    source.sourceMode.height = static_cast<UINT32>(height);
    source.sourceMode.pixelFormat = DISPLAYCONFIG_PIXELFORMAT_32BPP;
    source.sourceMode.position = position;
    planned.modes.push_back(source);
    planned.paths.push_back(path);
    error.clear();
    return true;
}

} // namespace display_detail

inline bool IsExactDuplicationMode(const DXGI_OUTDUPL_DESC& capture, int width, int height, int fps) {
    return width > 0 && height > 0 && capture.ModeDesc.Width == static_cast<UINT>(width) &&
        capture.ModeDesc.Height == static_cast<UINT>(height) && capture.Rotation == DXGI_MODE_ROTATION_IDENTITY &&
        display_detail::ExactRefresh(capture.ModeDesc.RefreshRate.Numerator,
            capture.ModeDesc.RefreshRate.Denominator, fps);
}

inline bool IsExactCaptureTexture(const D3D11_TEXTURE2D_DESC& texture, int width, int height) {
    return width > 0 && height > 0 && texture.Width == static_cast<UINT>(width) &&
        texture.Height == static_cast<UINT>(height) && texture.Format == DXGI_FORMAT_B8G8R8A8_UNORM &&
        texture.MipLevels == 1 && texture.ArraySize == 1 && texture.SampleDesc.Count == 1 &&
        texture.SampleDesc.Quality == 0;
}

inline bool CaptureDisplayState(DisplayStateSnapshot& snapshot, std::wstring& error) {
    snapshot = {};
    if (!display_detail::QueryPaths(QDC_ONLY_ACTIVE_PATHS, snapshot, error)) return false;
    for (DWORD index = 0;; ++index) {
        DISPLAY_DEVICEW device{};
        device.cb = sizeof(device);
        if (!EnumDisplayDevicesW(nullptr, index, &device, 0)) break;
        if ((device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0 ||
            (device.StateFlags & DISPLAY_DEVICE_MIRRORING_DRIVER) != 0) continue;
        DisplayDeviceState state{};
        state.gdiName = device.DeviceName;
        state.mode.dmSize = sizeof(state.mode);
        if (!EnumDisplaySettingsExW(device.DeviceName, ENUM_CURRENT_SETTINGS, &state.mode, 0)) {
            error = L"Could not read the current mode of " + state.gdiName;
            return false;
        }
        state.primary = (device.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;
        snapshot.devices.push_back(state);
    }
    if (snapshot.devices.empty()) { error = L"No active Windows desktop display is available."; return false; }
    error.clear();
    return true;
}

inline bool RestoreDisplayState(const DisplayStateSnapshot& snapshot, std::wstring& error) {
    if (snapshot.paths.empty() || snapshot.modes.empty()) { error = L"There is no original display topology to restore."; return false; }
    auto paths = snapshot.paths;
    auto modes = snapshot.modes;
    const LONG code = SetDisplayConfig(static_cast<UINT32>(paths.size()), paths.data(),
        static_cast<UINT32>(modes.size()), modes.data(), SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG |
        SDC_VIRTUAL_MODE_AWARE | SDC_VIRTUAL_REFRESH_RATE_AWARE);
    if (code != ERROR_SUCCESS) { error = display_detail::ErrorCode(L"Restore display topology", code); return false; }
    error.clear();
    return true;
}

inline bool FindManagedDisplayTarget(const std::wstring& instanceId,
    ManagedDisplayTarget& target, std::wstring& error) {
    target = {};
    // Do not match a friendly name or an arbitrary ROOT device.
    if (instanceId.size() <= 12 || _wcsnicmp(instanceId.c_str(), L"ROOT\\MTTVDD\\", 12) != 0) {
        error = L"The managed display instance identity is invalid.";
        return false;
    }
    std::vector<std::wstring> interfaces;
    if (!display_detail::ManagedAdapterInterfaces(instanceId, interfaces, error)) return false;
    DisplayStateSnapshot all;
    if (!display_detail::QueryPaths(QDC_ALL_PATHS, all, error)) return false;
    bool found = false;
    for (const auto& path : all.paths) {
        if (!path.targetInfo.targetAvailable || !display_detail::IsManagedPath(path, interfaces)) continue;
        std::wstring sourceAdapter, gdiName, adapterName;
        if (!display_detail::AdapterName(path.sourceInfo.adapterId, sourceAdapter) ||
            !display_detail::AdapterName(path.targetInfo.adapterId, adapterName) ||
            !display_detail::EqualName(sourceAdapter, adapterName) ||
            !display_detail::SourceName(path, gdiName)) continue;
        DISPLAY_DEVICEW device{};
        device.cb = sizeof(device);
        bool validGdiName = false;
        for (DWORD index = 0; EnumDisplayDevicesW(nullptr, index, &device, 0); ++index) {
            if (display_detail::EqualName(gdiName, device.DeviceName)) { validGdiName = true; break; }
            device = {}; device.cb = sizeof(device);
        }
        if (!validGdiName) continue;
        if (found && (!display_detail::EqualLuid(target.path.targetInfo.adapterId, path.targetInfo.adapterId) ||
            target.path.targetInfo.id != path.targetInfo.id)) {
            error = L"The managed driver exposed multiple monitors; exactly one is required.";
            return false;
        }
        if (!found || (path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0) {
            target.path = path;
            target.instanceId = instanceId;
            target.adapterDevicePath = adapterName;
            target.gdiName = gdiName;
            found = true;
        }
    }
    if (!found) { error = L"The managed virtual monitor is not available yet."; return false; }
    error.clear();
    return true;
}

inline bool EnsureManagedDisplaySdr(const std::wstring& instanceId, bool& changed,
    std::wstring& error, const std::atomic<bool>* cancel = nullptr) {
    changed = false;
    if (display_detail::Cancelled(cancel)) { error = L"Display activation was cancelled."; return false; }
    ManagedDisplayTarget target;
    // Resolve the owned ROOT\MTTVDD instance again, never a display number or
    // friendly name. This must not affect another monitor's HDR preference.
    if (!FindManagedDisplayTarget(instanceId, target, error)) return false;
    if (!(target.path.flags & DISPLAYCONFIG_PATH_ACTIVE)) {
        error = L"The managed virtual display is not active yet."; return false;
    }
    const LONG code = display_color_detail::EnsureSdr(target.path, changed, cancel);
    if (code != ERROR_SUCCESS) {
        error = display_detail::ErrorCode(L"Restore the iPad virtual display to SDR", code);
        return false;
    }
    error.clear();
    return true;
}

inline bool ValidatePhysicalDisplayState(const DisplayStateSnapshot& original,
    const std::wstring& managedInstance, std::wstring& error) {
    DisplayStateSnapshot current;
    if (!CaptureDisplayState(current, error)) return false;
    std::vector<std::wstring> interfaces;
    // The device can already be disabled when validating a rollback.
    std::wstring ignored;
    display_detail::ManagedAdapterInterfaces(managedInstance, interfaces, ignored);
    std::vector<std::wstring> managedNames;
    for (const auto& path : current.paths) {
        if (!display_detail::IsManagedPath(path, interfaces)) continue;
        std::wstring gdi;
        if (display_detail::SourceName(path, gdi)) managedNames.push_back(gdi);
    }
    for (const auto& device : original.devices) {
        bool managed = false;
        for (const auto& name : managedNames) if (display_detail::EqualName(device.gdiName, name)) managed = true;
        if (managed) continue;
        const auto found = std::find_if(current.devices.begin(), current.devices.end(), [&](const DisplayDeviceState& item) {
            return display_detail::EqualName(item.gdiName, device.gdiName);
        });
        if (found == current.devices.end() || !display_detail::SameDeviceState(device, *found)) {
            error = L"Activation changed the existing display " + device.gdiName + L". The original topology must be restored.";
            return false;
        }
    }
    size_t beforeCount = 0, afterCount = 0;
    for (const auto& path : current.paths) if (!display_detail::IsManagedPath(path, interfaces)) ++afterCount;
    for (const auto& path : original.paths) {
        if (display_detail::IsManagedPath(path, interfaces)) continue;
        ++beforeCount;
        const auto found = std::find_if(current.paths.begin(), current.paths.end(), [&](const DISPLAYCONFIG_PATH_INFO& item) {
            return display_detail::SamePathIdentity(path, item);
        });
        if (found == current.paths.end() || !display_detail::SamePathState(original, path, current, *found)) {
            error = L"Activation changed an existing physical display path. The original topology must be restored.";
            return false;
        }
    }
    if (beforeCount != afterCount) { error = L"The physical display topology changed during activation."; return false; }
    error.clear();
    return true;
}

inline bool ConfigureManagedDisplay(int width, int height, int fps, const std::wstring& managedInstance,
    std::wstring& outGdiName, HMONITOR& outMonitor, std::wstring& error,
    const DisplayStateSnapshot* originalSnapshot = nullptr, const std::atomic<bool>* cancel = nullptr) {
    outGdiName.clear();
    outMonitor = nullptr;
    if (width <= 0 || height <= 0 || fps <= 0) { error = L"The requested display mode is invalid."; return false; }
    DisplayStateSnapshot local;
    if (!originalSnapshot) {
        if (!CaptureDisplayState(local, error)) return false;
        originalSnapshot = &local;
    }
    ManagedDisplayTarget target;
    const ULONGLONG start = GetTickCount64();
    while (!FindManagedDisplayTarget(managedInstance, target, error)) {
        if (display_detail::Cancelled(cancel)) { error = L"Display activation was cancelled."; return false; }
        if (GetTickCount64() - start >= 8000) return false;
        Sleep(100);
    }
    if (!ValidatePhysicalDisplayState(*originalSnapshot, managedInstance, error)) return false;
    bool matched = false;
    for (DWORD index = 0;; ++index) {
        DEVMODEW mode{};
        mode.dmSize = sizeof(mode);
        if (!EnumDisplaySettingsExW(target.gdiName.c_str(), index, &mode, EDS_ROTATEDMODE)) break;
        if (display_detail::ExactMode(mode, width, height, fps)) { matched = true; break; }
    }
    if (!matched) {
        error = L"The virtual driver does not expose the exact requested mode: " + std::to_wstring(width) +
            L" x " + std::to_wstring(height) + L" at " + std::to_wstring(fps) + L" Hz.";
        return false;
    }
    POINTL position{};
    if (!display_detail::PlanRightPosition(originalSnapshot->devices, target.gdiName, position) ||
        static_cast<std::int64_t>(position.x) + width > (std::numeric_limits<LONG>::max)() ||
        static_cast<std::int64_t>(position.y) + height > (std::numeric_limits<LONG>::max)()) {
        error = L"The virtual monitor cannot be positioned beside an existing monitor.";
        return false;
    }
    DisplayStateSnapshot planned;
    if (!display_detail::PlanManagedTopology(*originalSnapshot, target, width, height, fps,
        position, planned, error)) return false;
    // CCD supports attaching an inactive indirect output on current Windows.
    // Preserve every original physical path/mode, then append only this screen.
    // Windows derives the missing managed target timing from its advertised mode
    // and requested refresh; supplied physical modes cannot be adjusted.
    const UINT32 configFlags = SDC_USE_SUPPLIED_DISPLAY_CONFIG |
        SDC_VIRTUAL_MODE_AWARE | SDC_VIRTUAL_REFRESH_RATE_AWARE;
    LONG code = SetDisplayConfig(static_cast<UINT32>(planned.paths.size()), planned.paths.data(),
        static_cast<UINT32>(planned.modes.size()), planned.modes.data(), configFlags | SDC_VALIDATE);
    if (code != ERROR_SUCCESS) { error = display_detail::ErrorCode(L"Test exact virtual display topology", code); return false; }
    if (display_detail::Cancelled(cancel)) { error = L"Display activation was cancelled."; return false; }
    code = SetDisplayConfig(static_cast<UINT32>(planned.paths.size()), planned.paths.data(),
        static_cast<UINT32>(planned.modes.size()), planned.modes.data(), configFlags | SDC_APPLY);
    if (code != ERROR_SUCCESS) { error = display_detail::ErrorCode(L"Set exact virtual display topology", code); return false; }
    for (int attempt = 0; attempt < 30; ++attempt) {
        if (display_detail::Cancelled(cancel)) { error = L"Display activation was cancelled."; return false; }
        ManagedDisplayTarget active;
        std::wstring pending;
        DEVMODEW actual{}; actual.dmSize = sizeof(actual);
        DisplayStateSnapshot activeState;
        const bool foundActive = FindManagedDisplayTarget(managedInstance, active, pending) &&
            (active.path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0;
        // HDR can change the source pixel format, so restore SDR before testing
        // the expected 32-bit mode, not after that test has already failed.
        if (foundActive) {
            bool colorChanged = false;
            if (!EnsureManagedDisplaySdr(managedInstance, colorChanged, error, cancel)) return false;
            if (colorChanged) {
                code = SetDisplayConfig(static_cast<UINT32>(planned.paths.size()), planned.paths.data(),
                    static_cast<UINT32>(planned.modes.size()), planned.modes.data(), configFlags | SDC_APPLY);
                if (code != ERROR_SUCCESS) { error = display_detail::ErrorCode(L"Restore exact virtual display mode after HDR", code); return false; }
                Sleep(100);
                continue;
            }
        }
        if (foundActive &&
            display_detail::QueryPaths(QDC_ONLY_ACTIVE_PATHS, activeState, pending) &&
            std::any_of(activeState.paths.begin(), activeState.paths.end(), [&](const DISPLAYCONFIG_PATH_INFO& path) {
                return display_detail::SamePathIdentity(path, active.path) &&
                    display_detail::ExactPathMode(activeState, path, width, height, fps);
            }) &&
            EnumDisplaySettingsExW(active.gdiName.c_str(), ENUM_CURRENT_SETTINGS, &actual, 0) &&
            display_detail::ExactMode(actual, width, height, fps) &&
            actual.dmPosition.x == position.x && actual.dmPosition.y == position.y) {
            if (!ValidatePhysicalDisplayState(*originalSnapshot, managedInstance, error)) return false;
            struct MonitorSearch { const std::wstring* name; HMONITOR monitor; } search{ &active.gdiName, nullptr };
            EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR monitor, HDC, LPRECT, LPARAM data) -> BOOL {
                auto& item = *reinterpret_cast<MonitorSearch*>(data);
                MONITORINFOEXW info{}; info.cbSize = sizeof(info);
                if (GetMonitorInfoW(monitor, reinterpret_cast<MONITORINFO*>(&info)) &&
                    display_detail::EqualName(*item.name, info.szDevice)) {
                    item.monitor = monitor; return FALSE;
                }
                return TRUE;
            }, reinterpret_cast<LPARAM>(&search));
            if (search.monitor) { outGdiName = active.gdiName; outMonitor = search.monitor; error.clear(); return true; }
        }
        Sleep(100);
    }
    error = L"Windows did not activate the exact requested virtual display resolution and refresh rate.";
    return false;
}

inline bool FindDXGIOutput(IDXGIFactory1* factory, const std::wstring& gdiName,
    IDXGIAdapter1** outAdapter, IDXGIOutput** outOutput) {
    if (outAdapter) *outAdapter = nullptr;
    if (outOutput) *outOutput = nullptr;
    if (!factory || gdiName.empty() || !outAdapter || !outOutput) return false;
    for (UINT adapterIndex = 0;; ++adapterIndex) {
        IDXGIAdapter1* adapter = nullptr;
        if (FAILED(factory->EnumAdapters1(adapterIndex, &adapter)) || !adapter) break;
        for (UINT outputIndex = 0;; ++outputIndex) {
            IDXGIOutput* output = nullptr;
            if (FAILED(adapter->EnumOutputs(outputIndex, &output)) || !output) break;
            DXGI_OUTPUT_DESC desc{};
            if (SUCCEEDED(output->GetDesc(&desc)) && desc.AttachedToDesktop &&
                display_detail::EqualName(gdiName, desc.DeviceName)) {
                *outAdapter = adapter;
                *outOutput = output;
                return true;
            }
            output->Release();
        }
        adapter->Release();
    }
    return false;
}

} // namespace winsideusb
