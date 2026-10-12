#include <windows.h>
#include <aclapi.h>
#include <cfgmgr32.h>
#include <sddl.h>
#include <setupapi.h>
#include <wtsapi32.h>
#include <atomic>
#include <cwchar>
#include <mutex>
#include <string>
#include <vector>

#include "SharedDisplayProtocol.h"

namespace {
using namespace WinSideUSBDisplay;
constexpr wchar_t RegistryPath[] = L"SOFTWARE\\WinSideUSB";
constexpr wchar_t HardwareId[] = L"Root\\MttVDD";
constexpr GUID DisplayClass = {0x4d36e968, 0xe325, 0x11ce, {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};
constexpr DWORD InvalidSession = 0xffffffff;

class Handle {
public:
    explicit Handle(HANDLE value = nullptr) : value_(value) {}
    ~Handle() { reset(); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    HANDLE get() const { return value_; }
    bool valid() const { return value_ && value_ != INVALID_HANDLE_VALUE; }
    void reset(HANDLE value = nullptr) {
        if (valid()) CloseHandle(value_);
        value_ = value;
    }
private:
    HANDLE value_;
};

SERVICE_STATUS_HANDLE g_statusHandle = nullptr;
SERVICE_STATUS g_status{};
std::mutex g_statusMutex;
Handle g_stop;
Handle g_sessionEnded;
std::atomic<DWORD> g_clientSession{InvalidSession};
std::wstring g_deviceId;
std::wstring g_installDir;
std::wstring g_clientImage;

void LogFailure(const wchar_t* operation, DWORD error) {
    const std::wstring detail = std::wstring(operation) + L" failed: " + std::to_wstring(error);
    OutputDebugStringW((detail + L"\n").c_str());
    HANDLE source = RegisterEventSourceW(nullptr, ServiceName);
    if (source) {
        const wchar_t* strings[] = {detail.c_str()};
        ReportEventW(source, EVENTLOG_ERROR_TYPE, 0, 1, nullptr, 1, 0, strings, nullptr);
        DeregisterEventSource(source);
    }
}

void ReportStatus(DWORD state, DWORD error = ERROR_SUCCESS, DWORD waitHint = 0) {
    std::lock_guard<std::mutex> lock(g_statusMutex);
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_status.dwCurrentState = state;
    g_status.dwWin32ExitCode = error;
    g_status.dwWaitHint = waitHint;
    g_status.dwControlsAccepted = state == SERVICE_RUNNING ?
        SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_SESSIONCHANGE : 0;
    g_status.dwCheckPoint = state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING ?
        g_status.dwCheckPoint + 1 : 0;
    SetServiceStatus(g_statusHandle, &g_status);
}

bool Stopping() { return WaitForSingleObject(g_stop.get(), 0) == WAIT_OBJECT_0; }

bool TrustedSid(PSID sid) {
    BYTE system[SECURITY_MAX_SID_SIZE], administrators[SECURITY_MAX_SID_SIZE];
    DWORD size = sizeof(system);
    if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system, &size)) return false;
    size = sizeof(administrators);
    if (!CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr, administrators, &size)) return false;
    if (EqualSid(sid, system) || EqualSid(sid, administrators)) return true;
    PSID installer = nullptr;
    if (!ConvertStringSidToSidW(L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464", &installer)) return false;
    const bool trusted = EqualSid(sid, installer) != FALSE;
    LocalFree(installer);
    return trusted;
}

// The service consumes administrator-owned setup state. A standard user must
// not redirect this broker to another device or substitute an installed client.
DWORD CheckTrustedSecurity(HANDLE object, SE_OBJECT_TYPE type, DWORD writeMask) {
    PSID owner = nullptr;
    PACL dacl = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    DWORD error = GetSecurityInfo(object, type, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        &owner, nullptr, &dacl, nullptr, &descriptor);
    if (error != ERROR_SUCCESS) return error;
    bool trusted = owner && TrustedSid(owner) && dacl;
    if (trusted) {
        for (DWORD index = 0; index < dacl->AceCount; ++index) {
            void* raw = nullptr;
            if (!GetAce(dacl, index, &raw)) { trusted = false; break; }
            const auto* header = static_cast<ACE_HEADER*>(raw);
            if (header->AceFlags & INHERIT_ONLY_ACE) continue;
            if (header->AceType == ACCESS_ALLOWED_ACE_TYPE) {
                const auto* ace = static_cast<ACCESS_ALLOWED_ACE*>(raw);
                if ((ace->Mask & writeMask) && !TrustedSid(const_cast<DWORD*>(&ace->SidStart))) {
                    trusted = false; break;
                }
            } else if (header->AceType != ACCESS_DENIED_ACE_TYPE && header->AceType != SYSTEM_AUDIT_ACE_TYPE) {
                // Do not reinterpret object/callback ACE layouts as simple ACEs.
                trusted = false; break;
            }
        }
    }
    LocalFree(descriptor);
    return trusted ? ERROR_SUCCESS : ERROR_ACCESS_DENIED;
}

DWORD ReadString(HKEY key, const wchar_t* name, std::wstring& value) {
    DWORD type = 0, size = 0;
    LSTATUS result = RegQueryValueExW(key, name, nullptr, &type, nullptr, &size);
    if (result != ERROR_SUCCESS) return static_cast<DWORD>(result);
    if (type != REG_SZ || size < sizeof(wchar_t) || size > 32768 * sizeof(wchar_t) || size % sizeof(wchar_t))
        return ERROR_INVALID_DATA;
    std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, L'\0');
    result = RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<BYTE*>(buffer.data()), &size);
    if (result != ERROR_SUCCESS) return static_cast<DWORD>(result);
    if (buffer[size / sizeof(wchar_t) - 1] != L'\0') return ERROR_INVALID_DATA;
    value = buffer.data();
    return value.empty() ? ERROR_INVALID_DATA : ERROR_SUCCESS;
}

std::wstring FinalPath(HANDLE file) {
    const DWORD size = GetFinalPathNameByHandleW(file, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!size || size > 32768) return {};
    std::vector<wchar_t> path(size + 1);
    const DWORD written = GetFinalPathNameByHandleW(file, path.data(), static_cast<DWORD>(path.size()),
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!written || written >= path.size()) return {};
    std::wstring result(path.data(), written);
    if (result.compare(0, 4, L"\\\\?\\") == 0) result.erase(0, 4);
    return result;
}

DWORD TrustedClientImage(const std::wstring& installDir, std::wstring& finalImage) {
    std::wstring cursor = installDir;
    BY_HANDLE_FILE_INFORMATION info{};
    DWORD error = ERROR_SUCCESS;
    while (true) {
        Handle directory(CreateFileW(cursor.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        if (!directory.valid()) return GetLastError();
        if (!GetFileInformationByHandle(directory.get(), &info)) return GetLastError();
        if (!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
            return ERROR_ACCESS_DENIED;
        DWORD writes = FILE_DELETE_CHILD | DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL;
        if (cursor == installDir) writes |= FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES;
        error = CheckTrustedSecurity(directory.get(), SE_FILE_OBJECT, writes);
        if (error) return error;
        if (cursor.size() == 3) break;
        const std::size_t separator = cursor.find_last_of(L'\\');
        if (separator == std::wstring::npos || separator < 2) return ERROR_BAD_PATHNAME;
        cursor.resize(separator == 2 ? 3 : separator);
    }
    const std::wstring imagePath = installDir + L"\\WinSideUSB.exe";
    Handle image(CreateFileW(imagePath.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!image.valid()) return GetLastError();
    if (!GetFileInformationByHandle(image.get(), &info)) return GetLastError();
    if (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_ACCESS_DENIED;
    error = CheckTrustedSecurity(image.get(), SE_FILE_OBJECT,
        FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES |
        DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL);
    if (!error) finalImage = FinalPath(image.get());
    return error ? error : finalImage.empty() ? ERROR_BAD_PATHNAME : ERROR_SUCCESS;
}

DWORD LoadConfiguration() {
    HKEY key = nullptr;
    LSTATUS result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, RegistryPath, 0, KEY_READ | KEY_WOW64_64KEY, &key);
    if (result != ERROR_SUCCESS) return static_cast<DWORD>(result);
    DWORD error = CheckTrustedSecurity(key, SE_REGISTRY_KEY,
        KEY_SET_VALUE | KEY_CREATE_SUB_KEY | DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL);
    if (!error) error = ReadString(key, L"ManagedDeviceInstanceId", g_deviceId);
    if (!error) error = ReadString(key, L"InstallDir", g_installDir);
    RegCloseKey(key);
    if (error) return error;
    if (g_deviceId.size() > MAX_DEVICE_ID_LEN || g_deviceId.size() <= 12 ||
        _wcsnicmp(g_deviceId.c_str(), L"ROOT\\MTTVDD\\", 12) != 0 ||
        g_deviceId.substr(12).find_first_not_of(L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789&_") != std::wstring::npos)
        return ERROR_INVALID_DATA;
    if (g_installDir.size() < 3 || g_installDir[1] != L':' || g_installDir[2] != L'\\') return ERROR_INVALID_DATA;
    while (g_installDir.size() > 3 && g_installDir.back() == L'\\') g_installDir.pop_back();
    std::vector<wchar_t> fullPath(32768);
    const DWORD length = GetFullPathNameW(g_installDir.c_str(), static_cast<DWORD>(fullPath.size()), fullPath.data(), nullptr);
    if (!length || length >= fullPath.size()) return ERROR_BAD_PATHNAME;
    g_installDir.assign(fullPath.data(), length);
    return TrustedClientImage(g_installDir, g_clientImage);
}

bool ActiveConsole(DWORD session);

DWORD SetDeviceEnabled(bool enable, HANDLE client = nullptr) {
    if (enable && (Stopping() || !ActiveConsole(g_clientSession.load()) ||
        WaitForSingleObject(g_sessionEnded.get(), 0) == WAIT_OBJECT_0 ||
        (client && WaitForSingleObject(client, 0) != WAIT_TIMEOUT))) return ERROR_OPERATION_ABORTED;
    HDEVINFO set = SetupDiCreateDeviceInfoList(&DisplayClass, nullptr);
    if (set == INVALID_HANDLE_VALUE) return GetLastError();
    SP_DEVINFO_DATA data{};
    data.cbSize = sizeof(data);
    DWORD error = ERROR_SUCCESS;
    if (!SetupDiOpenDeviceInfoW(set, g_deviceId.c_str(), nullptr, 0, &data)) error = GetLastError();
    if (!error && !IsEqualGUID(data.ClassGuid, DisplayClass)) error = ERROR_ACCESS_DENIED;
    DWORD type = 0, size = 0;
    if (!error) {
        SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID, &type, nullptr, 0, &size);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || type != REG_MULTI_SZ ||
            size < 2 * sizeof(wchar_t) || size > 65536 || size % sizeof(wchar_t)) error = ERROR_INVALID_DATA;
    }
    if (!error) {
        std::vector<wchar_t> ids(size / sizeof(wchar_t) + 2, L'\0');
        if (!SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID, &type,
            reinterpret_cast<BYTE*>(ids.data()), size, nullptr)) error = GetLastError();
        else {
            bool found = false;
            for (const wchar_t* id = ids.data(); *id; id += std::wcslen(id) + 1)
                if (_wcsicmp(id, HardwareId) == 0) found = true;
            if (!found) error = ERROR_ACCESS_DENIED;
        }
    }
    if (!error && enable) {
        // Setup creates/disables this root node through SetupAPI. Enabling only
        // its live devnode does not clear CONFIGFLAG_DISABLED or profile flags.
        // Apply the matching property change globally and to the current profile.
        SP_PROPCHANGE_PARAMS change{};
        change.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
        change.ClassInstallHeader.InstallFunction = DIF_PROPERTYCHANGE;
        change.StateChange = DICS_ENABLE;
        for (DWORD scope : {DICS_FLAG_GLOBAL, DICS_FLAG_CONFIGSPECIFIC}) {
            if (Stopping() || !ActiveConsole(g_clientSession.load()) ||
                WaitForSingleObject(g_sessionEnded.get(), 0) == WAIT_OBJECT_0 ||
                (client && WaitForSingleObject(client, 0) != WAIT_TIMEOUT)) {
                error = ERROR_OPERATION_ABORTED; break;
            }
            change.Scope = scope;
            if (!SetupDiSetClassInstallParamsW(set, &data, &change.ClassInstallHeader, sizeof(change)) ||
                !SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, set, &data)) {
                error = GetLastError(); break;
            }
        }
        SP_DEVINSTALL_PARAMS_W parameters{};
        parameters.cbSize = sizeof(parameters);
        if (!error && !SetupDiGetDeviceInstallParamsW(set, &data, &parameters)) error = GetLastError();
        if (!error && (parameters.Flags & (DI_NEEDREBOOT | DI_NEEDRESTART)))
            error = ERROR_SUCCESS_REBOOT_REQUIRED;
    } else if (!error) {
        const CONFIGRET result = CM_Disable_DevNode(data.DevInst, CM_DISABLE_PERSIST | CM_DISABLE_UI_NOT_OK);
        if (result != CR_SUCCESS) error = CM_MapCrToWin32Err(result, ERROR_GEN_FAILURE);
    }
    if (!error) {
        const ULONGLONG deadline = GetTickCount64() + 10000;
        while (true) {
            if (enable && (Stopping() || !ActiveConsole(g_clientSession.load()) ||
                WaitForSingleObject(g_sessionEnded.get(), 0) == WAIT_OBJECT_0 ||
                (client && WaitForSingleObject(client, 0) != WAIT_TIMEOUT))) {
                error = ERROR_OPERATION_ABORTED; break;
            }
            ULONG status = 0, problem = 0;
            const CONFIGRET result = CM_Get_DevNode_Status(&status, &problem, data.DevInst, 0);
            if (!enable && (result == CR_NO_SUCH_DEVNODE ||
                (result == CR_SUCCESS && !(status & DN_STARTED) && problem == CM_PROB_DISABLED))) break;
            if (result != CR_SUCCESS) { error = CM_MapCrToWin32Err(result, ERROR_GEN_FAILURE); break; }
            if (enable && problem == 0 && status & DN_STARTED) break;
            if (status & DN_NEED_RESTART || problem == CM_PROB_NEED_RESTART) { error = ERROR_SUCCESS_REBOOT_REQUIRED; break; }
            if (GetTickCount64() >= deadline) {
                const std::wstring detail = L"Managed display readiness (problem " +
                    std::to_wstring(problem) + L", status " + std::to_wstring(status) + L")";
                LogFailure(detail.c_str(), ERROR_TIMEOUT);
                error = ERROR_TIMEOUT; break;
            }
            Sleep(50);
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return error;
}

bool UnlockedConsoleInfo(const WTSINFOEXW& info, DWORD session) {
    // On supported Windows 11 systems, an active session can still be locked.
    // Checking this on every request also closes the event-before-lease race.
    return info.Level == 1 && info.Data.WTSInfoExLevel1.SessionId == session &&
        info.Data.WTSInfoExLevel1.SessionState == WTSActive &&
        info.Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_UNLOCK;
}

bool ActiveConsole(DWORD session) {
    if (session == InvalidSession || session == 0 || session != WTSGetActiveConsoleSessionId()) return false;
    wchar_t* raw = nullptr;
    DWORD bytes = 0;
    bool active = false;
    if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session, WTSConnectState, &raw, &bytes)) {
        active = bytes >= sizeof(WTS_CONNECTSTATE_CLASS) &&
            *reinterpret_cast<WTS_CONNECTSTATE_CLASS*>(raw) == WTSActive;
        WTSFreeMemory(raw);
    }
    if (!active) return false;
    raw = nullptr;
    bytes = 0;
    if (!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session, WTSSessionInfoEx, &raw, &bytes)) return false;
    const bool unlocked = bytes >= sizeof(WTSINFOEXW) &&
        UnlockedConsoleInfo(*reinterpret_cast<WTSINFOEXW*>(raw), session);
    WTSFreeMemory(raw);
    return unlocked;
}

bool ReadToken(HANDLE token, TOKEN_INFORMATION_CLASS type, std::vector<BYTE>& data) {
    DWORD size = 0;
    GetTokenInformation(token, type, nullptr, 0, &size);
    if (!size || size > 65536) return false;
    data.resize(size);
    return GetTokenInformation(token, type, data.data(), size, &size) != FALSE;
}

DWORD AuthenticatePipeProcess(HANDLE pipe, const std::wstring& expectedImage, Handle& process, DWORD& session) {
    ULONG processId = 0, pipeSession = 0;
    if (!GetNamedPipeClientProcessId(pipe, &processId) || !GetNamedPipeClientSessionId(pipe, &pipeSession))
        return GetLastError();
    process.reset(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, processId));
    if (!process.valid()) return GetLastError();
    std::vector<wchar_t> path(32768);
    DWORD length = static_cast<DWORD>(path.size());
    if (!QueryFullProcessImageNameW(process.get(), 0, path.data(), &length)) return GetLastError();
    Handle image(CreateFileW(path.data(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, 0, nullptr));
    if (!image.valid()) return GetLastError();
    if (_wcsicmp(FinalPath(image.get()).c_str(), expectedImage.c_str()) != 0) return ERROR_ACCESS_DENIED;
    Handle processToken;
    HANDLE rawToken = nullptr;
    if (!OpenProcessToken(process.get(), TOKEN_QUERY, &rawToken)) return GetLastError();
    processToken.reset(rawToken);
    std::vector<BYTE> processUser, processSession;
    if (!ReadToken(processToken.get(), TokenUser, processUser) ||
        !ReadToken(processToken.get(), TokenSessionId, processSession)) return ERROR_ACCESS_DENIED;
    session = *reinterpret_cast<DWORD*>(processSession.data());
    if (session != pipeSession || !ActiveConsole(session)) return ERROR_ACCESS_DENIED;

    // A local process can open a pipe under a different impersonation token.
    // Match both identities and require the INTERACTIVE logon SID.
    if (!ImpersonateNamedPipeClient(pipe)) return GetLastError();
    Handle clientToken;
    std::vector<BYTE> clientUser, clientSession, groups;
    DWORD error = ERROR_ACCESS_DENIED;
    if (OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &rawToken)) {
        clientToken.reset(rawToken);
        if (ReadToken(clientToken.get(), TokenUser, clientUser) &&
            ReadToken(clientToken.get(), TokenSessionId, clientSession) &&
            ReadToken(clientToken.get(), TokenGroups, groups)) {
            BYTE interactive[SECURITY_MAX_SID_SIZE];
            DWORD size = sizeof(interactive);
            bool hasInteractive = false;
            if (CreateWellKnownSid(WinInteractiveSid, nullptr, interactive, &size)) {
                const auto* tokenGroups = reinterpret_cast<TOKEN_GROUPS*>(groups.data());
                for (DWORD index = 0; index < tokenGroups->GroupCount; ++index)
                    if ((tokenGroups->Groups[index].Attributes & SE_GROUP_ENABLED) &&
                        EqualSid(tokenGroups->Groups[index].Sid, interactive)) hasInteractive = true;
            }
            if (hasInteractive && *reinterpret_cast<DWORD*>(clientSession.data()) == session &&
                EqualSid(reinterpret_cast<TOKEN_USER*>(clientUser.data())->User.Sid,
                    reinterpret_cast<TOKEN_USER*>(processUser.data())->User.Sid)) error = ERROR_SUCCESS;
        }
    }
    if (!RevertToSelf()) ExitProcess(ERROR_CANNOT_IMPERSONATE);
    return error;
}

DWORD AuthenticateClient(HANDLE pipe, Handle& process, DWORD& session) {
    std::wstring currentInstalledImage;
    const DWORD error = TrustedClientImage(g_installDir, currentInstalledImage);
    if (error || _wcsicmp(currentInstalledImage.c_str(), g_clientImage.c_str()) != 0)
        return error ? error : ERROR_ACCESS_DENIED;
    return AuthenticatePipeProcess(pipe, g_clientImage, process, session);
}

DWORD WaitIo(HANDLE pipe, OVERLAPPED& overlapped, HANDLE client, DWORD timeout, DWORD& bytes) {
    HANDLE handles[] = {g_stop.get(), g_sessionEnded.get(), overlapped.hEvent, client};
    const DWORD result = WaitForMultipleObjects(client ? 4 : 3, handles, FALSE, timeout);
    if (result == WAIT_OBJECT_0 + 2) {
        if (!GetOverlappedResult(pipe, &overlapped, &bytes, FALSE)) return GetLastError();
        return ERROR_SUCCESS;
    }
    const DWORD error = result == WAIT_TIMEOUT ? ERROR_TIMEOUT :
        result == WAIT_FAILED ? GetLastError() : ERROR_OPERATION_ABORTED;
    CancelIoEx(pipe, &overlapped);
    // OVERLAPPED/event/buffer remain alive until cancellation is complete.
    GetOverlappedResult(pipe, &overlapped, &bytes, TRUE);
    return error;
}

DWORD Transfer(HANDLE pipe, bool write, void* buffer, DWORD size, HANDLE client, DWORD timeout) {
    Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!event.valid()) return GetLastError();
    OVERLAPPED overlapped{};
    overlapped.hEvent = event.get();
    DWORD bytes = 0;
    const BOOL success = write ? WriteFile(pipe, buffer, size, &bytes, &overlapped) :
        ReadFile(pipe, buffer, size, &bytes, &overlapped);
    DWORD error = success ? ERROR_SUCCESS : GetLastError();
    if (error == ERROR_IO_PENDING) error = WaitIo(pipe, overlapped, client, timeout, bytes);
    return error ? error : bytes == size ? ERROR_SUCCESS : ERROR_INVALID_DATA;
}

// Fixed native operations in production; the native IPC harness substitutes
// only these boundaries so it never enables a real device or needs SCM setup.
struct BrokerHooks {
    DWORD (*authenticate)(HANDLE, Handle&, DWORD&) = AuthenticateClient;
    bool (*activeConsole)(DWORD) = ActiveConsole;
    DWORD (*setEnabled)(bool, HANDLE) = SetDeviceEnabled;
    DWORD leaseTimeoutMs = LeaseTimeoutMs;
};

DWORD ServeClient(HANDLE pipe, const BrokerHooks& hooks = BrokerHooks{}) {
    Handle process;
    DWORD session = InvalidSession;
    bool authenticated = false, active = false;
    DWORD cleanupError = ERROR_SUCCESS;
    ResetEvent(g_sessionEnded.get());
    while (!Stopping()) {
        Request request{};
        const DWORD readError = Transfer(pipe, false, &request, sizeof(request), process.get(),
            authenticated ? hooks.leaseTimeoutMs : 3000);
        if (readError) break;
        Reply reply{};
        if (!IsValidRequest(request)) {
            reply.error = ERROR_INVALID_DATA;
            Transfer(pipe, true, &reply, sizeof(reply), process.get(), 2000);
            break;
        }
        if (!authenticated) {
            reply.error = hooks.authenticate(pipe, process, session);
            if (reply.error) {
                Transfer(pipe, true, &reply, sizeof(reply), nullptr, 2000);
                break;
            }
            authenticated = true;
            g_clientSession.store(session);
        }
        if (!hooks.activeConsole(session) || WaitForSingleObject(g_sessionEnded.get(), 0) == WAIT_OBJECT_0) break;
        if (request.command == Command::Activate && !active) {
            reply.error = hooks.setEnabled(true, process.get());
            active = reply.error == ERROR_SUCCESS;
            if (!active) {
                cleanupError = hooks.setEnabled(false, nullptr);
                if (cleanupError) LogFailure(L"Activation rollback", cleanupError);
            }
        } else if (request.command == Command::Deactivate) {
            reply.error = hooks.setEnabled(false, nullptr);
            if (!reply.error) active = false;
        }
        reply.state = active ? State::Active : State::Inactive;
        if (Transfer(pipe, true, &reply, sizeof(reply), process.get(), 2000)) break;
        if (reply.error || cleanupError) break;
    }
    // Always attempt cleanup, including malformed IPC, idle timeout, a client
    // process exit, session changes, a broken pipe and an SCM stop.
    const DWORD error = hooks.setEnabled(false, nullptr);
    g_clientSession.store(InvalidSession);
    if (error) LogFailure(L"Releasing virtual display", error);
    return error;
}

DWORD RunBroker() {
    DWORD error = LoadConfiguration();
    if (error) return error;
    // A crash may have left the owned node enabled. SCM recovery starts here
    // before accepting a new lease and persists the disabled state over reboot.
    error = SetDeviceEnabled(false);
    if (error) return error;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
        L"D:P(A;;GA;;;SY)(A;;GRGW;;;IU)", SDDL_REVISION_1, &descriptor, nullptr)) return GetLastError();
    SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    ReportStatus(SERVICE_RUNNING);
    while (!Stopping()) {
        ResetEvent(g_sessionEnded.get());
        Handle pipe(CreateNamedPipeW(PipeName,
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1, sizeof(Reply), sizeof(Request), 3000, &security));
        if (!pipe.valid()) { error = GetLastError(); break; }
        Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        if (!event.valid()) { error = GetLastError(); break; }
        OVERLAPPED overlapped{};
        overlapped.hEvent = event.get();
        BOOL connected = ConnectNamedPipe(pipe.get(), &overlapped);
        error = connected ? ERROR_SUCCESS : GetLastError();
        DWORD bytes = 0;
        if (error == ERROR_IO_PENDING) error = WaitIo(pipe.get(), overlapped, nullptr, INFINITE, bytes);
        if (error == ERROR_PIPE_CONNECTED) error = ERROR_SUCCESS;
        if (!error) error = ServeClient(pipe.get());
        DisconnectNamedPipe(pipe.get());
        if (error == ERROR_OPERATION_ABORTED && Stopping()) { error = ERROR_SUCCESS; break; }
        if (error) break;
    }
    LocalFree(descriptor);
    const DWORD cleanupError = SetDeviceEnabled(false);
    return cleanupError ? cleanupError : error;
}

DWORD WINAPI HandleControl(DWORD control, DWORD eventType, void* eventData, void*) {
    if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
        ReportStatus(SERVICE_STOP_PENDING, ERROR_SUCCESS, 20000);
        SetEvent(g_stop.get());
        return NO_ERROR;
    }
    if (control == SERVICE_CONTROL_SESSIONCHANGE && eventData) {
        const auto* notification = static_cast<WTSSESSION_NOTIFICATION*>(eventData);
        if (notification->dwSessionId == g_clientSession.load() &&
            (eventType == WTS_SESSION_LOGOFF || eventType == WTS_CONSOLE_DISCONNECT ||
             eventType == WTS_REMOTE_DISCONNECT || eventType == WTS_SESSION_LOCK)) SetEvent(g_sessionEnded.get());
        return NO_ERROR;
    }
    if (control == SERVICE_CONTROL_INTERROGATE) {
        std::lock_guard<std::mutex> lock(g_statusMutex);
        SetServiceStatus(g_statusHandle, &g_status);
        return NO_ERROR;
    }
    return ERROR_CALL_NOT_IMPLEMENTED;
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
    g_statusHandle = RegisterServiceCtrlHandlerExW(ServiceName, HandleControl, nullptr);
    if (!g_statusHandle) return;
    ReportStatus(SERVICE_START_PENDING, ERROR_SUCCESS, 20000);
    g_stop.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    g_sessionEnded.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    DWORD error = ERROR_SUCCESS;
    if (!g_stop.valid() || !g_sessionEnded.valid()) error = GetLastError();
    else {
        HANDLE token = nullptr;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) error = GetLastError();
        else {
            Handle account(token);
            std::vector<BYTE> user;
            BYTE system[SECURITY_MAX_SID_SIZE];
            DWORD size = sizeof(system);
            if (!ReadToken(account.get(), TokenUser, user) ||
                !CreateWellKnownSid(WinLocalSystemSid, nullptr, system, &size) ||
                !EqualSid(reinterpret_cast<TOKEN_USER*>(user.data())->User.Sid, system)) error = ERROR_ACCESS_DENIED;
        }
    }
    if (!error) {
        try { error = RunBroker(); }
        catch (...) { error = ERROR_UNHANDLED_EXCEPTION; SetDeviceEnabled(false); }
    }
    if (error) LogFailure(L"Display broker", error);
    ReportStatus(SERVICE_STOPPED, error);
}
} // namespace

#ifndef WINSIDEUSB_DISPLAY_SERVICE_TEST
int WINAPI wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
    SERVICE_TABLE_ENTRYW services[] = {{const_cast<wchar_t*>(WinSideUSBDisplay::ServiceName), ServiceMain}, {nullptr, nullptr}};
    return StartServiceCtrlDispatcherW(services) ? 0 : static_cast<int>(GetLastError());
}
#endif
