#pragma once

#include <d3d11.h>
#include <dxgi1_2.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

#pragma comment(lib, "d3dcompiler.lib")

namespace winsideusb {

// DXGI can return the hardware pointer separately from the desktop surface.
// Composite only that pointer, on the capture thread, before H.264 encoding.
class DesktopCursor {
    template<class T> using ComPtr = Microsoft::WRL::ComPtr<T>;
public:
    HRESULT Initialize(ID3D11Device* device, ID3D11DeviceContext* context, ID3D11Texture2D* destination) {
        Shutdown();
        if (!device || !context || !destination) return E_INVALIDARG;
        device_ = device;
        context_ = context;
        destination_ = destination;
        D3D11_TEXTURE2D_DESC description{};
        destination->GetDesc(&description);
        width_ = description.Width;
        height_ = description.Height;
        HRESULT hr = device_->CreateRenderTargetView(destination, nullptr, &target_);
        if (FAILED(hr)) return hr;

        static const char shader[] = R"(
cbuffer Placement : register(b0) { int2 pointerPosition; int2 backgroundOrigin; uint shapeType; uint3 padding; };
Texture2D<uint4> pointerShape : register(t0);
Texture2D<float4> background : register(t1);
float4 Vertex(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}
float4 Pixel(float4 position : SV_Position) : SV_Target {
    int2 pixel = int2(position.xy);
    uint4 shape = pointerShape.Load(int3(pixel - pointerPosition, 0));
    float4 original = background.Load(int3(pixel - backgroundOrigin, 0));
    uint3 originalBytes = uint3(round(saturate(original.rgb) * 255.0));
    if (shapeType == 1) { // Monochrome AND mask followed by XOR mask.
        return float4(float3((originalBytes & shape.rrr) ^ shape.ggg) / 255.0, original.a);
    }
    if (shapeType == 4) { // Masked color: alpha is an XOR/replace flag.
        uint3 value = shape.a == 0 ? shape.bgr : (originalBytes ^ shape.bgr);
        return float4(float3(value) / 255.0, original.a);
    }
    float alpha = float(shape.a) / 255.0;
    return float4(lerp(original.rgb, float3(shape.bgr) / 255.0, alpha), original.a);
}
)";
        ComPtr<ID3DBlob> vertexCode, pixelCode, errors;
        hr = D3DCompile(shader, sizeof(shader) - 1, "DesktopCursor", nullptr, nullptr,
            "Vertex", "vs_4_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &vertexCode, &errors);
        if (FAILED(hr)) return hr;
        hr = D3DCompile(shader, sizeof(shader) - 1, "DesktopCursor", nullptr, nullptr,
            "Pixel", "ps_4_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &pixelCode, &errors);
        if (FAILED(hr)) return hr;
        hr = device_->CreateVertexShader(vertexCode->GetBufferPointer(), vertexCode->GetBufferSize(), nullptr, &vertex_);
        if (FAILED(hr)) return hr;
        hr = device_->CreatePixelShader(pixelCode->GetBufferPointer(), pixelCode->GetBufferSize(), nullptr, &pixel_);
        if (FAILED(hr)) return hr;
        D3D11_BUFFER_DESC buffer{};
        buffer.ByteWidth = sizeof(Placement);
        buffer.Usage = D3D11_USAGE_DEFAULT;
        buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        hr = device_->CreateBuffer(&buffer, nullptr, &placement_);
        if (FAILED(hr)) return hr;
        D3D11_RASTERIZER_DESC raster{};
        raster.FillMode = D3D11_FILL_SOLID;
        raster.CullMode = D3D11_CULL_NONE;
        raster.ScissorEnable = TRUE;
        raster.DepthClipEnable = TRUE;
        return device_->CreateRasterizerState(&raster, &raster_);
    }

    void ResetPointer() {
        visible_ = false;
        position_ = {};
        shapeInfo_ = {};
        shapeWidth_ = shapeHeight_ = 0;
        shape_.Reset(); shapeView_.Reset();
        background_.Reset(); backgroundView_.Reset();
    }

    void Shutdown() {
        ResetPointer();
        raster_.Reset(); placement_.Reset(); pixel_.Reset(); vertex_.Reset(); target_.Reset();
        destination_.Reset(); context_.Reset(); device_.Reset();
        width_ = height_ = 0;
    }

    void UpdatePosition(const DXGI_OUTDUPL_FRAME_INFO& frame) {
        // Zero means there was no pointer update; retain the cached visibility.
        if (!frame.LastMouseUpdateTime.QuadPart) return;
        visible_ = frame.PointerPosition.Visible != FALSE;
        if (visible_) position_ = frame.PointerPosition.Position;
    }

    HRESULT UpdateFrame(IDXGIOutputDuplication* duplication, const DXGI_OUTDUPL_FRAME_INFO& frame) {
        UpdatePosition(frame);
        if (!frame.PointerShapeBufferSize && (!visible_ || shapeView_)) return S_OK;
        if (!duplication) return E_INVALIDARG;
        constexpr UINT MaxShapeBytes = 16 * 1024 * 1024;
        if (frame.PointerShapeBufferSize > MaxShapeBytes) { ResetPointer(); return E_INVALIDARG; }
        rawShape_.resize((std::max)(32u, frame.PointerShapeBufferSize));
        UINT required = 0;
        DXGI_OUTDUPL_POINTER_SHAPE_INFO information{};
        HRESULT hr = duplication->GetFramePointerShape(static_cast<UINT>(rawShape_.size()),
            rawShape_.data(), &required, &information);
        if (hr == DXGI_ERROR_MORE_DATA && required && required <= MaxShapeBytes) {
            rawShape_.resize(required);
            hr = duplication->GetFramePointerShape(required, rawShape_.data(), &required, &information);
        }
        if (FAILED(hr)) { shapeView_.Reset(); return hr; }
        return SetShape(information, rawShape_.data(), (std::min)(static_cast<size_t>(required), rawShape_.size()));
    }

    HRESULT SetShape(const DXGI_OUTDUPL_POINTER_SHAPE_INFO& information, const uint8_t* bytes, size_t size) {
        shapeView_.Reset(); // Never draw an old shape after a failed shape update.
        const bool mono = information.Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME;
        if (!device_ || !bytes || !information.Width || !information.Height ||
            information.Width > 4096 || information.Height > 8192 ||
            (!mono && information.Type != DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR &&
                information.Type != DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR) ||
            (mono && information.Height % 2)) return E_INVALIDARG;
        const size_t rowBytes = mono ? (static_cast<size_t>(information.Width) + 7) / 8 : static_cast<size_t>(information.Width) * 4;
        if (information.Pitch < rowBytes || static_cast<uint64_t>(information.Pitch) * information.Height > size) return E_INVALIDARG;
        const UINT shapeHeight = mono ? information.Height / 2 : information.Height;
        if (shapeHeight > 4096) return E_INVALIDARG;
        std::vector<uint8_t> pixels(static_cast<size_t>(information.Width) * shapeHeight * 4);
        for (UINT y = 0; y < shapeHeight; ++y) {
            uint8_t* row = pixels.data() + static_cast<size_t>(y) * information.Width * 4;
            const uint8_t* source = bytes + static_cast<size_t>(y) * information.Pitch;
            if (!mono) {
                std::memcpy(row, source, rowBytes);
                continue;
            }
            const uint8_t* xorRow = bytes + static_cast<size_t>(y + shapeHeight) * information.Pitch;
            for (UINT x = 0; x < information.Width; ++x) {
                const uint8_t mask = static_cast<uint8_t>(0x80 >> (x % 8));
                row[x * 4] = (source[x / 8] & mask) ? 255 : 0;
                row[x * 4 + 1] = (xorRow[x / 8] & mask) ? 255 : 0;
            }
        }
        D3D11_TEXTURE2D_DESC texture{};
        texture.Width = information.Width; texture.Height = shapeHeight;
        texture.MipLevels = 1; texture.ArraySize = 1; texture.SampleDesc.Count = 1;
        texture.Format = DXGI_FORMAT_R8G8B8A8_UINT;
        texture.Usage = D3D11_USAGE_IMMUTABLE;
        texture.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        D3D11_SUBRESOURCE_DATA initial{};
        initial.pSysMem = pixels.data(); initial.SysMemPitch = information.Width * 4;
        ComPtr<ID3D11Texture2D> shape, background;
        ComPtr<ID3D11ShaderResourceView> shapeView, backgroundView;
        HRESULT hr = device_->CreateTexture2D(&texture, &initial, &shape);
        if (FAILED(hr)) return hr;
        hr = device_->CreateShaderResourceView(shape.Get(), nullptr, &shapeView);
        if (FAILED(hr)) return hr;
        texture.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        texture.Usage = D3D11_USAGE_DEFAULT;
        hr = device_->CreateTexture2D(&texture, nullptr, &background);
        if (FAILED(hr)) return hr;
        hr = device_->CreateShaderResourceView(background.Get(), nullptr, &backgroundView);
        if (FAILED(hr)) return hr;
        shape_ = shape; shapeView_ = shapeView;
        background_ = background; backgroundView_ = backgroundView;
        shapeInfo_ = information;
        shapeWidth_ = information.Width; shapeHeight_ = shapeHeight;
        return S_OK;
    }

    bool Draw() {
        if (!visible_ || !shapeView_ || !target_) return false;
        // Position already describes the top left in output-local pixels. DXGI's
        // hotspot is informational; subtracting it would offset the pointer twice.
        const LONG left = static_cast<LONG>((std::max)(0LL, static_cast<long long>(position_.x)));
        const LONG top = static_cast<LONG>((std::max)(0LL, static_cast<long long>(position_.y)));
        const LONG right = static_cast<LONG>((std::min)(static_cast<long long>(width_), static_cast<long long>(position_.x) + shapeWidth_));
        const LONG bottom = static_cast<LONG>((std::min)(static_cast<long long>(height_), static_cast<long long>(position_.y) + shapeHeight_));
        if (left >= right || top >= bottom) return false;

        // Only copy the cursor-sized background region. No CPU readback, full
        // screen shader pass or per-frame allocation is needed on the GPU path.
        D3D11_BOX box{ static_cast<UINT>(left), static_cast<UINT>(top), 0,
            static_cast<UINT>(right), static_cast<UINT>(bottom), 1 };
        context_->CopySubresourceRegion(background_.Get(), 0, 0, 0, 0, destination_.Get(), 0, &box);
        Placement data{ position_.x, position_.y, left, top, shapeInfo_.Type, {} };
        context_->UpdateSubresource(placement_.Get(), 0, nullptr, &data, 0, 0);
        ID3D11RenderTargetView* target = target_.Get();
        context_->OMSetRenderTargets(1, &target, nullptr);
        context_->OMSetBlendState(nullptr, nullptr, 0xffffffff);
        context_->OMSetDepthStencilState(nullptr, 0);
        context_->IASetInputLayout(nullptr);
        context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context_->VSSetShader(vertex_.Get(), nullptr, 0);
        context_->GSSetShader(nullptr, nullptr, 0);
        context_->PSSetShader(pixel_.Get(), nullptr, 0);
        ID3D11Buffer* constants = placement_.Get();
        context_->PSSetConstantBuffers(0, 1, &constants);
        ID3D11ShaderResourceView* resources[] = { shapeView_.Get(), backgroundView_.Get() };
        context_->PSSetShaderResources(0, 2, resources);
        D3D11_VIEWPORT viewport{ 0, 0, static_cast<float>(width_), static_cast<float>(height_), 0, 1 };
        context_->RSSetViewports(1, &viewport);
        D3D11_RECT clip{ left, top, right, bottom };
        context_->RSSetScissorRects(1, &clip);
        context_->RSSetState(raster_.Get());
        context_->Draw(3, 0);
        // The destination is handed to NVENC/MFT immediately after this call.
        ID3D11ShaderResourceView* empty[] = { nullptr, nullptr };
        context_->PSSetShaderResources(0, 2, empty);
        context_->OMSetRenderTargets(0, nullptr, nullptr);
        return true;
    }

private:
    struct Placement { LONG x, y, left, top; UINT type; UINT padding[3]; };
    static_assert(sizeof(Placement) == 32, "Cursor constant buffer must match HLSL packing");
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;
    ComPtr<ID3D11Texture2D> destination_, shape_, background_;
    ComPtr<ID3D11RenderTargetView> target_;
    ComPtr<ID3D11ShaderResourceView> shapeView_, backgroundView_;
    ComPtr<ID3D11VertexShader> vertex_;
    ComPtr<ID3D11PixelShader> pixel_;
    ComPtr<ID3D11Buffer> placement_;
    ComPtr<ID3D11RasterizerState> raster_;
    DXGI_OUTDUPL_POINTER_SHAPE_INFO shapeInfo_{};
    POINT position_{};
    bool visible_ = false;
    UINT width_ = 0, height_ = 0, shapeWidth_ = 0, shapeHeight_ = 0;
    std::vector<uint8_t> rawShape_;
};

} // namespace winsideusb
