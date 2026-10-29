#pragma once

#include <array>
#include <initializer_list>

namespace winsideusb {

enum class DisplayProfile { Native, Balanced, LaptopSize, Fallback };

struct ModeOption {
    int w = 0;
    int h = 0;
    int fps = 0;
    DisplayProfile profile = DisplayProfile::Fallback;
};

struct ModeDimensions { int w = 0; int h = 0; };

inline constexpr int MaxDisplayModes = 8;
struct DisplayModeList {
    std::array<ModeOption, MaxDisplayModes> modes{};
    int count = 0;
};

// Both encoder paths require even NV12 dimensions. Balanced keeps the 4:3
// panel family exactly 4:3, including the almost-4:3 2732 x 2048 panel.
inline ModeDimensions ProfileDimensions(int nativeW, int nativeH, DisplayProfile profile) {
    if (nativeW <= 0 || nativeH <= 0) return {};
    if (profile == DisplayProfile::Native) return {nativeW, nativeH};
    if (profile == DisplayProfile::LaptopSize) return {(nativeW / 2) & ~1, (nativeH / 2) & ~1};
    if (profile != DisplayProfile::Balanced) return {};
    int width = static_cast<int>((3LL * nativeW) / 4) & ~1;
    int height = static_cast<int>((3LL * nativeH) / 4) & ~1;
    const long long ratioDelta = 3LL * nativeW - 4LL * nativeH;
    if (ratioDelta >= -8 && ratioDelta <= 8) {
        const int horizontalUnits = width / 4;
        const int verticalUnits = height / 3;
        const int units = (horizontalUnits < verticalUnits ? horizontalUnits : verticalUnits) & ~1;
        width = 4 * units;
        height = 3 * units;
    }
    return {width, height};
}

inline bool SameMode(const ModeOption& left, const ModeOption& right) {
    return left.w == right.w && left.h == right.h && left.fps == right.fps;
}

inline int FindModeIndex(const DisplayModeList& choices, const ModeOption& requested) {
    for (int index = 0; index < choices.count; ++index)
        if (SameMode(choices.modes[index], requested)) return index;
    return -1;
}

inline bool AddDisplayMode(DisplayModeList& choices, const ModeOption& mode) {
    if (mode.w <= 0 || mode.h <= 0 || (mode.w & 1) || (mode.h & 1) ||
        (mode.fps != 60 && mode.fps != 120) || choices.count >= MaxDisplayModes ||
        FindModeIndex(choices, mode) >= 0) return false;
    choices.modes[choices.count++] = mode;
    return true;
}

// Native is always first at the highest supported 60/120 Hz rate. Reduced
// profiles never imply a Windows DPI change or promise native image detail.
inline DisplayModeList BuildKnownModes(int nativeW, int nativeH, int maxFPS) {
    DisplayModeList result;
    if (nativeW <= 0 || nativeH <= 0 || (nativeW & 1) || (nativeH & 1) || maxFPS < 60)
        return result;
    const int highestFPS = maxFPS >= 120 ? 120 : 60;
    for (DisplayProfile profile : {DisplayProfile::Native, DisplayProfile::Balanced, DisplayProfile::LaptopSize}) {
        const ModeDimensions size = ProfileDimensions(nativeW, nativeH, profile);
        if (profile != DisplayProfile::Native && (size.w < 800 || size.h < 600)) continue;
        AddDisplayMode(result, {size.w, size.h, highestFPS, profile});
        if (highestFPS > 60) AddDisplayMode(result, {size.w, size.h, 60, profile});
    }
    return result;
}

} // namespace winsideusb
