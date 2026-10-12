#pragma once

#include <Windows.h>
#include <avrt.h>
#include <algorithm>
#include <atomic>

#pragma comment(lib, "avrt.lib")

namespace winsideusb {

struct StageTiming {
    unsigned long long samples = 0;
    double totalMs = 0;
    double maxMs = 0;
    void Add(double milliseconds) {
        ++samples;
        totalMs += milliseconds;
        maxMs = (std::max)(maxMs, milliseconds);
    }
    double AverageMs() const { return samples ? totalMs / static_cast<double>(samples) : 0; }
    void Reset() { samples = 0; totalMs = 0; maxMs = 0; }
};

class ScopedStageTimer {
public:
    ScopedStageTimer(StageTiming* timing, LONGLONG frequency) : timing_(timing), frequency_(frequency) {
        if (timing_) QueryPerformanceCounter(&start_);
    }
    ~ScopedStageTimer() {
        if (!timing_ || frequency_ <= 0) return;
        LARGE_INTEGER end{};
        QueryPerformanceCounter(&end);
        timing_->Add(static_cast<double>(end.QuadPart - start_.QuadPart) * 1000 / frequency_);
    }
    ScopedStageTimer(const ScopedStageTimer&) = delete;
    ScopedStageTimer& operator=(const ScopedStageTimer&) = delete;
private:
    StageTiming* timing_;
    LONGLONG frequency_;
    LARGE_INTEGER start_{};
};

// Only the capture thread joins MMCSS; UI/service priorities remain unchanged.
class CaptureThreadScheduling {
public:
    CaptureThreadScheduling() {
        DWORD index = 0;
        task_ = AvSetMmThreadCharacteristicsW(L"Capture", &index);
    }
    ~CaptureThreadScheduling() { if (task_) AvRevertMmThreadCharacteristics(task_); }
    CaptureThreadScheduling(const CaptureThreadScheduling&) = delete;
    CaptureThreadScheduling& operator=(const CaptureThreadScheduling&) = delete;
    bool Active() const { return task_ != nullptr; }
private:
    HANDLE task_ = nullptr;
};

// An unnamed high-resolution timer keeps 8.33 ms deadlines usable even when
// the app is minimized. A short final spin avoids coarse Sleep rounding.
class FrameDeadlineWaiter {
public:
    FrameDeadlineWaiter() {
        timer_ = CreateWaitableTimerExW(nullptr, nullptr,
            CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_MODIFY_STATE | SYNCHRONIZE);
        highResolution_ = timer_ != nullptr;
        if (!timer_) timer_ = CreateWaitableTimerExW(nullptr, nullptr, 0,
            TIMER_MODIFY_STATE | SYNCHRONIZE);
    }
    ~FrameDeadlineWaiter() { if (timer_) CloseHandle(timer_); }
    FrameDeadlineWaiter(const FrameDeadlineWaiter&) = delete;
    FrameDeadlineWaiter& operator=(const FrameDeadlineWaiter&) = delete;
    bool HighResolution() const { return highResolution_; }

    bool WaitUntil(LONGLONG deadline, LONGLONG frequency, const std::atomic<bool>& cancelled) {
        if (frequency <= 0) return false;
        const LONGLONG spinCounts = (std::max)(1LL, frequency / 10000); // At most 100 us.
        while (!cancelled.load()) {
            LARGE_INTEGER now{};
            QueryPerformanceCounter(&now);
            const LONGLONG remaining = deadline - now.QuadPart;
            if (remaining <= 0) return true;
            if (remaining <= spinCounts) { YieldProcessor(); continue; }
            // Bound cancellation latency independently of the supplied deadline.
            const LONGLONG waitCounts = (std::min)(remaining - spinCounts, frequency / 100);
            if (timer_) {
                LARGE_INTEGER due{};
                due.QuadPart = -(std::max)(1LL, waitCounts * 10000000LL / frequency);
                if (SetWaitableTimer(timer_, &due, 0, nullptr, nullptr, FALSE) &&
                    WaitForSingleObject(timer_, 20) == WAIT_OBJECT_0) continue;
            }
            Sleep(1);
        }
        return false;
    }
private:
    HANDLE timer_ = nullptr;
    bool highResolution_ = false;
};

} // namespace winsideusb
