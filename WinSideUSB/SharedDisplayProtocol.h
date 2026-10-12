#pragma once

#include <cstdint>

// Local, message-mode IPC. Keep the installed client and SYSTEM broker on the
// same version; no user-supplied paths, device IDs, or display modes cross it.
namespace WinSideUSBDisplay {
inline constexpr wchar_t PipeName[] = L"\\\\.\\pipe\\WinSideUSBDisplay.v1";
inline constexpr wchar_t ServiceName[] = L"WinSideUSBDisplayService";
inline constexpr std::uint32_t Magic = 0x31445357; // WSD1, little endian.
inline constexpr std::uint32_t Version = 1;
inline constexpr std::uint32_t HeartbeatIntervalMs = 3000;
inline constexpr std::uint32_t LeaseTimeoutMs = 15000;

enum class Command : std::uint32_t { Activate = 1, Deactivate = 2, Ping = 3 };
enum class State : std::uint32_t { Inactive = 0, Active = 1 };

struct Request {
    std::uint32_t magic = Magic;
    std::uint32_t version = Version;
    Command command = Command::Ping;
    std::uint32_t reserved = 0;
};
struct Reply {
    std::uint32_t magic = Magic;
    std::uint32_t version = Version;
    std::uint32_t error = 0; // Win32 error; 3010 means a reboot is required.
    State state = State::Inactive;
};
static_assert(sizeof(Request) == 16 && sizeof(Reply) == 16, "IPC layout changed");

constexpr bool IsValidRequest(const Request& request) {
    return request.magic == Magic && request.version == Version &&
        request.reserved == 0 && (request.command == Command::Activate ||
        request.command == Command::Deactivate || request.command == Command::Ping);
}
} // namespace WinSideUSBDisplay
