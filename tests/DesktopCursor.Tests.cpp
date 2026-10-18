#define NOMINMAX
#include "../WinSideUSB/DesktopCursor.h"
#include <d3d11sdklayers.h>
#include <cstdio>
#include <stdexcept>

#pragma comment(lib, "d3d11.lib")

using Microsoft::WRL::ComPtr;

namespace {
void Require(HRESULT result) {
    if (FAILED(result)) {
        std::printf("HRESULT 0x%08lx\n", static_cast<unsigned long>(result));
        throw std::runtime_error("D3D11 cursor test setup failed");
    }
}

struct Fixture {
    static constexpr UINT Width = 8, Height = 6;
    static constexpr uint32_t Background = 0xff204060;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11Texture2D> target, clean, staging;
    ComPtr<ID3D11InfoQueue> diagnostics;
    winsideusb::DesktopCursor cursor;

    explicit Fixture(bool hardware) {
        const D3D_DRIVER_TYPE driver = hardware ? D3D_DRIVER_TYPE_HARDWARE : D3D_DRIVER_TYPE_WARP;
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_DEBUG;
        HRESULT hr = D3D11CreateDevice(nullptr, driver, nullptr, flags,
            nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context);
        if (hr == DXGI_ERROR_SDK_COMPONENT_MISSING) {
            flags &= ~D3D11_CREATE_DEVICE_DEBUG;
            hr = D3D11CreateDevice(nullptr, driver, nullptr, flags,
                nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context);
        }
        Require(hr);
        ComPtr<IDXGIDevice> dxgiDevice;
        ComPtr<IDXGIAdapter> adapter;
        DXGI_ADAPTER_DESC adapterDescription{};
        Require(device.As(&dxgiDevice));
        Require(dxgiDevice->GetAdapter(&adapter));
        Require(adapter->GetDesc(&adapterDescription));
        std::printf("cursor_driver=%s adapter_vendor=0x%04x\n", hardware ? "hardware" : "WARP", adapterDescription.VendorId);
        device.As(&diagnostics);
        D3D11_TEXTURE2D_DESC description{};
        description.Width = Width; description.Height = Height;
        description.ArraySize = 1; description.MipLevels = 1; description.SampleDesc.Count = 1;
        description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        Require(device->CreateTexture2D(&description, nullptr, &target));
        description.BindFlags = 0;
        std::vector<uint32_t> pixels(Width * Height, Background);
        D3D11_SUBRESOURCE_DATA data{};
        data.pSysMem = pixels.data(); data.SysMemPitch = Width * 4;
        Require(device->CreateTexture2D(&description, &data, &clean));
        description.Usage = D3D11_USAGE_STAGING; description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        Require(device->CreateTexture2D(&description, nullptr, &staging));
        Require(cursor.Initialize(device.Get(), context.Get(), target.Get()));
        ResetDesktop();
    }
    void ResetDesktop() { context->CopyResource(target.Get(), clean.Get()); }
    void Position(LONG x, LONG y, bool visible = true, bool updated = true) {
        DXGI_OUTDUPL_FRAME_INFO frame{};
        frame.LastMouseUpdateTime.QuadPart = updated ? 1 : 0;
        frame.PointerPosition.Visible = visible;
        frame.PointerPosition.Position = { x, y };
        cursor.UpdatePosition(frame);
    }
    HRESULT Shape(UINT type, UINT width, UINT height, UINT pitch, const void* bytes, size_t size) {
        DXGI_OUTDUPL_POINTER_SHAPE_INFO information{ type, width, height, pitch, { 5, 5 } };
        return cursor.SetShape(information, static_cast<const uint8_t*>(bytes), size);
    }
    std::vector<uint32_t> Read() {
        context->CopyResource(staging.Get(), target.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        Require(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
        std::vector<uint32_t> pixels(Width * Height);
        for (UINT y = 0; y < Height; ++y)
            std::memcpy(pixels.data() + y * Width,
                static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch, Width * 4);
        context->Unmap(staging.Get(), 0);
        return pixels;
    }
    bool NoGpuErrors() {
        if (!diagnostics) return true;
        bool okay = true;
        for (UINT64 i = 0; i < diagnostics->GetNumStoredMessagesAllowedByRetrievalFilter(); ++i) {
            SIZE_T size = 0;
            diagnostics->GetMessage(i, nullptr, &size);
            std::vector<uint8_t> storage(size);
            auto* message = reinterpret_cast<D3D11_MESSAGE*>(storage.data());
            Require(diagnostics->GetMessage(i, message, &size));
            if (message->Severity <= D3D11_MESSAGE_SEVERITY_WARNING) {
                std::printf("D3D11: %s\n", message->pDescription);
                okay = false;
            }
        }
        return okay;
    }
};
}

int main(int argc, char** argv) {
    const bool hardware = argc == 2 && std::strcmp(argv[1], "--hardware") == 0;
    if (argc > 1 && !hardware) {
        std::printf("Usage: DesktopCursor.Tests.exe [--hardware]\n");
        return 2;
    }
    int failures = 0, checks = 0;
    auto check = [&](bool success, const char* name) {
        ++checks;
        std::printf("%s %s\n", success ? "PASS" : "FAIL", name);
        if (!success) ++failures;
    };
    try {
        Fixture f(hardware);
        const uint32_t color[] = { 0xffff0000, 0x000000ff, 0x80c08040 };
        Require(f.Shape(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR, 3, 1, 12, color, sizeof(color)));
        f.Position(2, 1);
        check(f.cursor.Draw(), "separate visible pointer is composited");
        auto image = f.Read();
        check(image[1 * f.Width + 2] == 0xffff0000, "opaque color cursor uses BGRA correctly and ignores informational hotspot");
        check(image[1 * f.Width + 3] == f.Background, "transparent cursor pixels preserve desktop");
        check(image[1 * f.Width + 4] == 0xff706050, "partial alpha cursor blends with desktop");
        check(image[0] == f.Background && image.back() == f.Background, "composition changes only the cursor rectangle");

        f.ResetDesktop();
        f.Position(0, 0, false, false);
        f.cursor.Draw();
        check(f.Read()[1 * f.Width + 2] == 0xffff0000, "desktop-only update retains cached pointer position and visibility");

        f.ResetDesktop();
        f.Position(0, 0, false);
        check(!f.cursor.Draw() && f.Read()[1 * f.Width + 2] == f.Background, "hidden or already embedded pointer is not drawn twice");
        f.ResetDesktop();
        f.Position(4, 3);
        f.cursor.Draw();
        image = f.Read();
        check(image[1 * f.Width + 2] == f.Background && image[3 * f.Width + 4] == 0xffff0000,
            "pointer-only movement removes the old cursor without trails");

        const uint32_t padded[] = { 0xff112233, 0xff445566, 0xdeadbeef,
                                    0xff778899, 0xffaabbcc, 0xdeadbeef };
        Require(f.Shape(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR, 2, 2, 12, padded, sizeof(padded)));
        f.ResetDesktop(); f.Position(-1, -1); f.cursor.Draw();
        image = f.Read();
        check(image[0] == 0xffaabbcc && image[1] == f.Background, "negative output-local positions clip using the correct padded shape pixel");
        f.ResetDesktop(); f.Position(7, 5); f.cursor.Draw();
        image = f.Read();
        check(image.back() == 0xff112233 && image[5 * f.Width + 6] == f.Background,
            "right and bottom edges clip without changing neighboring pixels");
        f.ResetDesktop(); f.Position(9, 6);
        check(!f.cursor.Draw() && f.Read().back() == f.Background, "pointer completely outside the output is skipped");

        const uint8_t masks[] = { 0x30, 0x50 };
        Require(f.Shape(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME, 4, 2, 1, masks, sizeof(masks)));
        f.ResetDesktop(); f.Position(0, 0); f.cursor.Draw(); image = f.Read();
        check(image[0] == 0xff000000, "monochrome AND=0 XOR=0 paints black");
        check(image[1] == 0xffffffff, "monochrome AND=0 XOR=1 paints white");
        check(image[2] == f.Background, "monochrome AND=1 XOR=0 preserves background");
        check(image[3] == 0xffdfbf9f, "monochrome AND=1 XOR=1 inverts background");
        check(image[f.Width] == f.Background, "monochrome bitmap height includes both masks, not twice the visible height");

        const uint32_t masked[] = { 0x00112233, 0xff102030, 0xff000000 };
        Require(f.Shape(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR, 3, 1, 12, masked, sizeof(masked)));
        f.ResetDesktop(); f.Position(0, 0); f.cursor.Draw(); image = f.Read();
        check(image[0] == 0xff112233, "masked color alpha=0 replaces desktop RGB");
        check(image[1] == 0xff306050, "masked color alpha=255 XORs desktop RGB");
        check(image[2] == f.Background, "masked transparent XOR pixel preserves desktop");

        check(FAILED(f.Shape(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR, 2, 2, 4, color, sizeof(color))), "undersized pointer row pitch is rejected");
        check(!f.cursor.Draw(), "a failed shape update cannot reuse the old shape");
        check(FAILED(f.Shape(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME, 4, 3, 1, masks, sizeof(masks))), "odd monochrome mask height is rejected");
        check(FAILED(f.Shape(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR, 3, 2, 12, color, sizeof(color))), "truncated pointer buffer is rejected");
        check(FAILED(f.Shape(999, 3, 1, 12, color, sizeof(color))), "unknown pointer type is rejected");
        Require(f.Shape(DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR, 3, 1, 12, color, sizeof(color)));
        f.cursor.ResetPointer();
        check(!f.cursor.Draw(), "duplication recreation clears stale pointer state");
        check(f.NoGpuErrors(), "D3D11 debug layer reports no composition warnings or resource hazards");
    } catch (const std::exception& error) {
        std::printf("FAIL %s\n", error.what());
        ++failures;
    }
    std::printf("cursor_checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
