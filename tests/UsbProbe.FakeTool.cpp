#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
int main(int argc, char** argv) {
    std::string key, udid;
    bool simple = false;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-k" && i + 1 < argc) key = argv[++i];
        else if (arg == "-u" && i + 1 < argc) udid = argv[++i];
        else if (arg == "-s") simple = true;
    }
    if (key == "hang") { Sleep(10000); return 0; }
    if (key == "arguments" && (udid != "1111-2222" || !simple)) return 4;
    std::string output = key == "oversize" ? std::string(5000, 'A') : "1111-2222 \r\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), output.data(), static_cast<DWORD>(output.size()), &written, nullptr)) return 5;
    if (key == "closeearly") {
        CloseHandle(GetStdHandle(STD_OUTPUT_HANDLE));
        Sleep(100);
    }
    return key == "nonzero" ? 7 : 0;
}
