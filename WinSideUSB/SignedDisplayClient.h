#pragma once

#include <Windows.h>
#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <iterator>
#include "SharedDisplayProtocol.h"

#pragma comment(lib, "advapi32.lib")

namespace winsideusb {

inline bool ReadDisplaySetting(const wchar_t* name, std::wstring& value) {
    DWORD bytes = 0;
    if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WinSideUSB", name,
        RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, nullptr, &bytes) != ERROR_SUCCESS ||
        bytes < sizeof(wchar_t) || bytes > 32768) return false;
    std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, 0);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WinSideUSB", name,
        RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, buffer.data(), &bytes) != ERROR_SUCCESS) return false;
    value.assign(buffer.data());
    return !value.empty();
}

inline bool HasSignedDisplayConfiguration() {
    HKEY key = nullptr;
    LONG result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WinSideUSB", 0,
        KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key);
    if (key) RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

inline std::wstring FinalFilePath(const std::wstring& path) {
    HANDLE file = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return {};
    std::vector<wchar_t> buffer(32768);
    DWORD length = GetFinalPathNameByHandleW(file, buffer.data(), (DWORD)buffer.size(), FILE_NAME_NORMALIZED);
    CloseHandle(file);
    if (!length || length >= buffer.size()) return {};
    return std::wstring(buffer.data(), length);
}

// The persistent pipe is a lease: its closure removes the display even when the
// client crashes. Only the installed SCM service is allowed to grant a lease.
class SignedDisplayClient {
public:
    ~SignedDisplayClient() { Close(); }
    SignedDisplayClient() = default;
    SignedDisplayClient(const SignedDisplayClient&) = delete;
    SignedDisplayClient& operator=(const SignedDisplayClient&) = delete;

    static bool IsInstalledApp() {
        std::wstring installDir;
        wchar_t ownPath[32768]{};
        return ReadDisplaySetting(L"InstallDir", installDir) &&
            GetModuleFileNameW(nullptr, ownPath, (DWORD)std::size(ownPath)) &&
            SameFile(ownPath, installDir + L"\\WinSideUSB.exe");
    }

    bool Activate(std::wstring& instanceId, DWORD& error, const std::atomic<bool>& cancelled) {
        std::lock_guard<std::mutex> lock(mutex_);
        DropLocked();
        std::wstring installDir;
        if (!ReadDisplaySetting(L"InstallDir", installDir) ||
            !ReadDisplaySetting(L"ManagedDeviceInstanceId", instanceId) ||
            _wcsnicmp(instanceId.c_str(), L"ROOT\\MTTVDD\\", 12) != 0) {
            error = ERROR_BAD_CONFIGURATION;
            return false;
        }
        wchar_t ownPath[32768]{};
        if (!GetModuleFileNameW(nullptr, ownPath, (DWORD)std::size(ownPath)) ||
            !SameFile(ownPath, installDir + L"\\WinSideUSB.exe")) {
            error = ERROR_ACCESS_DENIED;
            return false;
        }
        const ULONGLONG deadline = GetTickCount64() + 4000;
        do {
            if (cancelled.load()) { error = ERROR_CANCELLED; return false; }
            pipe_ = CreateFileW(WinSideUSBDisplay::PipeName, GENERIC_READ | GENERIC_WRITE,
                0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED |
                SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
            if (pipe_ != INVALID_HANDLE_VALUE) break;
            error = GetLastError();
            if (error != ERROR_PIPE_BUSY && error != ERROR_FILE_NOT_FOUND) return false;
            Sleep(100);
        } while (GetTickCount64() < deadline);
        if (pipe_ == INVALID_HANDLE_VALUE) return false;
        if (!ValidateServer(installDir)) {
            error = ERROR_ACCESS_DENIED;
            DropLocked();
            return false;
        }
        DWORD readMode = PIPE_READMODE_MESSAGE;
        if (!SetNamedPipeHandleState(pipe_, &readMode, nullptr, nullptr)) {
            error = GetLastError(); DropLocked(); return false;
        }
        if (!CommandLocked(WinSideUSBDisplay::Command::Activate, error, 20000, &cancelled)) {
            DropLocked(); return false;
        }
        active_ = true;
        return true;
    }

    bool Ping(DWORD& error, const std::atomic<bool>& cancelled) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_) { error = ERROR_NOT_CONNECTED; return false; }
        if (!CommandLocked(WinSideUSBDisplay::Command::Ping, error, 2000, &cancelled)) {
            DropLocked(); return false;
        }
        return true;
    }

    void Close() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_) {
            DWORD ignored = 0;
            CommandLocked(WinSideUSBDisplay::Command::Deactivate, ignored, 2000, nullptr);
        }
        DropLocked();
    }

private:
#ifdef WINSIDEUSB_DISPLAY_CLIENT_TEST
    friend class SignedDisplayClientTests;
#endif
    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    bool active_ = false;
    std::mutex mutex_;

    static bool SameFile(const std::wstring& left, const std::wstring& right) {
        std::wstring a = FinalFilePath(left), b = FinalFilePath(right);
        return !a.empty() && !b.empty() && _wcsicmp(a.c_str(), b.c_str()) == 0;
    }

    bool ValidateServer(const std::wstring& installDir) {
        ULONG serverPid = 0;
        if (!GetNamedPipeServerProcessId(pipe_, &serverPid)) return false;
        SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
        if (!manager) return false;
        SC_HANDLE service = OpenServiceW(manager, WinSideUSBDisplay::ServiceName,
            SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG);
        SERVICE_STATUS_PROCESS status{};
        DWORD bytes = 0;
        bool valid = service && QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
            reinterpret_cast<BYTE*>(&status), sizeof(status), &bytes);
        std::vector<BYTE> buffer;
        if (valid) {
            QueryServiceConfigW(service, nullptr, 0, &bytes);
            valid = GetLastError() == ERROR_INSUFFICIENT_BUFFER &&
                bytes >= sizeof(QUERY_SERVICE_CONFIGW) && bytes <= 8192;
            if (valid) {
                buffer.resize(bytes);
                auto* config = reinterpret_cast<QUERY_SERVICE_CONFIGW*>(buffer.data());
                valid = QueryServiceConfigW(service, config, bytes, &bytes) &&
                    MatchesServiceIdentity(serverPid, status, *config,
                        installDir + L"\\WinSideUSBDisplayService.exe");
            }
        }
        if (service) CloseServiceHandle(service);
        CloseServiceHandle(manager);
        return valid;
    }

    static bool MatchesServiceIdentity(ULONG serverPid, const SERVICE_STATUS_PROCESS& status,
        const QUERY_SERVICE_CONFIGW& config, const std::wstring& expectedImage) {
        // SCM supplies the trusted running PID and configuration to ordinary
        // users. Opening a LocalSystem process is normally denied to them.
        // Tie the actual pipe server to this own-process LocalSystem service,
        // and require the exact installed executable with no extra arguments.
        if (!serverPid || status.dwCurrentState != SERVICE_RUNNING ||
            status.dwProcessId != serverPid || status.dwServiceType != SERVICE_WIN32_OWN_PROCESS ||
            config.dwServiceType != SERVICE_WIN32_OWN_PROCESS || !config.lpServiceStartName ||
            _wcsicmp(config.lpServiceStartName, L"LocalSystem") != 0 || !config.lpBinaryPathName)
            return false;
        const std::wstring command(config.lpBinaryPathName);
        if (command.size() < 3 || command.front() != L'"' || command.back() != L'"' ||
            command.find(L'"', 1) != command.size() - 1) return false;
        return SameFile(command.substr(1, command.size() - 2), expectedImage);
    }

    bool TransferLocked(bool writing, void* buffer, DWORD bytes, DWORD timeoutMs,
        const std::atomic<bool>* cancelled, DWORD& error) {
        OVERLAPPED operation{};
        operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!operation.hEvent) { error = GetLastError(); return false; }
        DWORD transferred = 0;
        BOOL ok = writing ? WriteFile(pipe_, buffer, bytes, &transferred, &operation) :
            ReadFile(pipe_, buffer, bytes, &transferred, &operation);
        if (!ok && GetLastError() == ERROR_IO_PENDING) {
            ULONGLONG deadline = GetTickCount64() + timeoutMs;
            do {
                if (cancelled && cancelled->load()) { error = ERROR_CANCELLED; break; }
                DWORD wait = WaitForSingleObject(operation.hEvent, 100);
                if (wait == WAIT_OBJECT_0) {
                    ok = GetOverlappedResult(pipe_, &operation, &transferred, FALSE);
                    if (!ok) error = GetLastError();
                    break;
                }
                if (wait == WAIT_FAILED) { error = GetLastError(); break; }
                error = ERROR_TIMEOUT;
            } while (GetTickCount64() < deadline);
            if (!ok) {
                CancelIoEx(pipe_, &operation);
                GetOverlappedResult(pipe_, &operation, &transferred, TRUE);
            }
        } else if (!ok) error = GetLastError();
        CloseHandle(operation.hEvent);
        if (ok && transferred != bytes) { error = ERROR_INVALID_DATA; return false; }
        return ok != FALSE;
    }

    bool CommandLocked(WinSideUSBDisplay::Command command, DWORD& error,
        DWORD timeoutMs, const std::atomic<bool>* cancelled) {
        error = ERROR_SUCCESS;
        WinSideUSBDisplay::Request request{};
        request.command = command;
        WinSideUSBDisplay::Reply reply{};
        if (!TransferLocked(true, &request, sizeof(request), timeoutMs, cancelled, error) ||
            !TransferLocked(false, &reply, sizeof(reply), timeoutMs, cancelled, error)) return false;
        if (reply.magic != WinSideUSBDisplay::Magic || reply.version != WinSideUSBDisplay::Version ||
            (reply.state != WinSideUSBDisplay::State::Active && reply.state != WinSideUSBDisplay::State::Inactive)) {
            error = ERROR_INVALID_DATA; return false;
        }
        error = reply.error;
        if (error) return false;
        bool shouldBeActive = command != WinSideUSBDisplay::Command::Deactivate;
        if ((reply.state == WinSideUSBDisplay::State::Active) != shouldBeActive) {
            error = ERROR_NOT_READY; return false;
        }
        return true;
    }

    void DropLocked() {
        if (pipe_ != INVALID_HANDLE_VALUE) CloseHandle(pipe_);
        pipe_ = INVALID_HANDLE_VALUE;
        active_ = false;
    }
};
} // namespace winsideusb
