// Native IPC tests: only private test pipes/events are created. These tests do
// not call the broker/device APIs, read setup ownership, or install a service.
#define WINSIDEUSB_DISPLAY_SERVICE_TEST
#include "../WinSideUSB/SignedDisplayService.cpp"
#include <cstdio>
#include <cstring>
#include <thread>
#include <iterator>
#define WINSIDEUSB_DISPLAY_CLIENT_TEST
#include "../WinSideUSB/SignedDisplayClient.h"

namespace winsideusb {
class SignedDisplayClientTests {
public:
    static bool RejectWrongServer(HANDLE pipe) {
        SignedDisplayClient client;
        client.pipe_ = pipe;
        const bool rejected = !client.ValidateServer(L"C:\\Program Files\\WinSideUSB");
        client.pipe_ = INVALID_HANDLE_VALUE; // TestPipe retains ownership.
        return rejected;
    }
    static bool MatchesIdentity(ULONG serverPid, const SERVICE_STATUS_PROCESS& status,
        const QUERY_SERVICE_CONFIGW& config, const std::wstring& expectedImage) {
        return SignedDisplayClient::MatchesServiceIdentity(serverPid, status, config, expectedImage);
    }
    static bool ValidateInstalledServer(HANDLE pipe, const std::wstring& installDir) {
        SignedDisplayClient client;
        client.pipe_ = pipe;
        const bool valid = client.ValidateServer(installDir);
        client.pipe_ = INVALID_HANDLE_VALUE;
        return valid;
    }
};
}

namespace {
int failures = 0;
void Check(bool success, const char* message) {
    std::printf("%s %s\n", success ? "PASS" : "FAIL", message);
    if (!success) ++failures;
}

class TestPipe {
public:
    Handle server;
    Handle client;
    TestPipe() {
        const std::wstring name = L"\\\\.\\pipe\\WinSideUSBDisplay.Test." +
            std::to_wstring(GetCurrentProcessId()) + L"." + std::to_wstring(GetTickCount64());
        server.reset(CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
            FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT |
            PIPE_REJECT_REMOTE_CLIENTS, 1, 1024, 1024, 0, nullptr));
        if (!server.valid()) return;
        client.reset(CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr));
        if (!client.valid()) return;
        DWORD mode = PIPE_READMODE_MESSAGE;
        SetNamedPipeHandleState(client.get(), &mode, nullptr, nullptr);
        Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        OVERLAPPED overlap{};
        overlap.hEvent = event.get();
        if (!ConnectNamedPipe(server.get(), &overlap) && GetLastError() != ERROR_PIPE_CONNECTED) {
            server.reset(); client.reset();
        }
    }
    bool valid() const { return server.valid() && client.valid(); }
    bool Send(const void* data, DWORD bytes) {
        DWORD written = 0;
        return WriteFile(client.get(), data, bytes, &written, nullptr) && written == bytes;
    }
    bool Receive(Reply& reply) {
        DWORD received = 0;
        return ReadFile(client.get(), &reply, sizeof(reply), &received, nullptr) && received == sizeof(reply);
    }
};

struct FakeDevice {
    std::atomic<int> activations{0}, deactivations{0};
    std::atomic<bool> enabled{false};
    Handle death{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    DWORD activationError = ERROR_SUCCESS;
};
FakeDevice* fakeDevice = nullptr;
DWORD FakeAuthenticate(HANDLE, Handle& process, DWORD& session) {
    HANDLE handle = nullptr;
    if (!DuplicateHandle(GetCurrentProcess(), fakeDevice->death.get(), GetCurrentProcess(), &handle,
        0, FALSE, DUPLICATE_SAME_ACCESS)) return GetLastError();
    process.reset(handle);
    session = 1;
    return ERROR_SUCCESS;
}
DWORD FakeUnauthorized(HANDLE, Handle&, DWORD&) { return ERROR_ACCESS_DENIED; }
bool FakeConsole(DWORD session) { return session == 1; }
DWORD FakeSetDevice(bool enabled, HANDLE) {
    if (enabled) {
        ++fakeDevice->activations;
        // Model a failure after the node already changed, to exercise rollback.
        fakeDevice->enabled.store(true);
        return fakeDevice->activationError;
    }
    ++fakeDevice->deactivations;
    fakeDevice->enabled.store(false);
    return ERROR_SUCCESS;
}

BrokerHooks FakeHooks() {
    BrokerHooks hooks;
    hooks.authenticate = FakeAuthenticate;
    hooks.activeConsole = FakeConsole;
    hooks.setEnabled = FakeSetDevice;
    hooks.leaseTimeoutMs = 3000;
    return hooks;
}
} // namespace

int main(int argc, char** argv) {
    g_stop.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    g_sessionEnded.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    Check(g_stop.valid() && g_sessionEnded.valid(), "test cancellation events");
    WTSINFOEXW sessionInfo{};
    sessionInfo.Level = 1;
    sessionInfo.Data.WTSInfoExLevel1.SessionId = 1;
    sessionInfo.Data.WTSInfoExLevel1.SessionState = WTSActive;
    sessionInfo.Data.WTSInfoExLevel1.SessionFlags = WTS_SESSIONSTATE_UNLOCK;
    Check(UnlockedConsoleInfo(sessionInfo, 1), "unlocked active console authorization");
    sessionInfo.Data.WTSInfoExLevel1.SessionFlags = WTS_SESSIONSTATE_LOCK;
    Check(!UnlockedConsoleInfo(sessionInfo, 1), "already locked active console rejected");
    sessionInfo.Data.WTSInfoExLevel1.SessionFlags = WTS_SESSIONSTATE_UNLOCK;
    Check(!UnlockedConsoleInfo(sessionInfo, 2), "different interactive session rejected");
    sessionInfo.Data.WTSInfoExLevel1.SessionState = WTSDisconnected;
    Check(!UnlockedConsoleInfo(sessionInfo, 1), "disconnected console rejected");
    Request request{};
    Check(IsValidRequest(request), "valid heartbeat protocol");
    request.command = Command::Activate;
    Check(IsValidRequest(request), "valid activation protocol");
    request.version = Version + 1;
    Check(!IsValidRequest(request), "future protocol version rejected");
    request.version = Version; request.reserved = 1;
    Check(!IsValidRequest(request), "unrecognized flags rejected");
    request.reserved = 0; request.command = static_cast<Command>(99);
    Check(!IsValidRequest(request), "unrecognized command rejected");
    request.command = Command::Ping; request.magic = 0;
    Check(!IsValidRequest(request), "foreign protocol rejected");
    request.magic = Magic;

    {
        wchar_t image[32768]{};
        GetModuleFileNameW(nullptr, image, (DWORD)std::size(image));
        std::wstring command = L"\"" + std::wstring(image) + L"\"";
        wchar_t systemAccount[] = L"LocalSystem";
        wchar_t otherAccount[] = L"LocalService";
        SERVICE_STATUS_PROCESS status{};
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = SERVICE_RUNNING;
        status.dwProcessId = 123;
        QUERY_SERVICE_CONFIGW config{};
        config.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        config.lpServiceStartName = systemAccount;
        config.lpBinaryPathName = command.data();
        auto matches = [&] {
            return winsideusb::SignedDisplayClientTests::MatchesIdentity(123, status, config, image);
        };
        Check(matches(), "SCM identity accepts exact running LocalSystem image without opening its process");
        status.dwProcessId = 124;
        Check(!matches(), "SCM identity rejects a different pipe server PID");
        status.dwProcessId = 123;
        status.dwCurrentState = SERVICE_STOPPED;
        Check(!matches(), "SCM identity rejects a stopped service");
        status.dwCurrentState = SERVICE_RUNNING;
        config.dwServiceType = SERVICE_WIN32_SHARE_PROCESS;
        Check(!matches(), "SCM identity rejects a shared-process service");
        config.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        config.lpServiceStartName = otherAccount;
        Check(!matches(), "SCM identity rejects a different service account");
        config.lpServiceStartName = systemAccount;
        config.lpBinaryPathName = image;
        Check(!matches(), "SCM identity rejects an unquoted executable path");
        command += L" --other";
        config.lpBinaryPathName = command.data();
        Check(!matches(), "SCM identity rejects extra service arguments");
        command = L"\"C:\\not-installed\\WinSideUSBDisplayService.exe\"";
        config.lpBinaryPathName = command.data();
        Check(!matches(), "SCM identity rejects another configured executable");
    }

    // Opt-in read-only check against the real installed service. It opens and
    // closes the pipe without sending any activation or other device request.
    if (argc == 2 && std::strcmp(argv[1], "--installed-service") == 0) {
        std::wstring installDir;
        const bool configured = winsideusb::ReadDisplaySetting(L"InstallDir", installDir);
        Handle installedPipe(CreateFileW(PipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
            OPEN_EXISTING, FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr));
        Check(configured && installedPipe.valid() &&
            winsideusb::SignedDisplayClientTests::ValidateInstalledServer(installedPipe.get(), installDir),
            "ordinary user validates real LocalSystem pipe server through SCM without activating a display");
    }

    {
        TestPipe pipe;
        Handle process;
        DWORD session = InvalidSession;
        Check(pipe.valid() && AuthenticatePipeProcess(pipe.server.get(), L"C:\\not-installed\\WinSideUSB.exe",
            process, session) == ERROR_ACCESS_DENIED, "real foreign client executable rejected");
        Check(winsideusb::SignedDisplayClientTests::RejectWrongServer(pipe.client.get()),
            "client rejects pipe server that is not its running SCM service");
        Request received{};
        const bool transferred = pipe.Send(&request, sizeof(request)) &&
            Transfer(pipe.server.get(), false, &received, sizeof(received), nullptr, 1000) == ERROR_SUCCESS;
        bool identificationReadable = false;
        if (transferred && ImpersonateNamedPipeClient(pipe.server.get())) {
            HANDLE token = nullptr;
            if (OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token)) {
                Handle identity(token);
                SECURITY_IMPERSONATION_LEVEL level = SecurityAnonymous;
                DWORD size = 0;
                identificationReadable = GetTokenInformation(token, TokenImpersonationLevel, &level,
                    sizeof(level), &size) && level == SecurityIdentification;
            }
            if (!RevertToSelf()) return 2;
        }
        Check(identificationReadable, "identification-only IPC token can be queried safely");
    }

    for (int kind = 0; kind < 9; ++kind) {
        TestPipe pipe;
        FakeDevice device;
        fakeDevice = &device;
        BrokerHooks hooks = FakeHooks();
        if (kind == 0) hooks.authenticate = FakeUnauthorized;
        if (kind == 5) hooks.leaseTimeoutMs = 75;
        if (kind == 6) device.activationError = ERROR_SUCCESS_REBOOT_REQUIRED;
        DWORD brokerResult = ERROR_GEN_FAILURE;
        std::thread broker([&] { brokerResult = ServeClient(pipe.server.get(), hooks); });
        Request activation{};
        activation.command = kind == 1 ? static_cast<Command>(99) : Command::Activate;
        Reply reply{};
        const bool replied = pipe.Send(&activation, sizeof(activation)) && pipe.Receive(reply);
        if (kind == 0 || kind == 1 || kind == 6) {
            broker.join();
            Check(replied && reply.error == static_cast<DWORD>(kind == 1 ? ERROR_INVALID_DATA :
                kind == 0 ? ERROR_ACCESS_DENIED : ERROR_SUCCESS_REBOOT_REQUIRED) &&
                !device.enabled.load() && device.activations.load() == (kind == 6 ? 1 : 0),
                kind == 0 ? "unauthorized lease cannot activate device" :
                kind == 1 ? "malformed command cannot activate device" :
                "failed activation returns reboot status and rolls back enabled node");
        } else {
            Check(replied && !reply.error && reply.state == State::Active && device.enabled.load(),
                "authenticated activation holds its device lease");
            if (kind == 2) pipe.client.reset();
            if (kind == 3) SetEvent(device.death.get());
            if (kind == 4) SetEvent(g_sessionEnded.get());
            if (kind == 7) SetEvent(g_stop.get());
            if (kind == 8) {
                Request deactivate{};
                deactivate.command = Command::Deactivate;
                Reply deactivated{};
                Check(pipe.Send(&deactivate, sizeof(deactivate)) && pipe.Receive(deactivated) &&
                    !deactivated.error && deactivated.state == State::Inactive && !device.enabled.load(),
                    "explicit Deactivate acknowledges disabled state");
                pipe.client.reset();
            }
            // kind5 deliberately stops sending heartbeat traffic.
            broker.join();
            Check(!brokerResult && !device.enabled.load() && device.deactivations.load() >= 1 &&
                g_clientSession.load() == InvalidSession, kind == 2 ? "broken client lease disables owned device" :
                kind == 3 ? "client death disables owned device" : kind == 4 ? "session end disables owned device" :
                kind == 7 ? "SCM stop disables active owned device" : kind == 8 ? "deactivated lease leaves no owned display active" :
                "expired heartbeat lease disables owned device");
        }
        ResetEvent(g_stop.get()); ResetEvent(g_sessionEnded.get());
        fakeDevice = nullptr;
    }

    {
        TestPipe pipe;
        Request received{};
        Check(pipe.valid() && pipe.Send(&request, sizeof(request)) &&
            Transfer(pipe.server.get(), false, &received, sizeof(received), nullptr, 1000) == ERROR_SUCCESS &&
            IsValidRequest(received), "whole request transferred through real message pipe");
    }
    {
        TestPipe pipe;
        Request received{};
        const ULONGLONG before = GetTickCount64();
        const DWORD result = Transfer(pipe.server.get(), false, &received, sizeof(received), nullptr, 75);
        Check(pipe.valid() && result == ERROR_TIMEOUT && GetTickCount64() - before < 2000,
            "idle lease read times out and cancellation drains");
        Check(pipe.Send(&request, sizeof(request)) &&
            Transfer(pipe.server.get(), false, &received, sizeof(received), nullptr, 1000) == ERROR_SUCCESS,
            "pipe remains usable after cancelled read");
    }
    {
        TestPipe pipe;
        Request received{};
        Check(pipe.valid() && pipe.Send(&request, 4) &&
            Transfer(pipe.server.get(), false, &received, sizeof(received), nullptr, 1000) == ERROR_INVALID_DATA,
            "truncated message rejected");
    }
    {
        TestPipe pipe;
        DWORD oversized[8]{};
        Request received{};
        Check(pipe.valid() && pipe.Send(oversized, sizeof(oversized)) &&
            Transfer(pipe.server.get(), false, &received, sizeof(received), nullptr, 1000) == ERROR_MORE_DATA,
            "oversized message rejected without interpreting payload");
    }
    {
        TestPipe pipe;
        Request received{};
        std::thread closer([&pipe] { Sleep(25); pipe.client.reset(); });
        const DWORD result = Transfer(pipe.server.get(), false, &received, sizeof(received), nullptr, 1000);
        closer.join();
        Check(result == ERROR_BROKEN_PIPE, "client disconnect wakes pending read");
    }
    for (int kind = 0; kind < 3; ++kind) {
        TestPipe pipe;
        Handle death(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        HANDLE signal = kind == 0 ? g_stop.get() : kind == 1 ? g_sessionEnded.get() : death.get();
        std::thread cancel([signal] { Sleep(25); SetEvent(signal); });
        Request received{};
        const DWORD result = Transfer(pipe.server.get(), false, &received, sizeof(received),
            kind == 2 ? death.get() : nullptr, 1000);
        cancel.join();
        Check(result == ERROR_OPERATION_ABORTED, kind == 0 ? "SCM stop cancels pending lease read" :
            kind == 1 ? "session end cancels pending lease read" : "waitable client death cancels pending lease read");
        ResetEvent(g_stop.get()); ResetEvent(g_sessionEnded.get());
    }
    return failures ? 1 : 0;
}
