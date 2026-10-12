# Windows frame pacing: 0.3.7

The working 0.3.6 source is preserved in commit `7b29272`. Windows performance work is on `codex/smooth-120fps`. The original setup, installed application/service and iPad IPA were also backed up locally before testing.

## Changes

- The capture thread uses MMCSS Capture scheduling and an unnamed high-resolution waitable timer for frame deadlines. The timer falls back if unavailable and observes cancellation during long waits.
- The native NVIDIA path submits the GPU copy and lets NVENC synchronize its input, replacing the separate GPU-query polling loop. Encoding remains synchronous on the capture thread.
- A captured DXGI frame stays owned until just before the next acquisition, including encoding and the pacing wait. Error and shutdown paths release ownership.
- A DXGI acquisition timeout no longer adds another full frame pacing delay, so capture can resume promptly when the desktop starts moving.
- CSV diagnostics include acquisition, copy submission, NVENC stages and late deadline measurements.

Selected pixel dimensions, refresh rates, encoder bitrate, keyframe interval, USB protocol and display-service lifetime are unchanged. The existing iPad application was used for the comparison; this Windows update does not install or require a new iPad application.

## Controlled comparison

Tested on 12 October 2026 using Windows 11 x64, an NVIDIA GeForce RTX 3080 Ti Laptop GPU and an iPad14,5 over USB. The virtual display was `2732x2048 @ 120 Hz`. The physical primary display remained `1920x1080 @ 360 Hz`.

Both runs used the same 18-second animated source paced at 120 FPS, shown only on the managed virtual display. The table summarizes 13 complete interior logging intervals, excluding startup and shutdown. The benchmark window checks the managed output identity, bounds and display mode; it exits if these change.

| Windows streaming measurement | 0.3.6 baseline | 0.3.7 candidate |
| --- | ---: | ---: |
| Measurement duration | 13.048 s | 13.065 s |
| Encoded and sent video rate | 120.095 FPS | 120.015 FPS |
| Maximum gap between captured desktop update timestamps | 16.595 ms | 11.190 ms |
| Capture timeouts during motion | 0 | 0 |
| Sender queue drops | 0 | 0 |

The candidate's maximum measured NVENC encode duration was 7.805 ms. Its mean bitstream lock wait was 6.051 ms; this is still a significant part of the 8.33 ms frame budget at 120 Hz.

This is one controlled comparison, not a guarantee of uninterrupted 120 FPS. The measurements cover Windows capture, encoding and sending. They do not measure how many video frames the iPad renderer actually displayed. Desktop contents, system load, USB transport and the iPad renderer can affect the visible result. A static desktop intentionally sends a low-rate heartbeat; low FPS while nothing changes is expected.

## Reproduce on Windows

Build and run the deadline/cancellation tests:

```powershell
.\tests\Run-FramePacingTests.ps1
```

All 12 checks passed, with the high-resolution timer available. The Release x64 application and display service also built successfully.

With the installed Windows app streaming to the existing iPad app at 120 Hz, run:

```powershell
.\tests\Run-DisplayMotionBenchmark.ps1 -Duration 18
```

The benchmark emits JSON source timing measurements. Compare these with the matching `%LOCALAPPDATA%\WinSideUSB\winsideusb_tx_*.csv` file, selecting full intervals inside the animation window. Compute video rate from packet counts divided by the actual interval duration. CSV files include an initial zero row, which should be excluded. Source animation FPS and captured desktop timestamps are separate from iPad presentation FPS.

The benchmark does not enable a display device or change a display mode. It requires the app's existing managed display lease and refuses a physical display fallback.
