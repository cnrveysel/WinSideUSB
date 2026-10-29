#include "../WinSideUSB/DisplayModes.h"
#include <cstdio>
#include <cstring>
#include <iostream>

int main(int argc, char** argv) {
    using namespace winsideusb;
    if (argc == 2 && std::strcmp(argv[1], "--list-modes") == 0) {
        int width = 0, height = 0, maximum = 0;
        while (std::cin >> width >> height >> maximum) {
            const auto choices = BuildKnownModes(width, height, maximum);
            if (!choices.count) { std::fprintf(stderr, "Invalid native mode input.\n"); return 2; }
            for (int index = 0; index < choices.count; ++index) {
                const auto& mode = choices.modes[index];
                std::printf("%d,%d,%d\n", mode.w, mode.h, mode.fps);
            }
        }
        return std::cin.eof() ? 0 : 2;
    }
    if (argc != 1) return 2;

    int failures = 0;
    auto check = [&](bool success, const char* description) {
        std::printf("%s %s\n", success ? "PASS" : "FAIL", description);
        if (!success) ++failures;
    };
    const auto pro = BuildKnownModes(2732, 2048, 120);
    check(pro.count == 6 && pro.modes[0].profile == DisplayProfile::Native &&
        SameMode(pro.modes[0], {2732, 2048, 120}) && SameMode(pro.modes[1], {2732, 2048, 60}),
        "native default and both supported refresh rates remain first");
    check(SameMode(pro.modes[2], {2048, 1536, 120}) &&
        pro.modes[2].profile == DisplayProfile::Balanced &&
        SameMode(pro.modes[4], {1366, 1024, 120}) && pro.modes[4].profile == DisplayProfile::LaptopSize,
        "M2 iPad profiles have the intended desktop sizes");
    check(FindModeIndex(pro, {1366, 1024, 120}) == 4 && FindModeIndex(pro, {1366, 1024, 240}) == -1 &&
        FindModeIndex(pro, {1920, 1080, 120}) == -1,
        "saved choices match only the regenerated resolution and refresh list");

    const int nativeSizes[][2] = {
        {2752, 2064}, {2732, 2048}, {2420, 1668}, {2388, 1668}, {2360, 1640},
        {2266, 1488}, {2224, 1668}, {2160, 1620}, {2048, 1536}, {1024, 768}
    };
    bool dimensionsValid = true, ratesCapped = true, unique = true, aspectPreserved = true;
    for (const auto& native : nativeSizes) {
        for (int cap : {60, 120}) {
            const auto choices = BuildKnownModes(native[0], native[1], cap);
            dimensionsValid = dimensionsValid && choices.count > 0 && choices.count <= MaxDisplayModes;
            for (int index = 0; index < choices.count; ++index) {
                const auto& mode = choices.modes[index];
                dimensionsValid = dimensionsValid && mode.w > 0 && mode.h > 0 &&
                    !(mode.w & 1) && !(mode.h & 1) && mode.w <= native[0] && mode.h <= native[1] &&
                    (mode.profile == DisplayProfile::Native || (mode.w >= 800 && mode.h >= 600));
                ratesCapped = ratesCapped && mode.fps <= cap && (mode.fps == 60 || mode.fps == 120);
                for (int previous = 0; previous < index; ++previous)
                    unique = unique && !SameMode(mode, choices.modes[previous]);
                const double relativeAspect = static_cast<double>(mode.w) * native[1] /
                    (static_cast<double>(mode.h) * native[0]);
                aspectPreserved = aspectPreserved && relativeAspect > 0.998 && relativeAspect < 1.002;
            }
        }
    }
    check(dimensionsValid, "all supported panel families stay encoder-aligned and reduced profiles remain usable");
    check(ratesCapped, "60 Hz iPads never receive 120 Hz choices");
    check(unique && aspectPreserved, "choices are unique and preserve the panel aspect within 0.2 percent");
    const auto oldPad = BuildKnownModes(1024, 768, 60);
    check(oldPad.count == 1 && SameMode(oldPad.modes[0], {1024, 768, 60}),
        "small iPads retain native mode without unusable reduced desktops");
    const auto evenHalf = ProfileDimensions(2266, 1488, DisplayProfile::LaptopSize);
    const auto balancedFourThree = ProfileDimensions(2160, 1620, DisplayProfile::Balanced);
    check(evenHalf.w == 1132 && evenHalf.h == 744 &&
        balancedFourThree.w == 1616 && balancedFourThree.h == 1212,
        "odd half-width and 4:3 balanced rounding are deterministic");
    check(BuildKnownModes(0, 2048, 120).count == 0 && BuildKnownModes(2733, 2048, 120).count == 0 &&
        BuildKnownModes(2732, 2048, 30).count == 0 && BuildKnownModes(2732, 2048, 90).modes[0].fps == 60,
        "invalid native inputs and intermediate refresh caps fail safely");
    std::printf("failures=%d\n", failures);
    return failures ? 1 : 0;
}
