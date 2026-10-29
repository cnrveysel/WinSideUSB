#pragma once

// Native desktop presentation. Included after the stream/detection/tray helpers.
#include <algorithm>
#include <commctrl.h>
#pragma comment(lib, "comctl32.lib")
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

static const int WIN_W = 560;
static const int WIN_H = 668;
static const int UI_BTN_SCALING = 117;
static const DWORD UI_WINDOW_STYLE = WS_OVERLAPPEDWINDOW & ~WS_MAXIMIZEBOX;
static UINT g_uiDpi = 96;

static const COLORREF UI_BG = RGB(245, 245, 247);
static const COLORREF UI_PANEL = RGB(255, 255, 255);
static const COLORREF UI_EDGE = RGB(229, 229, 234);
static const COLORREF UI_TEXT = RGB(29, 29, 31);
static const COLORREF UI_MUTED = RGB(107, 107, 115);
static const COLORREF UI_ACCENT = RGB(0, 113, 227);
static const COLORREF UI_READY = RGB(36, 128, 69);
static const COLORREF UI_WARN = RGB(154, 97, 0);
static const COLORREF UI_DANGER = RGB(196, 49, 49);

static HBRUSH g_brBg = nullptr;
static HBRUSH g_brPanel = nullptr;
static HFONT g_fontTitle = nullptr;
static HFONT g_fontBody = nullptr;
static HFONT g_fontSmall = nullptr;
static HFONT g_fontButton = nullptr;
static HFONT g_fontMetric = nullptr;
static ULONG_PTR g_gdiplusToken = 0;
static COLORREF g_statusColor = UI_MUTED;
static StreamStatus g_uiStatus = SS_DISCONNECTED;
static bool g_uiHasFrames = false;
static bool g_uiStopping = false;
static bool g_uiConnectionAttempted = false;
static bool g_uiVisibleDetection = false;
static int g_uiCardX = 32;
static int g_uiCardW = WIN_W - 64;

static int Dip(int value) { return MulDiv(value, g_uiDpi, 96); }

static UINT WindowDpi(HWND hwnd) {
    typedef UINT(WINAPI* GetDpiFn)(HWND);
    GetDpiFn getDpi = (GetDpiFn)GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow");
    if (getDpi && hwnd) return getDpi(hwnd);
    HDC dc = GetDC(hwnd);
    UINT dpi = dc ? (UINT)GetDeviceCaps(dc, LOGPIXELSY) : 96;
    if (dc) ReleaseDC(hwnd, dc);
    return dpi ? dpi : 96;
}

static HFONT MakeFont(int points, int weight) {
    return CreateFontW(-MulDiv(points, g_uiDpi, 72), 0, 0, 0, weight,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
}

static void DestroyUiFonts() {
    HFONT* fonts[] = { &g_fontTitle, &g_fontBody, &g_fontSmall, &g_fontButton, &g_fontMetric };
    for (HFONT* font : fonts) {
        if (*font) DeleteObject(*font);
        *font = nullptr;
    }
}

static void InitUiResources() {
    if (!g_gdiplusToken) {
        Gdiplus::GdiplusStartupInput input;
        Gdiplus::GdiplusStartup(&g_gdiplusToken, &input, nullptr);
    }
    if (!g_brBg) g_brBg = CreateSolidBrush(UI_BG);
    if (!g_brPanel) g_brPanel = CreateSolidBrush(UI_PANEL);
    if (!g_fontTitle) g_fontTitle = MakeFont(22, FW_SEMIBOLD);
    if (!g_fontBody) g_fontBody = MakeFont(11, FW_NORMAL);
    if (!g_fontSmall) g_fontSmall = MakeFont(10, FW_NORMAL);
    if (!g_fontButton) g_fontButton = MakeFont(11, FW_SEMIBOLD);
    if (!g_fontMetric) g_fontMetric = MakeFont(13, FW_SEMIBOLD);
}

static void DestroyUiResources() {
    DestroyUiFonts();
    if (g_brBg) { DeleteObject(g_brBg); g_brBg = nullptr; }
    if (g_brPanel) { DeleteObject(g_brPanel); g_brPanel = nullptr; }
    if (g_gdiplusToken) { Gdiplus::GdiplusShutdown(g_gdiplusToken); g_gdiplusToken = 0; }
}

static void ConfigureWindowChrome(HWND hwnd) {
    BOOL dark = FALSE;
    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
    // These attributes are optional on Windows 10; unsupported calls are harmless.
    DWORD corner = 2; // DWMWCP_ROUND
    DwmSetWindowAttribute(hwnd, (DWMWINDOWATTRIBUTE)33, &corner, sizeof(corner));
    COLORREF caption = UI_BG;
    DwmSetWindowAttribute(hwnd, (DWMWINDOWATTRIBUTE)35, &caption, sizeof(caption));
    COLORREF text = UI_TEXT;
    DwmSetWindowAttribute(hwnd, (DWMWINDOWATTRIBUTE)36, &text, sizeof(text));
}

static HWND CreateUiText(HWND hwnd, int id, const wchar_t* text, HFONT font,
    DWORD extraStyle = SS_ENDELLIPSIS) {
    HWND child = CreateWindowExW(0, L"STATIC", text, WS_CHILD | WS_VISIBLE | extraStyle,
        0, 0, 0, 0, hwnd, (HMENU)(INT_PTR)id, nullptr, nullptr);
    SendMessageW(child, WM_SETFONT, (WPARAM)font, FALSE);
    return child;
}

static void MoveUiControl(HWND hwnd, int id, int x, int y, int width, int height, HFONT font) {
    HWND child = GetDlgItem(hwnd, id);
    if (!child) return;
    SetWindowPos(child, nullptr, Dip(x), Dip(y), Dip(width), Dip(height), SWP_NOZORDER | SWP_NOACTIVATE);
    SendMessageW(child, WM_SETFONT, (WPARAM)font, FALSE);
}

static void LayoutUi(HWND hwnd) {
    RECT client{};
    GetClientRect(hwnd, &client);
    int width = MulDiv(client.right, 96, g_uiDpi);
    int height = MulDiv(client.bottom, 96, g_uiDpi);
    int margin = 32;
    g_uiCardX = margin;
    g_uiCardW = width - margin * 2;

    MoveUiControl(hwnd, IDC_TITLE, margin, 28, width - margin * 2 - 116, 38, g_fontTitle);
    MoveUiControl(hwnd, IDC_SUBTITLE, margin, 72, width - margin * 2, 24, g_fontSmall);
    MoveUiControl(hwnd, IDC_BTN_DETECT, width - margin - 104, 34, 104, 36, g_fontSmall);
    MoveUiControl(hwnd, IDC_LBL_STATUS, width / 2 - 96, 236, 208, 24, g_fontSmall);

    MoveUiControl(hwnd, IDC_LABEL_IPAD, margin + 24, 298, 100, 20, g_fontSmall);
    MoveUiControl(hwnd, IDC_LBL_IPAD, margin + 24, 322, g_uiCardW - 48, 27, g_fontBody);
    MoveUiControl(hwnd, IDC_LABEL_MODE, margin + 24, 369, g_uiCardW - 48, 20, g_fontSmall);
    MoveUiControl(hwnd, IDC_COMBO_MODE, margin + 24, 394, g_uiCardW - 48, 320, g_fontBody);
    HWND combo = GetDlgItem(hwnd, IDC_COMBO_MODE);
    SendMessageW(combo, CB_SETITEMHEIGHT, (WPARAM)-1, Dip(30));
    SendMessageW(combo, CB_SETITEMHEIGHT, 0, Dip(30));
    SendMessageW(combo, CB_SETDROPPEDWIDTH, Dip((std::max)(480, g_uiCardW - 48)), 0);
    SendMessageW(combo, CB_SETMINVISIBLE, 8, 0);
    MoveUiControl(hwnd, UI_BTN_SCALING, margin + 20, 433, 168, 26, g_fontSmall);

    MoveUiControl(hwnd, IDC_LABEL_ENCODER, margin + 4, 482, g_uiCardW - 140, 20, g_fontSmall);
    MoveUiControl(hwnd, IDC_LBL_ENCODER, margin + 4, 507, g_uiCardW - 140, 24, g_fontBody);
    MoveUiControl(hwnd, IDC_LABEL_FPS, width - margin - 104, 482, 100, 20, g_fontSmall);
    MoveUiControl(hwnd, IDC_LBL_FPS, width - margin - 104, 507, 100, 26, g_fontMetric);
    MoveUiControl(hwnd, IDC_HINT, margin + 4, 544, g_uiCardW - 8, 48, g_fontSmall);
    MoveUiControl(hwnd, IDC_BTN_ACTION, margin, height - 72, g_uiCardW, 42, g_fontButton);
    MoveUiControl(hwnd, IDC_BTN_LOGS, width / 2 - 64, height - 28, 128, 24, g_fontSmall);

    InvalidateRect(hwnd, nullptr, TRUE);
    RedrawWindow(hwnd, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
}

static void SetUiStatus(HWND hwnd, const wchar_t* text, COLORREF color, const wchar_t* hint) {
    g_statusColor = color;
    SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_STATUS), text);
    SetWindowTextW(GetDlgItem(hwnd, IDC_HINT), hint);
    RECT pill{};
    GetClientRect(hwnd, &pill);
    pill.top = Dip(226);
    pill.bottom = Dip(267);
    InvalidateRect(hwnd, &pill, FALSE);
}

static void UpdateModeHint(HWND hwnd) {
    int selection = (int)SendDlgItemMessageW(hwnd, IDC_COMBO_MODE, CB_GETCURSEL, 0, 0);
    if (selection < 0 || selection >= g_modeCount) return;
    std::wstring hint = ModeHint(g_modes[selection]);
    hint += g_streaming.load()
        ? L" To change mode: Stop display, choose a mode, then Start display."
        : L" Choose a mode, then Start display.";
    SetWindowTextW(GetDlgItem(hwnd, IDC_HINT), hint.c_str());
}

static void UpdateUiControls(HWND hwnd) {
    bool streaming = g_streaming.load();
    bool detecting = g_detecting.load();
    bool ready = !detecting && g_detectFound && g_modeCount > 0;
    EnableWindow(GetDlgItem(hwnd, IDC_BTN_ACTION), streaming ? !g_uiStopping : ready);
    EnableWindow(GetDlgItem(hwnd, IDC_BTN_DETECT), !streaming && !detecting);
    EnableWindow(GetDlgItem(hwnd, IDC_COMBO_MODE), !streaming && ready);
    EnableWindow(GetDlgItem(hwnd, UI_BTN_SCALING), g_detectFound && g_modeCount > 0);
    SetWindowTextW(GetDlgItem(hwnd, IDC_BTN_ACTION),
        g_uiStopping ? L"Stopping\u2026" : streaming ? L"Stop display" : L"Start display");
    SetWindowTextW(GetDlgItem(hwnd, IDC_BTN_DETECT), detecting ? L"Searching" : L"Refresh");
    InvalidateRect(GetDlgItem(hwnd, IDC_BTN_ACTION), nullptr, TRUE);
    InvalidateRect(GetDlgItem(hwnd, IDC_BTN_DETECT), nullptr, TRUE);
    InvalidateRect(GetDlgItem(hwnd, IDC_COMBO_MODE), nullptr, TRUE);
}

static void OnDetectionStarted(HWND hwnd) {
    g_uiVisibleDetection = true;
    SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_IPAD), L"Looking for your iPad\u2026");
    SetUiStatus(hwnd, L"Looking for iPad", UI_MUTED,
        L"Connect your iPad with a USB cable and unlock it.");
    UpdateUiControls(hwnd);
}

static void OnStreamStarting(HWND hwnd) {
    g_uiStopping = false;
    g_uiHasFrames = false;
    g_uiConnectionAttempted = true;
    g_uiStatus = SS_CONNECTING;
    SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_ENCODER), L"Preparing\u2026");
    SetUiStatus(hwnd, L"Connecting", UI_WARN, L"Keep the WinSideUSB app open on your iPad.");
    UpdateUiControls(hwnd);
}

static void OnStreamStopping(HWND hwnd) {
    g_uiStopping = true;
    SetUiStatus(hwnd, L"Stopping display", UI_MUTED, L"Disconnecting your virtual display\u2026");
    UpdateUiControls(hwnd);
}

static void OnUiStreamEnded(HWND hwnd) {
    g_uiStopping = false;
    g_uiHasFrames = false;
    SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_FPS), L"\u2014");
    SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_ENCODER), L"\u2014");
    UpdateUiControls(hwnd);
}

static Gdiplus::Color GdiColor(COLORREF c, BYTE alpha = 255) {
    return Gdiplus::Color(alpha, GetRValue(c), GetGValue(c), GetBValue(c));
}

static void AddRoundRectPath(Gdiplus::GraphicsPath& path, float x, float y,
    float width, float height, float radius) {
    float diameter = radius * 2;
    path.AddArc(x, y, diameter, diameter, 180, 90);
    path.AddArc(x + width - diameter, y, diameter, diameter, 270, 90);
    path.AddArc(x + width - diameter, y + height - diameter, diameter, diameter, 0, 90);
    path.AddArc(x, y + height - diameter, diameter, diameter, 90, 90);
    path.CloseFigure();
}

static void FillUiRoundRect(Gdiplus::Graphics& graphics, float x, float y,
    float width, float height, float radius, Gdiplus::Color color) {
    Gdiplus::GraphicsPath path;
    AddRoundRectPath(path, x, y, width, height, radius);
    Gdiplus::SolidBrush brush(color);
    graphics.FillPath(&brush, &path);
}

static void PaintWindowChrome(HWND hwnd, HDC dc) {
    RECT client{};
    GetClientRect(hwnd, &client);
    Gdiplus::Graphics graphics(dc);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.Clear(GdiColor(UI_BG));
    float scale = g_uiDpi / 96.0f;
    graphics.ScaleTransform(scale, scale);
    float center = client.right / scale / 2;

    // A quiet device illustration, drawn as vectors at the current display scale.
    Gdiplus::SolidBrush shadow(Gdiplus::Color(12, 0, 0, 0));
    graphics.FillEllipse(&shadow, center - 86, 215.0f, 172.0f, 9.0f);
    FillUiRoundRect(graphics, center - 96, 101, 192, 116, 14, Gdiplus::Color(255, 49, 51, 58));
    Gdiplus::GraphicsPath screen;
    AddRoundRectPath(screen, center - 90, 107, 180, 104, 9);
    Gdiplus::LinearGradientBrush wallpaper(Gdiplus::PointF(center - 90, 107),
        Gdiplus::PointF(center + 90, 211), Gdiplus::Color(255, 217, 235, 255),
        Gdiplus::Color(255, 178, 203, 246));
    graphics.FillPath(&wallpaper, &screen);
    FillUiRoundRect(graphics, center - 67, 122, 134, 72, 7, Gdiplus::Color(240, 255, 255, 255));
    FillUiRoundRect(graphics, center - 59, 130, 26, 56, 4, Gdiplus::Color(255, 241, 244, 250));
    FillUiRoundRect(graphics, center - 24, 134, 76, 5, 2, Gdiplus::Color(255, 204, 211, 225));
    FillUiRoundRect(graphics, center - 24, 148, 44, 4, 2, Gdiplus::Color(255, 226, 230, 237));
    FillUiRoundRect(graphics, center - 24, 161, 76, 4, 2, Gdiplus::Color(255, 226, 230, 237));
    FillUiRoundRect(graphics, center - 24, 174, 64, 4, 2, Gdiplus::Color(255, 226, 230, 237));

    FillUiRoundRect(graphics, center - 128, 229, 256, 36, 18, GdiColor(UI_PANEL));
    Gdiplus::SolidBrush statusDot(GdiColor(g_statusColor));
    graphics.FillEllipse(&statusDot, center - 110, 244.0f, 6.0f, 6.0f);

    FillUiRoundRect(graphics, (float)g_uiCardX, 278, (float)g_uiCardW, 188, 18, GdiColor(UI_PANEL));
    Gdiplus::Pen separator(GdiColor(UI_EDGE), 1);
    graphics.DrawLine(&separator, (float)g_uiCardX + 24, 359.0f,
        (float)g_uiCardX + g_uiCardW - 24, 359.0f);
}

static LRESULT CALLBACK UiButtonProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp,
    UINT_PTR, DWORD_PTR) {
    if (msg == WM_MOUSEMOVE) {
        if (!GetPropW(hwnd, L"WSUSBHover")) {
            SetPropW(hwnd, L"WSUSBHover", (HANDLE)1);
            TRACKMOUSEEVENT track{ sizeof(track), TME_LEAVE, hwnd, 0 };
            TrackMouseEvent(&track);
            InvalidateRect(hwnd, nullptr, FALSE);
        }
    }
    else if (msg == WM_MOUSELEAVE) {
        RemovePropW(hwnd, L"WSUSBHover");
        InvalidateRect(hwnd, nullptr, FALSE);
    }
    else if (msg == WM_SETFOCUS || msg == WM_KILLFOCUS || msg == WM_ENABLE) {
        InvalidateRect(hwnd, nullptr, FALSE);
    }
    else if (msg == WM_NCDESTROY) {
        RemovePropW(hwnd, L"WSUSBHover");
        RemoveWindowSubclass(hwnd, UiButtonProc, 1);
    }
    return DefSubclassProc(hwnd, msg, wp, lp);
}

static void DrawModernButton(const DRAWITEMSTRUCT* item) {
    RECT bounds = item->rcItem;
    bool disabled = (item->itemState & ODS_DISABLED) != 0;
    bool pressed = (item->itemState & ODS_SELECTED) != 0;
    bool hover = GetPropW(item->hwndItem, L"WSUSBHover") != nullptr;
    bool action = item->CtlID == IDC_BTN_ACTION;
    bool scaling = item->CtlID == UI_BTN_SCALING;
    bool logs = item->CtlID == IDC_BTN_LOGS || scaling;
    COLORREF surface = scaling ? UI_PANEL : UI_BG;
    bool stopping = g_streaming.load();
    COLORREF fill = logs ? surface : action ? (stopping ? RGB(254, 235, 235) : UI_ACCENT) : RGB(232, 232, 237);
    COLORREF text = logs ? UI_ACCENT : action ? (stopping ? UI_DANGER : RGB(255, 255, 255)) : UI_TEXT;
    if (disabled) { fill = logs ? surface : RGB(232, 232, 237); text = RGB(137, 137, 146); }
    else if (pressed || hover) {
        fill = logs ? RGB(233, 240, 249) : action ?
            (stopping ? RGB(249, 215, 215) : pressed ? RGB(0, 85, 178) : RGB(0, 103, 211)) : RGB(222, 222, 228);
    }

    Gdiplus::Graphics graphics(item->hDC);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.Clear(GdiColor(surface));
    float scale = g_uiDpi / 96.0f;
    float inset = 2 * scale;
    FillUiRoundRect(graphics, bounds.left + inset, bounds.top + inset,
        bounds.right - bounds.left - inset * 2, bounds.bottom - bounds.top - inset * 2,
        (logs ? 6 : 11) * scale, GdiColor(fill));

    if ((item->itemState & ODS_FOCUS) && !(item->itemState & ODS_NOFOCUSRECT)) {
        Gdiplus::GraphicsPath focus;
        AddRoundRectPath(focus, bounds.left + 0.5f * scale, bounds.top + 0.5f * scale,
            bounds.right - bounds.left - scale, bounds.bottom - bounds.top - scale, 13 * scale);
        Gdiplus::Pen ring(GdiColor(UI_ACCENT), 1.5f * scale);
        graphics.DrawPath(&ring, &focus);
    }
    wchar_t label[64]{};
    GetWindowTextW(item->hwndItem, label, 64);
    SetBkMode(item->hDC, TRANSPARENT);
    SetTextColor(item->hDC, text);
    HGDIOBJ oldFont = SelectObject(item->hDC, action ? g_fontButton : g_fontSmall);
    DrawTextW(item->hDC, label, -1, &bounds, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SelectObject(item->hDC, oldFont);
}

static void DrawComboItem(const DRAWITEMSTRUCT* item) {
    bool selected = (item->itemState & ODS_SELECTED) != 0;
    bool disabled = !IsWindowEnabled(item->hwndItem);
    bool closed = (item->itemState & ODS_COMBOBOXEDIT) != 0;
    HBRUSH brush = CreateSolidBrush(selected && !closed ? RGB(233, 243, 255) : UI_PANEL);
    FillRect(item->hDC, &item->rcItem, brush);
    DeleteObject(brush);
    std::wstring label = L"Connect an iPad to choose a mode";
    int index = (int)item->itemID;
    if (index < 0) index = (int)SendMessageW(item->hwndItem, CB_GETCURSEL, 0, 0);
    if (index >= 0) {
        LRESULT length = SendMessageW(item->hwndItem, CB_GETLBTEXTLEN, index, 0);
        if (length != CB_ERR && length >= 0) {
            // CB_GETLBTEXT does not accept a buffer length. Size to the actual
            // string so profile names and future mode labels cannot overflow.
            label.resize((size_t)length + 1);
            SendMessageW(item->hwndItem, CB_GETLBTEXT, index, (LPARAM)&label[0]);
            label.resize((size_t)length);
        }
    }
    RECT textBounds = item->rcItem;
    textBounds.left += Dip(10);
    textBounds.right -= Dip(8);
    SetBkMode(item->hDC, TRANSPARENT);
    SetTextColor(item->hDC, disabled ? UI_MUTED : UI_TEXT);
    HGDIOBJ oldFont = SelectObject(item->hDC, g_fontBody);
    DrawTextW(item->hDC, label.c_str(), -1, &textBounds, DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    SelectObject(item->hDC, oldFont);
    if ((item->itemState & ODS_FOCUS) && !closed) DrawFocusRect(item->hDC, &item->rcItem);
}

static void OpenDiagnostics(HWND hwnd) {
    wchar_t directory[MAX_PATH]{};
    DWORD size = GetEnvironmentVariableW(L"LOCALAPPDATA", directory, MAX_PATH);
    std::wstring path;
    if (size && size < MAX_PATH) path = std::wstring(directory) + L"\\WinSideUSB";
    else {
        GetModuleFileNameW(nullptr, directory, MAX_PATH);
        path = directory;
        size_t slash = path.find_last_of(L"\\/");
        if (slash != std::wstring::npos) path.resize(slash);
        path += L"\\WinSideUSBData";
    }
    CreateDirectoryW(path.c_str(), nullptr);
    if ((INT_PTR)ShellExecuteW(hwnd, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL) <= 32)
        MessageBoxW(hwnd, L"The log folder could not be opened.", L"WinSideUSB", MB_OK | MB_ICONINFORMATION);
}

static void OpenWindowsScaling(HWND hwnd) {
    if ((INT_PTR)ShellExecuteW(hwnd, L"open", L"ms-settings:display", nullptr, nullptr, SW_SHOWNORMAL) <= 32)
        MessageBoxW(hwnd, L"Windows display settings could not be opened.", L"WinSideUSB", MB_OK | MB_ICONINFORMATION);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_uiDpi = WindowDpi(hwnd);
        InitUiResources();
        ConfigureWindowChrome(hwnd);
        CreateUiText(hwnd, IDC_TITLE, L"WinSideUSB", g_fontTitle);
        CreateUiText(hwnd, IDC_SUBTITLE, L"Your iPad. More room to work.", g_fontSmall);
        CreateUiText(hwnd, IDC_LABEL_IPAD, L"Device", g_fontSmall);
        CreateUiText(hwnd, IDC_LBL_IPAD, L"Looking for your iPad\u2026", g_fontBody);
        CreateUiText(hwnd, IDC_LABEL_MODE, L"Profile, resolution & refresh rate", g_fontSmall);
        CreateUiText(hwnd, IDC_LBL_STATUS, L"Looking for iPad", g_fontSmall, SS_CENTER);
        CreateUiText(hwnd, IDC_LABEL_ENCODER, L"Video", g_fontSmall);
        CreateUiText(hwnd, IDC_LBL_ENCODER, L"\u2014", g_fontBody);
        CreateUiText(hwnd, IDC_LABEL_FPS, L"Frame rate", g_fontSmall, SS_RIGHT);
        CreateUiText(hwnd, IDC_LBL_FPS, L"\u2014", g_fontMetric, SS_RIGHT);
        CreateUiText(hwnd, IDC_HINT, L"Connect your iPad with a USB cable and unlock it.", g_fontSmall, SS_CENTER);

        int ids[] = { IDC_BTN_DETECT, UI_BTN_SCALING, IDC_BTN_ACTION, IDC_BTN_LOGS };
        const wchar_t* labels[] = { L"Refresh", L"Windows scaling", L"Start display", L"View logs" };
        for (int i = 0; i < 4; ++i) {
            HWND button = CreateWindowExW(0, L"BUTTON", labels[i],
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 0, 0,
                hwnd, (HMENU)(INT_PTR)ids[i], nullptr, nullptr);
            SetWindowSubclass(button, UiButtonProc, 1, 0);
        }
        HWND combo = CreateWindowExW(0, L"COMBOBOX", nullptr,
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST |
            CBS_OWNERDRAWFIXED | CBS_HASSTRINGS, 0, 0, 0, 0,
            hwnd, (HMENU)(INT_PTR)IDC_COMBO_MODE, nullptr, nullptr);
        SetWindowTheme(combo, L"Explorer", nullptr);
        // Tab order: refresh, mode, Windows scaling, primary action, logs.
        SetWindowPos(combo, GetDlgItem(hwnd, IDC_BTN_DETECT), 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        LayoutUi(hwnd);
        UpdateUiControls(hwnd);
        TriggerDetect(hwnd);
        SetTimer(hwnd, 1, 1000, nullptr);
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        HDC dc = BeginPaint(hwnd, &paint);
        RECT client{};
        GetClientRect(hwnd, &client);
        HDC buffer = CreateCompatibleDC(dc);
        HBITMAP bitmap = CreateCompatibleBitmap(dc, client.right, client.bottom);
        if (buffer && bitmap) {
            HGDIOBJ old = SelectObject(buffer, bitmap);
            PaintWindowChrome(hwnd, buffer);
            BitBlt(dc, 0, 0, client.right, client.bottom, buffer, 0, 0, SRCCOPY);
            SelectObject(buffer, old);
        }
        else PaintWindowChrome(hwnd, dc);
        if (bitmap) DeleteObject(bitmap);
        if (buffer) DeleteDC(buffer);
        EndPaint(hwnd, &paint);
        return 0;
    }
    case WM_ERASEBKGND: return TRUE;
    case WM_PRINTCLIENT:
        PaintWindowChrome(hwnd, (HDC)wp);
        return 0;
    case WM_CTLCOLORSTATIC: {
        HDC dc = (HDC)wp;
        int id = GetDlgCtrlID((HWND)lp);
        bool card = id == IDC_LABEL_IPAD || id == IDC_LBL_IPAD || id == IDC_LABEL_MODE;
        bool panel = card || id == IDC_LBL_STATUS;
        COLORREF color = id == IDC_LBL_STATUS ? g_statusColor :
            id == IDC_TITLE || id == IDC_LBL_IPAD || id == IDC_LBL_ENCODER || id == IDC_LBL_FPS ? UI_TEXT : UI_MUTED;
        SetTextColor(dc, color);
        SetBkColor(dc, panel ? UI_PANEL : UI_BG);
        SetBkMode(dc, OPAQUE);
        return (LRESULT)(panel ? g_brPanel : g_brBg);
    }
    case WM_CTLCOLORLISTBOX:
    case WM_CTLCOLOREDIT:
        SetBkColor((HDC)wp, UI_PANEL);
        SetTextColor((HDC)wp, UI_TEXT);
        return (LRESULT)g_brPanel;
    case WM_DRAWITEM: {
        const DRAWITEMSTRUCT* item = (const DRAWITEMSTRUCT*)lp;
        if (!item) break;
        if (item->CtlID == IDC_COMBO_MODE) { DrawComboItem(item); return TRUE; }
        if (item->CtlID == IDC_BTN_ACTION || item->CtlID == IDC_BTN_DETECT ||
            item->CtlID == IDC_BTN_LOGS || item->CtlID == UI_BTN_SCALING) {
            DrawModernButton(item); return TRUE;
        }
        break;
    }
    case WM_MEASUREITEM: {
        MEASUREITEMSTRUCT* item = (MEASUREITEMSTRUCT*)lp;
        if (item && item->CtlID == IDC_COMBO_MODE) { item->itemHeight = Dip(30); return TRUE; }
        break;
    }
    case WM_DETECT_DONE: {
        if (g_closing.load()) return 0;
        g_detecting = false;
        if (g_detectThread.joinable()) g_detectThread.join();
        if (!g_detectionSameDevice) g_autoStartSuppressed = false;
        SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_IPAD), g_detectFound ? g_detectedName.c_str() : L"No iPad connected");
        HWND combo = GetDlgItem(hwnd, IDC_COMBO_MODE);
        if (!g_detectionSameDevice) {
            SendMessageW(combo, CB_RESETCONTENT, 0, 0);
            for (int i = 0; g_detectFound && i < g_modeCount; ++i) {
                std::wstring label = ModeLabel(g_modes[i]);
                SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)label.c_str());
            }
        }
        if (g_detectFound && g_modeCount > 0) {
            int selection = 0;
            for (int i = 0; i < g_modeCount; ++i) {
                if (g_modes[i].w == g_targetW && g_modes[i].h == g_targetH &&
                    g_modes[i].fps == g_targetFPS.load()) { selection = i; break; }
            }
            SendMessageW(combo, CB_SETCURSEL, selection, 0);
            SelectModeOption(selection, false);
            if (!g_detectionSameDevice || g_uiVisibleDetection) {
                SetUiStatus(hwnd, L"Ready to connect", UI_READY,
                    L"Open WinSideUSB on your iPad. Your display will connect automatically.");
                UpdateModeHint(hwnd);
            }
        }
        else SetUiStatus(hwnd, L"Connect your iPad", UI_MUTED,
            L"Use a USB cable, unlock your iPad and trust this computer.");
        g_uiVisibleDetection = false;
        UpdateUiControls(hwnd);
        if (g_detectFound && !g_autoStartSuppressed && GetTickCount64() >= g_nextAutoAttempt)
            StartStream(hwnd);
        return 0;
    }
    case WM_STREAM_STATUS: {
        StreamStatus status = (StreamStatus)wp;
        bool encoder = status == SS_ENCODER_GPU || status == SS_ENCODER_HW || status == SS_ENCODER_SW;
        if (!encoder) g_uiStatus = status;
        if (status == SS_DISCONNECTED) {
            bool stopped = g_uiStopping;
            OnStreamEnded(hwnd);
            SetUiStatus(hwnd, g_detectFound ? (stopped ? L"Display stopped" : L"Disconnected") : L"Connect your iPad", UI_MUTED,
                stopped ? L"Your iPad is ready whenever you are." : g_uiConnectionAttempted ?
                L"Check the iPad app and driver. View logs for connection details." :
                L"Use a USB cable, unlock your iPad and trust this computer.");
            std::wstring error = GetStreamError();
            if (!error.empty()) {
                g_autoStartSuppressed = true;
                SetUiStatus(hwnd, L"Display could not start", UI_WARN, error.c_str());
            }
            else if (stopped && g_detectFound) UpdateModeHint(hwnd);
        }
        else if (!g_uiStopping) {
            switch (status) {
            case SS_CONNECTING:
                SetUiStatus(hwnd, L"Connecting", UI_WARN, L"Keep the WinSideUSB app open on your iPad."); break;
            case SS_WAITING_IPAD_APP:
                SetUiStatus(hwnd, L"Waiting for iPad app", UI_WARN, L"Open WinSideUSB on your iPad to continue."); break;
            case SS_CONNECTED:
                SetUiStatus(hwnd, g_uiHasFrames ? L"Display active" : L"Preparing display", UI_READY,
                    g_uiHasFrames ? L"Move a Windows window onto your iPad to get started." : L"Your iPad is connected. Preparing the video stream\u2026");
                if (g_uiHasFrames) UpdateModeHint(hwnd);
                break;
            case SS_ENCODER_GPU: SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_ENCODER), L"GPU acceleration"); break;
            case SS_ENCODER_HW: SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_ENCODER), L"Hardware encoding"); break;
            case SS_ENCODER_SW: SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_ENCODER), L"Software encoding"); break;
            case SS_PAUSED:
                SetUiStatus(hwnd, L"Display paused", UI_WARN, L"Windows paused capture. Waiting for the display to resume."); break;
            default: break;
            }
        }
        return 0;
    }
    case WM_STREAM_FPS: {
        if (g_uiStopping || !g_streaming.load()) return 0;
        wchar_t label[32];
        swprintf_s(label, L"%.1f fps", wp / 10.0);
        SetWindowTextW(GetDlgItem(hwnd, IDC_LBL_FPS), label);
        if (wp > 0 && !g_uiHasFrames) {
            g_uiHasFrames = true;
            if (g_uiStatus == SS_CONNECTED) {
                SetUiStatus(hwnd, L"Display active", UI_READY, L"Move a Windows window onto your iPad to get started.");
                UpdateModeHint(hwnd);
            }
        }
        return 0;
    }
    case WM_TIMER:
        if (wp == 1 && !g_closing.load() && !g_streaming.load() && !g_streamCompletionPending &&
            !g_detecting.load() && GetTickCount64() >= g_nextPresenceCheck) {
            g_nextPresenceCheck = GetTickCount64() + 3000;
            TriggerDetect(hwnd, true);
        }
        return 0;
    case WM_DEVICECHANGE:
        if (wp == DBT_DEVNODES_CHANGED || wp == DBT_DEVICEARRIVAL || wp == DBT_DEVICEREMOVECOMPLETE) {
            g_deviceChangePending = true;
            g_nextPresenceCheck = 0;
            if (!g_streaming.load()) TriggerDetect(hwnd, true);
        }
        return 0;
    case WM_DPICHANGED: {
        g_uiDpi = HIWORD(wp);
        DestroyUiFonts();
        InitUiResources();
        const RECT* suggested = (const RECT*)lp;
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
            suggested->right - suggested->left, suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        LayoutUi(hwnd);
        return 0;
    }
    case WM_GETMINMAXINFO: {
        MINMAXINFO* info = (MINMAXINFO*)lp;
        RECT bounds{ 0, 0, Dip(520), Dip(WIN_H) };
        typedef BOOL(WINAPI* AdjustDpiFn)(LPRECT, DWORD, BOOL, DWORD, UINT);
        AdjustDpiFn adjust = (AdjustDpiFn)GetProcAddress(GetModuleHandleW(L"user32.dll"), "AdjustWindowRectExForDpi");
        if (adjust) adjust(&bounds, UI_WINDOW_STYLE, FALSE, 0, g_uiDpi);
        else AdjustWindowRectEx(&bounds, UI_WINDOW_STYLE, FALSE, 0);
        info->ptMinTrackSize = { bounds.right - bounds.left, bounds.bottom - bounds.top };
        return 0;
    }
    case WM_SIZE:
        if (wp == SIZE_MINIMIZED) { ShowWindow(hwnd, SW_HIDE); AddTrayIcon(hwnd); }
        else if (g_fontTitle) LayoutUi(hwnd);
        return 0;
    case WM_TRAY_MSG:
        if (lp == WM_LBUTTONDBLCLK || lp == WM_RBUTTONUP) ShowTrayMenu(hwnd);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDM_SHOW: RemoveTrayIcon(); ShowWindow(hwnd, SW_RESTORE); SetForegroundWindow(hwnd); break;
        case IDC_BTN_DETECT: if (!g_streaming.load()) TriggerDetect(hwnd); break;
        case IDC_BTN_LOGS: OpenDiagnostics(hwnd); break;
        case UI_BTN_SCALING: if (g_detectFound) OpenWindowsScaling(hwnd); break;
        case IDC_COMBO_MODE:
            if (HIWORD(wp) == CBN_SELCHANGE && !g_streaming.load() && !g_detecting.load()) {
                int selection = (int)SendDlgItemMessageW(hwnd, IDC_COMBO_MODE, CB_GETCURSEL, 0, 0);
                if (SelectModeOption(selection)) UpdateModeHint(hwnd);
            }
            break;
        case IDC_BTN_ACTION:
            if (g_streaming.load()) { if (!g_uiStopping) StopStream(hwnd); }
            else if (!g_detecting.load() && g_detectFound && g_modeCount > 0) {
                g_autoStartSuppressed = false;
                StartStream(hwnd);
            }
            break;
        case IDM_EXIT: StopStream(hwnd); DestroyWindow(hwnd); break;
        }
        return 0;
    case WM_CLOSE: StopStream(hwnd); DestroyWindow(hwnd); return 0;
    case WM_DESTROY:
        g_closing = true;
        g_stop = true;
        KillTimer(hwnd, 1);
        DisconnectVirtualDisplay();
        RemoveTrayIcon();
        DestroyUiResources();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
