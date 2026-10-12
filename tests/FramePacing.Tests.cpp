#define NOMINMAX
#include "../WinSideUSB/FramePacing.h"
#include <cstdio>
#include <thread>

int main() {
    int failures = 0;
    auto check = [&](bool value, const char* name) {
        std::printf("%s %s\n", value ? "PASS" : "FAIL", name);
        if (!value) ++failures;
    };
    LARGE_INTEGER frequency{}, start{}, end{};
    QueryPerformanceFrequency(&frequency);
    winsideusb::FrameDeadlineWaiter waiter;
    std::atomic<bool> cancelled{false};
    QueryPerformanceCounter(&start);
    check(waiter.WaitUntil(start.QuadPart - 1, frequency.QuadPart, cancelled), "past deadline returns immediately");
    QueryPerformanceCounter(&end);
    check(end.QuadPart - start.QuadPart < frequency.QuadPart / 10, "past deadline does not block");
    check(!waiter.WaitUntil(start.QuadPart, 0, cancelled), "invalid timer frequency rejected");
    cancelled = true;
    check(!waiter.WaitUntil(start.QuadPart + frequency.QuadPart, frequency.QuadPart, cancelled), "cancelled deadline returns without waiting");
    cancelled = false;
    QueryPerformanceCounter(&start);
    const auto deadline = start.QuadPart + frequency.QuadPart / 120;
    check(waiter.WaitUntil(deadline, frequency.QuadPart, cancelled), "120 Hz deadline completes");
    QueryPerformanceCounter(&end);
    check(end.QuadPart >= deadline, "deadline never fires early");
    check(end.QuadPart - start.QuadPart < frequency.QuadPart / 5, "native deadline wait is bounded");
    QueryPerformanceCounter(&start);
    std::thread stop([&] { Sleep(5); cancelled = true; });
    const bool completed = waiter.WaitUntil(start.QuadPart + frequency.QuadPart, frequency.QuadPart, cancelled);
    stop.join();
    QueryPerformanceCounter(&end);
    check(!completed && end.QuadPart - start.QuadPart < frequency.QuadPart / 5, "long wait observes cancellation promptly");
    winsideusb::StageTiming timing;
    check(timing.AverageMs() == 0, "empty stage metrics are finite");
    timing.Add(2); timing.Add(6);
    check(timing.samples == 2 && timing.AverageMs() == 4 && timing.maxMs == 6, "stage metrics preserve mean and worst delay");
    timing.Reset();
    check(timing.samples == 0 && timing.totalMs == 0 && timing.maxMs == 0, "interval reset clears stage measurements");
    {
        winsideusb::ScopedStageTimer measurement(&timing, frequency.QuadPart);
        Sleep(2);
    }
    check(timing.samples == 1 && timing.maxMs > 0, "native scoped measurement records completed stage");
    std::printf("high_resolution_timer=%s failures=%d\n", waiter.HighResolution() ? "yes" : "fallback", failures);
    return failures ? 1 : 0;
}
