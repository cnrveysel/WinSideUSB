#include "../WinSideUSB/SignedDisplayOutput.h"
#include <iostream>

namespace {
int checks = 0;
int failures = 0;
struct ColorMock {
    bool modern = true, hdr = true, wcg = false, unsupported = false, stubborn = false;
    bool identityOkay = true, valuesZero = true;
    LONG readError = ERROR_SUCCESS, writeError = ERROR_SUCCESS;
    int reads = 0, pauses = 0;
    std::vector<UINT> writes;
    std::atomic<bool>* cancelOnWrite = nullptr;
} colorMock;

LONG WINAPI ReadColorMock(DISPLAYCONFIG_DEVICE_INFO_HEADER* header) {
    using namespace winsideusb::display_color_detail;
    ++colorMock.reads;
    colorMock.identityOkay &= header->adapterId.LowPart == 42 && header->adapterId.HighPart == 7 && header->id == 8;
    if (colorMock.readError != ERROR_SUCCESS) return colorMock.readError;
    if (colorMock.unsupported) return ERROR_NOT_SUPPORTED;
    if (header->type == static_cast<DISPLAYCONFIG_DEVICE_INFO_TYPE>(15)) {
        if (!colorMock.modern) return ERROR_INVALID_PARAMETER;
        auto& info = *reinterpret_cast<ColorInfo2*>(header);
        info.value = (colorMock.hdr ? (1u << 5) : 0) | (colorMock.wcg ? (1u << 7) : 0);
        info.activeMode = colorMock.hdr ? 2 : colorMock.wcg ? 1 : 0;
        info.bitsPerChannel = colorMock.hdr ? 10 : 8;
    } else {
        auto& info = *reinterpret_cast<DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO*>(header);
        info.advancedColorEnabled = colorMock.hdr;
        info.bitsPerColorChannel = colorMock.hdr ? 10 : 8;
    }
    return ERROR_SUCCESS;
}

LONG WINAPI WriteColorMock(DISPLAYCONFIG_DEVICE_INFO_HEADER* header) {
    colorMock.identityOkay &= header->adapterId.LowPart == 42 && header->adapterId.HighPart == 7 && header->id == 8;
    colorMock.valuesZero &= reinterpret_cast<winsideusb::display_color_detail::SetColor*>(header)->value == 0;
    colorMock.writes.push_back(static_cast<UINT>(header->type));
    if (colorMock.writeError != ERROR_SUCCESS) return colorMock.writeError;
    if (!colorMock.stubborn) {
        if (header->type == static_cast<DISPLAYCONFIG_DEVICE_INFO_TYPE>(17)) colorMock.wcg = false;
        else colorMock.hdr = false;
    }
    if (colorMock.cancelOnWrite) *colorMock.cancelOnWrite = true;
    return ERROR_SUCCESS;
}
void WINAPI PauseColorMock(DWORD) { ++colorMock.pauses; }

void Check(bool result, const char* description) {
    ++checks;
    if (!result) { ++failures; std::cerr << "FAIL: " << description << '\n'; }
}

DEVMODEW Mode(DWORD width, DWORD height, DWORD fps) {
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;
    mode.dmPelsWidth = width; mode.dmPelsHeight = height;
    mode.dmDisplayFrequency = fps; mode.dmBitsPerPel = 32;
    return mode;
}

winsideusb::DisplayDeviceState Device(const wchar_t* name, LONG x, LONG y,
    DWORD width, DWORD height, bool primary = false) {
    winsideusb::DisplayDeviceState device{};
    device.gdiName = name;
    device.mode = Mode(width, height, 60);
    device.mode.dmPosition = { x, y };
    device.primary = primary;
    return device;
}

winsideusb::DisplayStateSnapshot PathFixture() {
    winsideusb::DisplayStateSnapshot result;
    DISPLAYCONFIG_PATH_INFO path{};
    path.flags = DISPLAYCONFIG_PATH_ACTIVE | DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE;
    path.sourceInfo.adapterId = { 42, 7 }; path.sourceInfo.id = 3;
    path.targetInfo.adapterId = path.sourceInfo.adapterId; path.targetInfo.id = 8;
    path.sourceInfo.sourceModeInfoIdx = 0;
    path.targetInfo.targetModeInfoIdx = 1;
    path.targetInfo.refreshRate = { 60000, 1000 };
    path.targetInfo.rotation = DISPLAYCONFIG_ROTATION_IDENTITY;
    path.targetInfo.scaling = DISPLAYCONFIG_SCALING_IDENTITY;
    path.targetInfo.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    DISPLAYCONFIG_MODE_INFO source{};
    source.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE;
    source.sourceMode.width = 1920; source.sourceMode.height = 1080;
    source.sourceMode.pixelFormat = DISPLAYCONFIG_PIXELFORMAT_32BPP;
    DISPLAYCONFIG_MODE_INFO target{};
    target.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_TARGET;
    auto& video = target.targetMode.targetVideoSignalInfo;
    video.activeSize = { 1920, 1080 }; video.totalSize = { 2200, 1125 };
    video.pixelRate = 148500000; video.vSyncFreq = { 60, 1 }; video.hSyncFreq = { 67500, 1 };
    video.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    result.paths.push_back(path);
    result.modes = { source, target };
    return result;
}
}

int main(int argc, char** argv) {
    using namespace winsideusb;
    using namespace winsideusb::display_detail;
    if (argc == 2 && std::string(argv[1]) == "--inspect") {
        DisplayStateSnapshot current;
        std::wstring error;
        if (!CaptureDisplayState(current, error)) { std::wcerr << error << L'\n'; return 1; }
        for (const auto& device : current.devices) {
            std::wcout << device.gdiName << L" " << device.mode.dmPelsWidth << L"x" << device.mode.dmPelsHeight
                << L"@" << device.mode.dmDisplayFrequency << L" position=" << device.mode.dmPosition.x
                << L"," << device.mode.dmPosition.y << L" primary=" << device.primary << L'\n';
        }
        for (const auto& path : current.paths) {
            std::wstring adapter;
            AdapterName(path.targetInfo.adapterId, adapter);
            std::wcout << L"target=" << adapter << L" refresh=" << path.targetInfo.refreshRate.Numerator
                << L"/" << path.targetInfo.refreshRate.Denominator << L'\n';
            display_color_detail::ColorState color;
            const LONG code = display_color_detail::Read(path, color);
            std::wcout << L"color query=" << code << L" known=" << color.known << L" modern=" << color.modern
                << L" HDR=" << color.hdr << L" WCG=" << color.wcg << L" active=" << color.active
                << L" bits=" << color.bitsPerChannel << L'\n';
        }
        return 0;
    }
    {
        using namespace display_color_detail;
        const auto path = PathFixture().paths.front();
        auto recover = [&](bool& changed, const std::atomic<bool>* cancel = nullptr) {
            return EnsureSdr(path, changed, cancel, ReadColorMock, WriteColorMock, PauseColorMock);
        };
        bool changed = false;
        colorMock = {};
        Check(recover(changed) == ERROR_SUCCESS && changed && colorMock.writes == std::vector<UINT>{16} && !colorMock.hdr,
            "modern saved HDR is disabled and verified using only SET_HDR_STATE");
        Check(colorMock.identityOkay && colorMock.valuesZero, "every color request retains the target adapter/id and all set values disable only");
        colorMock = {}; colorMock.hdr = false;
        Check(recover(changed) == ERROR_SUCCESS && !changed && colorMock.writes.empty(), "already SDR output is never changed");
        colorMock.wcg = true;
        Check(recover(changed) == ERROR_SUCCESS && changed && colorMock.writes == std::vector<UINT>{17}, "WCG-only mode uses its own SDR transition");
        colorMock = {}; colorMock.wcg = true;
        Check(recover(changed) == ERROR_SUCCESS && colorMock.writes == std::vector<UINT>({16,17}), "HDR plus saved WCG preference both return to SDR");
        colorMock = {}; colorMock.modern = false;
        Check(recover(changed) == ERROR_SUCCESS && colorMock.writes == std::vector<UINT>{10}, "older Windows uses legacy Advanced Color off");
        colorMock = {}; colorMock.unsupported = true;
        Check(recover(changed) == ERROR_SUCCESS && !changed && colorMock.writes.empty(), "driver without Advanced Color queries is left unchanged");
        colorMock = {}; colorMock.readError = ERROR_ACCESS_DENIED;
        Check(recover(changed) == ERROR_ACCESS_DENIED && colorMock.reads == 1 && colorMock.writes.empty(), "query access error cannot fall through to an unchecked write");
        colorMock = {}; colorMock.writeError = ERROR_ACCESS_DENIED;
        Check(recover(changed) == ERROR_ACCESS_DENIED && !changed, "failed HDR setting is reported without claiming recovery");
        colorMock = {}; colorMock.stubborn = true;
        Check(recover(changed) == ERROR_TIMEOUT && colorMock.pauses == 30, "HDR setting must be verified and recovery wait is bounded");
        std::atomic<bool> cancelled{true};
        colorMock = {};
        Check(recover(changed, &cancelled) == ERROR_CANCELLED && colorMock.reads == 0 && colorMock.writes.empty(), "cancelled recovery makes no color requests");
        cancelled = false; colorMock.cancelOnWrite = &cancelled;
        Check(recover(changed, &cancelled) == ERROR_CANCELLED && colorMock.writes.size() == 1, "cancellation after color change stops further requests");
        std::wstring error;
        Check(!EnsureManagedDisplaySdr(L"ROOT\\OTHER\\0000", changed, error) && !changed,
            "physical or unrelated PnP target cannot enter managed SDR recovery");
    }
    Check(ExactRefresh(60, 1, 60), "60 Hz exact");
    Check(ExactRefresh(120000, 1000, 120), "120 Hz rational exact");
    Check(!ExactRefresh(60000, 1001, 60), "59.94 is not exact 60 Hz");
    Check(!ExactRefresh(119880, 1000, 120), "119.88 is not exact 120 Hz");
    Check(!ExactRefresh(120, 0, 120), "zero refresh denominator rejected");
    Check(!ExactRefresh(0, 1, 0), "zero requested rate rejected");
    Check(!ExactRefresh(1, 0xffffffffu, 120), "refresh multiplication cannot overflow 32-bit");
    Check(EqualRefresh({ 120, 1 }, { 120000, 1000 }), "equivalent refresh fractions accepted");
    Check(!EqualRefresh({ 60, 1 }, { 60000, 1001 }), "fractional physical rate change detected");

    auto exact = Mode(2732, 2048, 120);
    Check(ExactMode(exact, 2732, 2048, 120), "iPad native 120 mode selected");
    Check(!ExactMode(exact, 2732, 2048, 60), "120 mode does not masquerade as 60");
    Check(!ExactMode(exact, 2730, 2048, 120), "nearby resolution rejected");
    exact.dmBitsPerPel = 24;
    Check(!ExactMode(exact, 2732, 2048, 120), "24-bit encoder input rejected");
    exact = Mode(2732, 2048, 120); exact.dmDisplayFlags = DM_INTERLACED;
    Check(!ExactMode(exact, 2732, 2048, 120), "interlaced output rejected");
    exact = Mode(2732, 2048, 120); exact.dmDisplayOrientation = DMDO_90;
    Check(!ExactMode(exact, 2732, 2048, 120), "rotated output rejected");
    exact = Mode(2732, 2048, 120); exact.dmFields &= ~DM_DISPLAYFREQUENCY;
    Check(!ExactMode(exact, 2732, 2048, 120), "unspecified refresh rejected");
    Check(ExactMode(Mode(1366, 1024, 60), 1366, 1024, 60), "half-size exact mode supported");

    DXGI_OUTDUPL_DESC capture{};
    capture.ModeDesc.Width = 2732; capture.ModeDesc.Height = 2048;
    capture.ModeDesc.RefreshRate = { 120000, 1000 };
    capture.Rotation = DXGI_MODE_ROTATION_IDENTITY;
    Check(IsExactDuplicationMode(capture, 2732, 2048, 120), "exact resumed capture mode accepted");
    capture.ModeDesc.RefreshRate = { 60, 1 };
    Check(!IsExactDuplicationMode(capture, 2732, 2048, 120), "same-size 120 to 60 Hz capture change rejected");
    capture.ModeDesc.RefreshRate = { 120, 1 }; capture.Rotation = DXGI_MODE_ROTATION_ROTATE90;
    Check(!IsExactDuplicationMode(capture, 2732, 2048, 120), "same-size rotated duplication rejected");
    capture.Rotation = DXGI_MODE_ROTATION_IDENTITY; capture.ModeDesc.Width = 2730;
    Check(!IsExactDuplicationMode(capture, 2732, 2048, 120), "changed duplication width rejected");
    D3D11_TEXTURE2D_DESC texture{};
    texture.Width = 2732; texture.Height = 2048; texture.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    texture.MipLevels = 1; texture.ArraySize = 1; texture.SampleDesc.Count = 1;
    Check(IsExactCaptureTexture(texture, 2732, 2048), "matching desktop texture accepted");
    texture.Width = 2730;
    Check(!IsExactCaptureTexture(texture, 2732, 2048), "copy of wrong-size texture rejected");
    texture.Width = 2732; texture.Format = DXGI_FORMAT_R10G10B10A2_UNORM;
    Check(!IsExactCaptureTexture(texture, 2732, 2048), "HDR format incompatible with BGRA copy rejected");
    texture.Format = DXGI_FORMAT_B8G8R8A8_UNORM; texture.SampleDesc.Count = 2;
    Check(!IsExactCaptureTexture(texture, 2732, 2048), "incompatible multisample texture rejected");
    texture.SampleDesc.Count = 1; texture.ArraySize = 2;
    Check(!IsExactCaptureTexture(texture, 2732, 2048), "incompatible texture array rejected");

    POINTL position{};
    std::vector<DisplayDeviceState> screens{
        Device(L"DISPLAY1", -1920, -500, 1920, 1080),
        Device(L"DISPLAY2", 0, 0, 2560, 1440, true)
    };
    Check(PlanRightPosition(screens, L"virtual", position) && position.x == 2560 && position.y == 0,
        "negative coordinates retained and primary right edge selected");
    screens = { Device(L"left", 0, -1200, 1920, 1080), Device(L"right", 1920, 1500, 1280, 720) };
    Check(PlanRightPosition(screens, L"virtual", position) && position.x == 3200 && position.y == 1500,
        "diagonal arrangement attaches beside real monitor, not empty bounding-box corner");
    screens.push_back(Device(L"virtual", 3200, 1500, 2732, 2048));
    Check(PlanRightPosition(screens, L"VIRTUAL", position) && position.x == 3200,
        "already active managed monitor is excluded from placement");
    Check(!PlanRightPosition({ Device(L"virtual", 0, 0, 100, 100) }, L"virtual", position),
        "no physical desktop rejects activation");
    Check(!PlanRightPosition({ Device(L"overflow", LONG_MAX - 10, 0, 1920, 1080) }, L"virtual", position),
        "desktop right-coordinate overflow rejected");

    auto beforeDevice = Device(L"DISPLAY1", -1920, 40, 1920, 1080, true);
    auto afterDevice = beforeDevice;
    Check(SameDeviceState(beforeDevice, afterDevice), "unchanged physical mode accepted");
    afterDevice.primary = false;
    Check(!SameDeviceState(beforeDevice, afterDevice), "physical primary change detected");
    afterDevice = beforeDevice; afterDevice.mode.dmDisplayFrequency = 59;
    Check(!SameDeviceState(beforeDevice, afterDevice), "physical refresh change detected");
    afterDevice = beforeDevice; ++afterDevice.mode.dmPosition.x;
    Check(!SameDeviceState(beforeDevice, afterDevice), "one-pixel physical position change detected");

    auto before = PathFixture();
    auto after = before;
    Check(ExactPathMode(before, before.paths[0], 1920, 1080, 60), "exact CCD source, target and 60 Hz signal accepted");
    Check(!ExactPathMode(before, before.paths[0], 1920, 1080, 120), "60 Hz CCD output does not masquerade as 120");
    after.modes[1].targetMode.targetVideoSignalInfo.vSyncFreq = { 60000, 1001 };
    Check(!ExactPathMode(after, after.paths[0], 1920, 1080, 60), "virtual 60 Hz with fractional physical signal rejected");
    after = before; after.modes[0].sourceMode.width = 1280;
    Check(!ExactPathMode(after, after.paths[0], 1920, 1080, 60), "scaled source resolution rejected");
    after = before;
    Check(SamePathState(before, before.paths[0], after, after.paths[0]), "identical CCD mode path accepted");
    after.paths[0].targetInfo.refreshRate = { 60, 1 };
    Check(SamePathState(before, before.paths[0], after, after.paths[0]), "CCD equivalent fractions accepted");
    after = before; after.modes[1].targetMode.targetVideoSignalInfo.vSyncFreq = { 60000, 1001 };
    Check(!SamePathState(before, before.paths[0], after, after.paths[0]), "physical signal fractional rate change detected");
    after = before; ++after.modes[0].sourceMode.width;
    Check(!SamePathState(before, before.paths[0], after, after.paths[0]), "physical source resolution change detected");
    after = before; after.paths[0].targetInfo.id++;
    Check(!SamePathState(before, before.paths[0], after, after.paths[0]), "different output identity rejected");
    after = before; after.paths[0].sourceInfo.sourceModeInfoIdx = 0xffff;
    Check(!SamePathState(before, before.paths[0], after, after.paths[0]), "invalid virtual source-mode index rejected");
    before.paths[0].flags &= ~DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE;
    before.paths[0].sourceInfo.modeInfoIdx = 0; before.paths[0].targetInfo.modeInfoIdx = 1;
    after = before;
    Check(SamePathState(before, before.paths[0], after, after.paths[0]), "non-virtual CCD mode indices supported");

    ManagedDisplayTarget managed;
    std::wstring error;
    Check(!FindManagedDisplayTarget(L"ROOT\\OTHER\\0000", managed, error), "foreign adapter identity rejected");
    Check(!FindManagedDisplayTarget(L"ROOT\\MTTVDD\\", managed, error), "empty managed instance rejected");
    {
        auto physical = PathFixture();
        ManagedDisplayTarget target;
        target.path.flags = DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE;
        target.path.sourceInfo.adapterId = {99, 7};
        target.path.targetInfo.adapterId = target.path.sourceInfo.adapterId;
        target.path.sourceInfo.id = 0;
        target.path.targetInfo.id = 1;
        DisplayStateSnapshot planned;
        Check(PlanManagedTopology(physical, target, 2732, 2048, 120, {1920, 0}, planned, error),
            "CCD extends the supplied physical topology with the exact requested virtual source");
        Check(planned.paths.size() == 2 && planned.modes.size() == 3 &&
            SamePathState(physical, physical.paths[0], planned, planned.paths[0]),
            "CCD plan retains the physical path, resolution, position and exact signal timing");
        const auto& path = planned.paths.back();
        const auto* source = PathMode(planned, path, true);
        Check(source && source->sourceMode.width == 2732 && source->sourceMode.height == 2048 &&
            source->sourceMode.position.x == 1920 && source->sourceMode.position.y == 0 &&
            ExactRefresh(path.targetInfo.refreshRate.Numerator, path.targetInfo.refreshRate.Denominator, 120),
            "CCD plan preserves iPad pixels, Hz and adjacent extended position");
        Check(path.targetInfo.targetModeInfoIdx == DISPLAYCONFIG_PATH_TARGET_MODE_IDX_INVALID &&
            path.targetInfo.desktopModeInfoIdx == DISPLAYCONFIG_PATH_DESKTOP_IMAGE_IDX_INVALID &&
            path.sourceInfo.cloneGroupId == DISPLAYCONFIG_PATH_CLONE_GROUP_INVALID,
            "CCD derives only the missing managed timing and does not clone a physical source");
        Check(!PlanManagedTopology(physical, target, 0, 2048, 120, {1920, 0}, planned, error),
            "CCD rejects invalid iPad dimensions");
        auto invalid = physical;
        invalid.paths[0].targetInfo.targetModeInfoIdx = DISPLAYCONFIG_PATH_TARGET_MODE_IDX_INVALID;
        Check(!PlanManagedTopology(invalid, target, 2732, 2048, 120, {1920, 0}, planned, error),
            "CCD refuses to let Windows infer a missing physical target mode");
        auto duplicate = target;
        duplicate.path = physical.paths[0];
        Check(!PlanManagedTopology(physical, duplicate, 2732, 2048, 120, {1920, 0}, planned, error),
            "CCD refuses to replace an original display path");
        auto foreign = target;
        foreign.path.sourceInfo.adapterId.LowPart++;
        Check(!PlanManagedTopology(physical, foreign, 2732, 2048, 120, {1920, 0}, planned, error),
            "CCD refuses a virtual source on another adapter");
        target.path.flags = 0;
        Check(PlanManagedTopology(physical, target, 2732, 2048, 60, {1920, 0}, planned, error) &&
            planned.paths.back().sourceInfo.modeInfoIdx == 2 &&
            planned.paths.back().targetInfo.modeInfoIdx == DISPLAYCONFIG_PATH_MODE_IDX_INVALID,
            "CCD supports an indirect path without packed virtual-mode indices");
    }
    std::wstring gdi = L"must-clear";
    HMONITOR monitor = reinterpret_cast<HMONITOR>(1);
    Check(!ConfigureManagedDisplay(0, 2048, 120, L"ROOT\\MTTVDD\\0000", gdi, monitor, error) &&
        gdi.empty() && monitor == nullptr, "invalid request fails without any display mutation");

    // Native smoke checks only enumerate the current machine. No driver/device
    // installation, activation, display mode change, or security change occurs.
    IDXGIFactory1* factory = nullptr;
    Check(SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory))),
        "native DXGI factory available");
    if (factory) {
        IDXGIAdapter1* adapter = reinterpret_cast<IDXGIAdapter1*>(1);
        IDXGIOutput* output = reinterpret_cast<IDXGIOutput*>(1);
        Check(!FindDXGIOutput(factory, L"\\\\.\\WINSIDEUSB-NONEXISTENT", &adapter, &output) && !adapter && !output,
            "unknown output never falls back to a physical monitor");
        factory->Release();
    }
    DisplayStateSnapshot native;
    if (CaptureDisplayState(native, error)) {
        Check(ValidatePhysicalDisplayState(native, L"ROOT\\MTTVDD\\WINSIDEUSB-NONEXISTENT", error),
            "read-only native physical topology roundtrip");
        std::atomic<bool> cancelled{true};
        gdi = L"must-clear"; monitor = reinterpret_cast<HMONITOR>(1);
        Check(!ConfigureManagedDisplay(1920, 1080, 60, L"ROOT\\MTTVDD\\WINSIDEUSB-NONEXISTENT",
            gdi, monitor, error, &native, &cancelled) && gdi.empty() && !monitor,
            "cancelled missing managed adapter never changes display settings");
        factory = nullptr;
        if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory)))) {
            IDXGIAdapter1* adapter = nullptr;
            IDXGIOutput* output = nullptr;
            const auto& name = native.devices.front().gdiName;
            if (FindDXGIOutput(factory, name, &adapter, &output)) {
                DXGI_OUTPUT_DESC outputDesc{};
                DXGI_ADAPTER_DESC1 adapterDesc{}, parentDesc{};
                IDXGIAdapter1* parent = nullptr;
                Check(SUCCEEDED(output->GetDesc(&outputDesc)) && EqualName(name, outputDesc.DeviceName),
                    "native selected GDI output matches exact requested identity");
                const bool sameAdapter = SUCCEEDED(adapter->GetDesc1(&adapterDesc)) &&
                    SUCCEEDED(output->GetParent(__uuidof(IDXGIAdapter1), reinterpret_cast<void**>(&parent))) &&
                    SUCCEEDED(parent->GetDesc1(&parentDesc)) && EqualLuid(adapterDesc.AdapterLuid, parentDesc.AdapterLuid);
                Check(sameAdapter, "selected capture output belongs to the returned adapter");
                if (parent) parent->Release();
                output->Release(); adapter->Release();
            } else {
                std::cout << "SKIP: current native output is not exposed by DXGI\n";
            }
            factory->Release();
        }
    } else {
        std::wcerr << L"SKIP: native topology smoke check: " << error << L'\n';
    }
    std::cout << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
