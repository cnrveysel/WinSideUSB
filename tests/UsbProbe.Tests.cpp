#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <atomic>
#include <algorithm>
#include <string>
#include <vector>
#include <thread>
#include <iostream>
static std::atomic<bool> g_closing{ false };
static std::string g_toolDirectory;
static std::string EnsureBundledToolsDirA() { return g_toolDirectory; }
// Generated directly from the application source by the test runner.
#include "UsbProbe.implementation.h"
static int failures = 0, checks = 0;
static void Check(bool condition, const char* name) {
    ++checks;
    if (!condition) { ++failures; std::cerr << "FAIL: " << name << '\n'; }
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    g_toolDirectory = argv[1];
    Check(RunIdeviceinfo("success", "", false) == "1111-2222", "successful child output is retained and trimmed");
    Check(RunIdeviceinfo("closeearly", "", false) == "1111-2222", "closed stdout before process exit retains output");
    Check(RunIdeviceinfo("arguments", "1111-2222", true) == "1111-2222", "exact device and simple probe arguments reach child");
    Check(RunIdeviceinfo("nonzero", "", false).empty(), "nonzero child exit discards output");
    Check(RunIdeviceinfo("oversize", "", false).empty(), "oversized output is rejected");
    Check(RunIdeviceinfo("success", "1111 & other-command", false).empty(), "invalid UDID cannot create command arguments");
    ULONGLONG start = GetTickCount64();
    Check(RunIdeviceinfo("hang", "", false).empty(), "hung tool fails without blocking");
    Check(GetTickCount64() - start < 3500, "hung tool has bounded lifetime");
    start = GetTickCount64();
    std::thread cancel([] { Sleep(100); g_closing = true; });
    const bool canceled = RunIdeviceinfo("hang", "", false).empty();
    cancel.join();
    Check(canceled && GetTickCount64() - start < 1000, "app exit cancels owned child promptly");
    g_closing = false;
    DWORD before = 0, after = 0;
    GetProcessHandleCount(GetCurrentProcess(), &before);
    bool retained = true;
    for (int i = 0; i < 20; ++i) retained = retained && RunIdeviceinfo("closeearly", "", false) == "1111-2222";
    GetProcessHandleCount(GetCurrentProcess(), &after);
    Check(retained, "repeated detection retains valid output");
    Check(after <= before, "repeated probes close process, thread and pipe handles");
    g_toolDirectory += "\\absent";
    Check(RunIdeviceinfo("success", "", false).empty(), "missing tool fails cleanly");
    std::cout << checks << " USB probe checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
