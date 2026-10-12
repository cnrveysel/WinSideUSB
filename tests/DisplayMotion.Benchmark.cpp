// Read-only display selection: this program never activates a device, changes a
// display mode, or touches another application's windows. Run while WinSideUSB
// already owns an active 120 Hz virtual monitor. The only UI is a timed,
// borderless, non-activating animation on that exact monitor.
#define NOMINMAX
#include "../WinSideUSB/SignedDisplayOutput.h"
#include "../WinSideUSB/SignedDisplayClient.h"
#include "../WinSideUSB/FramePacing.h"
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <sstream>
#include <stdexcept>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")

namespace {
using Microsoft::WRL::ComPtr;
constexpr int ExpectedHz = 120;

std::string Utf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (bytes <= 1) return {};
    std::string result(static_cast<size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), bytes, nullptr, nullptr);
    result.pop_back();
    return result;
}

std::string JsonString(const std::string& value) {
    std::ostringstream out;
    out << '"';
    for (const unsigned char ch : value) {
        if (ch == '"' || ch == '\\') out << '\\' << static_cast<char>(ch);
        else if (ch < 0x20) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(ch);
        else out << static_cast<char>(ch);
    }
    out << '"';
    return out.str();
}

int Failure(const char* status, const std::string& error, int code) {
    std::cout << "{\"status\":" << JsonString(status) << ",\"error\":" << JsonString(error) << "}\n";
    return code;
}

void Require(HRESULT result, const char* operation) {
    if (SUCCEEDED(result)) return;
    std::ostringstream message;
    message << operation << " failed (HRESULT 0x" << std::hex << static_cast<unsigned long>(result) << ").";
    throw std::runtime_error(message.str());
}

LONGLONG Qpc() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

struct WindowState {
    RECT rect{};
    bool closed = false;
    bool topologyChanged = false;
};

LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* state = reinterpret_cast<WindowState*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        const auto* creation = reinterpret_cast<CREATESTRUCTW*>(lparam);
        state = static_cast<WindowState*>(creation->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
    }
    if (state) {
        if (message == WM_DISPLAYCHANGE || message == WM_DPICHANGED) {
            state->topologyChanged = true;
            ShowWindow(window, SW_HIDE);
            return 0;
        }
        if (message == WM_WINDOWPOSCHANGING) {
            auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
            const bool moved = !(position->flags & SWP_NOMOVE) &&
                (position->x != state->rect.left || position->y != state->rect.top);
            const bool resized = !(position->flags & SWP_NOSIZE) &&
                (position->cx != state->rect.right - state->rect.left ||
                 position->cy != state->rect.bottom - state->rect.top);
            if (moved || resized) {
                // In particular, never let Windows relocate this animation to a
                // physical screen if the virtual screen disappears mid-run.
                position->flags |= SWP_NOMOVE | SWP_NOSIZE | SWP_HIDEWINDOW;
                state->topologyChanged = true;
            }
        }
        if (message == WM_CLOSE) {
            state->closed = true;
            ShowWindow(window, SW_HIDE);
            return 0;
        }
        if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
        if (message == WM_ERASEBKGND) return 1;
        if (message == WM_PAINT) {
            PAINTSTRUCT paint{};
            BeginPaint(window, &paint);
            EndPaint(window, &paint);
            return 0;
        }
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

struct OwnWindow {
    HWND handle = nullptr;
    ~OwnWindow() { if (handle) DestroyWindow(handle); }
};

struct OwnHandle {
    HANDLE handle = nullptr;
    ~OwnHandle() { if (handle) CloseHandle(handle); }
};

bool PumpMessages(WindowState& state) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        if (message.message == WM_QUIT) state.closed = true;
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return !state.closed && !state.topologyChanged;
}

struct MonitorSearch {
    const std::wstring* name = nullptr;
    HMONITOR monitor = nullptr;
    RECT rect{};
};

BOOL CALLBACK FindMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM parameter) {
    auto& search = *reinterpret_cast<MonitorSearch*>(parameter);
    MONITORINFOEXW information{};
    information.cbSize = sizeof(information);
    if (GetMonitorInfoW(monitor, reinterpret_cast<MONITORINFO*>(&information)) &&
        winsideusb::display_detail::EqualName(*search.name, information.szDevice)) {
        search.monitor = monitor;
        search.rect = information.rcMonitor;
        return FALSE;
    }
    return TRUE;
}

constexpr char ShaderSource[] = R"hlsl(
cbuffer Animation : register(b0) { float elapsed; float width; float height; float frame; };
struct Vertex { float4 position : SV_POSITION; float2 uv : TEXCOORD0; };
Vertex VS(uint id : SV_VertexID) {
    Vertex result;
    result.uv = float2((id << 1) & 2, id & 2);
    result.position = float4(result.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return result;
}
float4 PS(Vertex vertex) : SV_TARGET {
    float2 pixel = vertex.uv * float2(width, height);
    float phase = pixel.x - elapsed * 720.0;
    float stripe = 0.5 + 0.5 * sin(phase * 0.049087385); // smooth 128-pixel stripes
    float3 gradient = 0.5 + 0.5 * cos(float3(0, 2.094395, 4.188790) +
        pixel.y * 0.004 + elapsed * 0.7);
    float3 color = lerp(gradient * 0.15, gradient * 0.85 + 0.15, stripe);
    float bar = 1.0 - smoothstep(2.0, 5.0, abs(frac((pixel.x - elapsed * 480.0) / width) * width - width * 0.5));
    color = lerp(color, float3(1, 1, 1), bar);
    // A binary frame marker helps a recorded image reveal repeated frames.
    if (pixel.y < 36.0 && pixel.x < 480.0) {
        uint bit = (uint)(pixel.x / 30.0);
        color = (((uint)frame >> bit) & 1) ? float3(1, 1, 1) : float3(0.02, 0.02, 0.02);
    }
    return float4(color, 1);
}
)hlsl";

ComPtr<ID3DBlob> Compile(const char* entry, const char* profile) {
    ComPtr<ID3DBlob> shader, errors;
    const HRESULT result = D3DCompile(ShaderSource, std::strlen(ShaderSource), "DisplayMotion.Benchmark",
        nullptr, nullptr, entry, profile, D3DCOMPILE_OPTIMIZATION_LEVEL3 | D3DCOMPILE_ENABLE_STRICTNESS,
        0, &shader, &errors);
    if (FAILED(result) && errors) {
        throw std::runtime_error(std::string(static_cast<const char*>(errors->GetBufferPointer()), errors->GetBufferSize()));
    }
    Require(result, "D3DCompile");
    return shader;
}

struct SampleSummary {
    double mean = 0, minimum = 0, maximum = 0, p50 = 0, p95 = 0, p99 = 0;
};

SampleSummary Summarize(std::vector<double> samples) {
    SampleSummary result;
    if (samples.empty()) return result;
    std::sort(samples.begin(), samples.end());
    result.mean = std::accumulate(samples.begin(), samples.end(), 0.0) / samples.size();
    result.minimum = samples.front();
    result.maximum = samples.back();
    auto quantile = [&](double percentile) {
        const size_t index = static_cast<size_t>(std::ceil(percentile * samples.size())) - 1;
        return samples[index];
    };
    result.p50 = quantile(0.50); result.p95 = quantile(0.95); result.p99 = quantile(0.99);
    return result;
}

void PrintSummary(const SampleSummary& result) {
    std::cout << "{\"mean\":" << result.mean << ",\"min\":" << result.minimum
        << ",\"p50\":" << result.p50 << ",\"p95\":" << result.p95
        << ",\"p99\":" << result.p99 << ",\"max\":" << result.maximum << '}';
}

int Run(double duration) {
    std::wstring instance, error;
    if (!winsideusb::ReadDisplaySetting(L"ManagedDeviceInstanceId", instance))
        return Failure("unavailable", "The owned ManagedDeviceInstanceId setting is unavailable.", 2);
    winsideusb::ManagedDisplayTarget target;
    if (!winsideusb::FindManagedDisplayTarget(instance, target, error))
        return Failure("unavailable", Utf8(error), 2);
    if (!(target.path.flags & DISPLAYCONFIG_PATH_ACTIVE))
        return Failure("unavailable", "The owned WinSideUSB virtual display is not already active.", 2);
    winsideusb::DisplayStateSnapshot active;
    if (!winsideusb::display_detail::QueryPaths(QDC_ONLY_ACTIVE_PATHS, active, error))
        return Failure("unavailable", Utf8(error), 2);
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsExW(target.gdiName.c_str(), ENUM_CURRENT_SETTINGS, &mode, 0) ||
        !winsideusb::display_detail::ExactMode(mode, static_cast<int>(mode.dmPelsWidth),
            static_cast<int>(mode.dmPelsHeight), ExpectedHz) ||
        !std::any_of(active.paths.begin(), active.paths.end(), [&](const DISPLAYCONFIG_PATH_INFO& path) {
            return winsideusb::display_detail::SamePathIdentity(path, target.path) &&
                winsideusb::display_detail::ExactPathMode(active, path, static_cast<int>(mode.dmPelsWidth),
                    static_cast<int>(mode.dmPelsHeight), ExpectedHz);
        }))
        return Failure("unavailable", "The owned active display must already have an exact progressive 120 Hz mode.", 2);

    MonitorSearch search{ &target.gdiName };
    EnumDisplayMonitors(nullptr, nullptr, FindMonitor, reinterpret_cast<LPARAM>(&search));
    if (!search.monitor)
        return Failure("unavailable", "The owned active GDI display has no matching HMONITOR.", 2);
    const LONG width = search.rect.right - search.rect.left;
    const LONG height = search.rect.bottom - search.rect.top;
    if (width <= 0 || height <= 0 || static_cast<DWORD>(width) != mode.dmPelsWidth ||
        static_cast<DWORD>(height) != mode.dmPelsHeight)
        return Failure("unavailable", "The owned monitor rectangle does not match its active pixel dimensions.", 2);

    ComPtr<IDXGIFactory2> factory;
    Require(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "CreateDXGIFactory1");
    ComPtr<IDXGIAdapter1> adapter;
    ComPtr<IDXGIOutput> output;
    if (!winsideusb::FindDXGIOutput(factory.Get(), target.gdiName, &adapter, &output))
        return Failure("unavailable", "The owned GDI display has no attached DXGI output; no fallback is allowed.", 2);
    DXGI_OUTPUT_DESC outputDescription{};
    Require(output->GetDesc(&outputDescription), "DXGI output description");
    if (outputDescription.Monitor != search.monitor || !EqualRect(&outputDescription.DesktopCoordinates, &search.rect))
        return Failure("unavailable", "The selected DXGI output does not match the owned HMONITOR and desktop rectangle.", 2);
    DXGI_ADAPTER_DESC1 adapterDescription{};
    Require(adapter->GetDesc1(&adapterDescription), "DXGI adapter description");
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0 };
    Require(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        levels, static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION, &device, nullptr, &context), "D3D11CreateDevice on owned output adapter");

    WindowState windowState{ search.rect };
    const HINSTANCE module = GetModuleHandleW(nullptr);
    constexpr wchar_t ClassName[] = L"WinSideUSB.DisplayMotion.Benchmark";
    WNDCLASSW windowClass{};
    windowClass.lpfnWndProc = WindowProcedure;
    windowClass.hInstance = module;
    windowClass.lpszClassName = ClassName;
    if (!RegisterClassW(&windowClass)) throw std::runtime_error("Could not register the benchmark window class.");
    OwnWindow window;
    window.handle = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
        ClassName, L"WinSideUSB 120 Hz motion benchmark", WS_POPUP, search.rect.left, search.rect.top,
        width, height, nullptr, nullptr, module, &windowState);
    if (!window.handle) throw std::runtime_error("Could not create the owned-display benchmark window.");
    Require(factory->MakeWindowAssociation(window.handle, DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES),
        "Disable DXGI automatic window changes");

    DXGI_SWAP_CHAIN_DESC1 description{};
    description.Width = static_cast<UINT>(width); description.Height = static_cast<UINT>(height);
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    description.BufferCount = 2;
    description.Scaling = DXGI_SCALING_STRETCH;
    description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    description.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    description.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    ComPtr<IDXGISwapChain1> swapChain;
    // Indirect outputs can invalidate DXGI's restriction token without a CCD
    // topology change. Keep the window pinned to the validated owned rectangle
    // instead; its procedure immediately hides it on relocation/display loss.
    Require(factory->CreateSwapChainForHwnd(device.Get(), window.handle, &description, nullptr,
        nullptr, &swapChain), "Create flip-model swapchain on owned window");
    ComPtr<IDXGISwapChain2> swapChain2;
    Require(swapChain.As(&swapChain2), "IDXGISwapChain2");
    Require(swapChain2->SetMaximumFrameLatency(1), "SetMaximumFrameLatency(1)");
    OwnHandle frameReady{ swapChain2->GetFrameLatencyWaitableObject() };
    if (!frameReady.handle) throw std::runtime_error("DXGI did not provide a frame latency waitable object.");

    ComPtr<ID3D11Texture2D> backBuffer;
    Require(swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer)), "Swapchain back buffer");
    ComPtr<ID3D11RenderTargetView> renderTarget;
    Require(device->CreateRenderTargetView(backBuffer.Get(), nullptr, &renderTarget), "CreateRenderTargetView");
    const auto vsBytes = Compile("VS", "vs_5_0"), psBytes = Compile("PS", "ps_5_0");
    ComPtr<ID3D11VertexShader> vertexShader;
    ComPtr<ID3D11PixelShader> pixelShader;
    Require(device->CreateVertexShader(vsBytes->GetBufferPointer(), vsBytes->GetBufferSize(), nullptr,
        &vertexShader), "CreateVertexShader");
    Require(device->CreatePixelShader(psBytes->GetBufferPointer(), psBytes->GetBufferSize(), nullptr,
        &pixelShader), "CreatePixelShader");
    struct Animation { float elapsed, width, height, frame; };
    static_assert(sizeof(Animation) == 16, "Constant-buffer alignment");
    D3D11_BUFFER_DESC constantsDescription{};
    constantsDescription.ByteWidth = sizeof(Animation);
    constantsDescription.Usage = D3D11_USAGE_DYNAMIC;
    constantsDescription.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    constantsDescription.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    ComPtr<ID3D11Buffer> constants;
    Require(device->CreateBuffer(&constantsDescription, nullptr, &constants), "Create animation constant buffer");
    D3D11_VIEWPORT viewport{ 0, 0, static_cast<float>(width), static_cast<float>(height), 0, 1 };
    context->RSSetViewports(1, &viewport);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetShader(vertexShader.Get(), nullptr, 0);
    context->PSSetShader(pixelShader.Get(), nullptr, 0);
    ID3D11Buffer* constantsPointer = constants.Get();
    context->PSSetConstantBuffers(0, 1, &constantsPointer);

    LARGE_INTEGER frequency{};
    QueryPerformanceFrequency(&frequency);
    const double qpcFrequency = static_cast<double>(frequency.QuadPart);
    const double millisecondsPerTick = 1000.0 / qpcFrequency;
    std::vector<LONGLONG> presents;
    std::vector<double> presentCalls;
    presents.reserve(static_cast<size_t>(duration * ExpectedHz * 2));
    presentCalls.reserve(presents.capacity());
    DXGI_FRAME_STATISTICS firstStatistics{}, lastStatistics{};
    bool haveStatistics = false;
    unsigned statisticsDisjoints = 0;
    // Device and shader setup can take time. Revalidate immediately before
    // showing, including topology messages queued while this window was hidden.
    winsideusb::ManagedDisplayTarget currentTarget;
    MONITORINFOEXW currentMonitor{};
    currentMonitor.cbSize = sizeof(currentMonitor);
    if (!PumpMessages(windowState) ||
        !winsideusb::FindManagedDisplayTarget(instance, currentTarget, error) ||
        !(currentTarget.path.flags & DISPLAYCONFIG_PATH_ACTIVE) ||
        !winsideusb::display_detail::SamePathIdentity(target.path, currentTarget.path) ||
        !winsideusb::display_detail::EqualName(target.gdiName, currentTarget.gdiName) ||
        !GetMonitorInfoW(search.monitor, reinterpret_cast<MONITORINFO*>(&currentMonitor)) ||
        !winsideusb::display_detail::EqualName(target.gdiName, currentMonitor.szDevice) ||
        !EqualRect(&currentMonitor.rcMonitor, &search.rect) ||
        MonitorFromWindow(window.handle, MONITOR_DEFAULTTONULL) != search.monitor)
        return Failure("unavailable", "The owned display changed during benchmark setup.", 2);
    ShowWindow(window.handle, SW_SHOWNOACTIVATE);
    const LONGLONG start = Qpc();
    const LONGLONG deadline = start + static_cast<LONGLONG>(duration * qpcFrequency);
    winsideusb::FrameDeadlineWaiter motionTimer;
    std::atomic<bool> cancelled{false};
    LONGLONG nextMotionFrame = start;
    const LONGLONG motionInterval = frequency.QuadPart / ExpectedHz;
    bool complete = false;
    while (PumpMessages(windowState)) {
        const LONGLONG beforeWait = Qpc();
        if (beforeWait >= deadline) { complete = true; break; }
        const DWORD remaining = static_cast<DWORD>(std::max(1.0,
            std::ceil((deadline - beforeWait) * millisecondsPerTick)));
        const DWORD waited = MsgWaitForMultipleObjectsEx(1, &frameReady.handle,
            std::min<DWORD>(remaining, 1000), QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (waited == WAIT_OBJECT_0 + 1) continue;
        if (waited == WAIT_TIMEOUT) {
            if (Qpc() >= deadline) { complete = true; break; }
            throw std::runtime_error("No DXGI frame-latency signal arrived within one second.");
        }
        if (waited != WAIT_OBJECT_0) throw std::runtime_error("Waiting for DXGI frame latency failed.");
        if (!PumpMessages(windowState)) break;
        // DWM can schedule an indirect swapchain against a faster physical
        // monitor. Explicitly generate 120 changes/s for a fair source test.
        if (!motionTimer.WaitUntil(nextMotionFrame, frequency.QuadPart, cancelled)) break;
        if (!PumpMessages(windowState)) break;
        const LONGLONG renderTime = Qpc();
        if (renderTime >= deadline) { complete = true; break; }
        const Animation animation{ static_cast<float>((renderTime - start) / qpcFrequency),
            static_cast<float>(width), static_cast<float>(height), static_cast<float>(presents.size()) };
        D3D11_MAPPED_SUBRESOURCE mapped{};
        Require(context->Map(constants.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped), "Map animation constants");
        std::memcpy(mapped.pData, &animation, sizeof(animation));
        context->Unmap(constants.Get(), 0);
        // Flip presentation unbinds the back buffer, so bind it for each frame.
        ID3D11RenderTargetView* targetPointer = renderTarget.Get();
        context->OMSetRenderTargets(1, &targetPointer, nullptr);
        context->Draw(3, 0);
        const LONGLONG presentStart = Qpc();
        const DXGI_PRESENT_PARAMETERS parameters{};
        const HRESULT presented = swapChain->Present1(1, 0, &parameters);
        const LONGLONG presentEnd = Qpc();
        if (presented == DXGI_STATUS_OCCLUDED) throw std::runtime_error("The owned benchmark window became occluded.");
        Require(presented, "Present1(1)");
        presents.push_back(presentEnd);
        nextMotionFrame += motionInterval;
        if (presentEnd - nextMotionFrame > motionInterval)
            nextMotionFrame = presentEnd + motionInterval;
        presentCalls.push_back((presentEnd - presentStart) * millisecondsPerTick);
        DXGI_FRAME_STATISTICS statistics{};
        const HRESULT statsResult = swapChain->GetFrameStatistics(&statistics);
        if (statsResult == DXGI_ERROR_FRAME_STATISTICS_DISJOINT) {
            ++statisticsDisjoints;
            haveStatistics = false;
        } else if (SUCCEEDED(statsResult) && statistics.SyncQPCTime.QuadPart > 0) {
            if (!haveStatistics) { firstStatistics = statistics; haveStatistics = true; }
            lastStatistics = statistics;
        }
    }
    const LONGLONG end = Qpc();
    ShowWindow(window.handle, SW_HIDE);
    std::vector<double> intervals;
    for (size_t index = 1; index < presents.size(); ++index)
        intervals.push_back((presents[index] - presents[index - 1]) * millisecondsPerTick);
    const double elapsed = (end - start) / qpcFrequency;
    const double fps = presents.size() > 1 ? (presents.size() - 1) * qpcFrequency /
        static_cast<double>(presents.back() - presents.front()) : 0;
    const auto late = std::count_if(intervals.begin(), intervals.end(), [](double value) {
        return value > 1.5 * 1000.0 / ExpectedHz;
    });
    const bool statisticsAvailable = haveStatistics && lastStatistics.SyncQPCTime.QuadPart > firstStatistics.SyncQPCTime.QuadPart;
    std::cout << std::fixed << std::setprecision(4)
        << "{\"status\":" << JsonString(complete ? "complete" : "interrupted")
        << ",\"stop_reason\":" << JsonString(complete ? "duration" :
            (windowState.topologyChanged ? "display_topology_changed" : "window_closed"))
        << ",\"managed_instance\":" << JsonString(Utf8(instance))
        << ",\"gdi_name\":" << JsonString(Utf8(target.gdiName))
        << ",\"adapter\":" << JsonString(Utf8(adapterDescription.Description))
        << ",\"width\":" << width << ",\"height\":" << height
        << ",\"refresh_hz\":" << ExpectedHz << ",\"source_target_fps\":120,\"sync_interval\":1,\"maximum_frame_latency\":1,\"window_pinned_to_owned_output\":true"
        << ",\"requested_duration_seconds\":" << duration << ",\"elapsed_seconds\":" << elapsed
        << ",\"present_count\":" << presents.size() << ",\"measured_present_fps\":" << fps
        << ",\"intervals_over_1_5_refresh_period\":" << late << ",\"present_interval_ms\":";
    PrintSummary(Summarize(intervals));
    std::cout << ",\"present_call_ms\":";
    PrintSummary(Summarize(presentCalls));
    std::cout << ",\"dxgi_statistics_available\":" << (statisticsAvailable ? "true" : "false")
        << ",\"dxgi_statistics_disjoints\":" << statisticsDisjoints;
    if (statisticsAvailable) {
        // Diagnostic only: Microsoft notes DXGI statistics can be unreliable
        // with multiple monitors. Present intervals above are always reported.
        const UINT count = lastStatistics.PresentCount - firstStatistics.PresentCount;
        const UINT refreshes = lastStatistics.PresentRefreshCount - firstStatistics.PresentRefreshCount;
        const double statsSeconds = (lastStatistics.SyncQPCTime.QuadPart - firstStatistics.SyncQPCTime.QuadPart) / qpcFrequency;
        std::cout << ",\"dxgi_present_count_delta\":" << count
            << ",\"dxgi_present_refresh_count_delta\":" << refreshes
            << ",\"dxgi_statistics_seconds\":" << statsSeconds
            << ",\"dxgi_present_fps\":" << count / statsSeconds;
    }
    std::cout << "}\n";
    return complete ? 0 : 3;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    double duration = 18;
    if (argc == 2 && std::wstring(argv[1]) == L"--help") {
        std::cout << "Usage: DisplayMotion.Benchmark.exe [--duration seconds]\n"
            "Requires WinSideUSB's owned virtual display already active at exactly 120 Hz.\n"
            "Creates only a timed, non-activating animation on that display; makes no display changes.\n"
            "Exit codes: 0 complete, 2 unavailable/invalid arguments, 3 interrupted/runtime error.\n";
        return 0;
    }
    if (argc != 1) {
        if (argc != 3 || std::wstring(argv[1]) != L"--duration")
            return Failure("invalid_arguments", "Usage: DisplayMotion.Benchmark.exe [--duration seconds]", 2);
        wchar_t* end = nullptr;
        duration = std::wcstod(argv[2], &end);
        if (!end || *end || !std::isfinite(duration) || duration < 1 || duration > 120)
            return Failure("invalid_arguments", "Duration must be a finite number between 1 and 120 seconds.", 2);
    }
    // Coordinate selection and client size must be native display pixels.
    if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))
        return Failure("error", "Could not enable per-monitor DPI awareness for exact pixel placement.", 3);
    try { return Run(duration); }
    catch (const std::exception& error) { return Failure("error", error.what(), 3); }
}
