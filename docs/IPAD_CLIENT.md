# iPad Client

The canonical iPad client is the single Swift file:

```text
WinSideUSB/swiftclientcode.swift
```

It can run in Swift Playgrounds or in the native iPadOS 17+ project under `iPadClient/`. Edit the canonical file and synchronize the native target from the repository root:

```powershell
.\scripts\Sync-iPadClient.ps1
```

This copies it to `iPadClient/Sources/WinSideUSBClient/App.swift`. The build script also performs this synchronization, and the transport test runner rejects differing copies.

## Device Coverage

The client is not hard-coded to one iPad screen size; it displays the incoming H.264 stream inside an `AVSampleBufferDisplayLayer` that fills the current view.

The Windows app chooses the virtual-display mode from a `ProductType` database. The current database includes known iPad, iPad Air, iPad mini, and iPad Pro identifiers through May 2026.

Unknown future iPads are allowed to start with conservative 60 Hz fallback modes. Add a real preset later if the native resolution or refresh rate differs from the fallback list.

## Runtime Flow

1. The iPad app opens a nonblocking BSD listener on loopback. It tries these ports in order:

   ```text
   17326, 17325, 17324, 17323, 17322, 17321
   ```

2. The Windows app starts `iproxy` and probes the same ports.
3. Windows sends `WSUSB_HELLO2`; the iPad responds with `WSUSB_READY2`.
4. Windows starts the virtual display and sends the existing H.264 stream.

The port order, versioned handshake, framing and video path remain compatible with the Windows app. The `WSUSB_USE_NW=1` development alternative still uses Network.framework on port 8080.

## Connection Recovery

The listener keeps accepting connections independently of the active video stream. A new PC connection can replace a stale connection, so an old tunnel waiting for data cannot block reconnecting.

EOF and socket errors close the active session, flush the renderer, clear parser/configuration/chunk state and return to waiting for a new connection. Listener failures retry after 1, 2, 4 and then at most 8 seconds between attempts. A successful listener start resets this backoff. TCP keepalive helps detect a lost tunnel; there is deliberately no video-idle timeout, so an unchanged desktop can remain connected without sending new frames.

The app stops its transports when its scene enters the background and prepares the listener again when it becomes active. Temporary inactive states leave the connection running. Keep the iPad app open for display use.

Manual recovery is available without relaunching the app:

- **Yenile** resets the receiver while waiting for a PC or for the first video frame.
- **Yeniden dene** does the same after a disconnect or listener error.
- A short button cooldown prevents repeated resets from rapid taps.

Windows must still be connected over USB and running WinSideUSB for video to resume. If **Stop display** was used on Windows, use **Start display** there to resume.

## Interface and Status

The connection panel shows **İkinci ekranınız hazır.** before connection, **Ekranınız hazırlanıyor.** while awaiting the first frame, and **Windows ekranı bağlı** during streaming. Disconnects and errors reveal the panel with recovery controls. These presentation states come directly from the receiver rather than parsing diagnostic text.

The panel stays visible while waiting, preparing, reconnecting, or reporting an error. During streaming it hides after five seconds, leaving the video unobstructed without a persistent corner button for touch users. Tap the video to show the controls again. Opening **Ayrıntılar** or using VoiceOver prevents automatic hiding. If a VoiceOver user manually closes the panel, an accessible controls button remains available. The layout adapts to the available space and follows light/dark appearance, Dynamic Type, reduced motion and reduced transparency settings.

Open **Ayrıntılar** to inspect messages such as:

```text
USB alıcısı hazır · HELLO2 / READY2
Port 17326 açık - PC bekleniyor...
Hazır - PC yayını bekleniyor...
Yayın alınıyor...
Streaming
```

The port may be any fallback port. If the iPad continues waiting, inspect these Windows logs:

```text
%LOCALAPPDATA%\WinSideUSB\winsideusb_diag.log
%LOCALAPPDATA%\WinSideUSB\iproxy.log
```

If Windows reports that it received `READY2`, the USB socket handshake succeeded. Check the subsequent Windows display/capture/encoder diagnostics and the iPad receiver details to locate the remaining failure.

Swift Playgrounds can leave an older run holding a port. If every fallback port is occupied, the new client reports a listener error and retries automatically. Close the older Playgrounds run to release its listeners; the current client can recover on a later retry or with **Yeniden dene**.

## Logs

The client creates a CSV log for each accepted connection in the app document directory. **Ayrıntılar** shows the frame count, receiver status, latest recovery detail and log filename. Use **Kaydı paylaş** to export a log when one is available, including after its connection has closed.

Build **1.1 (4)** adds **Gösterim FPS** to the diagnostics. On iPadOS 17.4+, it samples Apple's renderer counters about once per second and estimates the displayed rate as `delta(totalNumberOfFrames - numberOfDroppedFrames) / elapsedSeconds`. The existing **İşlenen kare** counter counts enqueues separately. This estimate is neither the panel refresh rate nor proof of evenly spaced physical presentation. Corrupted frames are reported separately, not subtracted a second time.

Polling continues when no packets arrive. The first valid sample establishes a baseline; two unchanged valid samples yield zero new displayed frames per second. A disconnect or renderer flush invalidates pending callbacks and resets the baseline. Missing, invalid or stale measurements show **—**, as does an unsupported iPadOS version. Queries have a three-second timeout; sample age is checked on the approximately one-second polling cadence. The CSV records the sample's own callback time and age because renderer callbacks and RX logging are asynchronous.

File creation, opening, writes and closing run on a separate serial utility queue. No periodic disk synchronization runs on the video queue. Pending log data is bounded to 64 KiB per session; excess log rows are skipped and counted without delaying video. Closing drains accepted rows asynchronously. Sharing an active log includes completed writes and can omit a pending row; final writes complete shortly after the session closes. Logging errors do not stop video.

The CSV includes:

- received bytes and packet counts
- maximum payload and receive-buffer sizes
- renderer status
- sync drops
- queue refreshes
- total enqueued and dropped frames

Additional renderer/log columns in build 4:

| Column | Meaning |
| --- | --- |
| `renderer_metrics_state` | `waiting`, `warming_up`, `available`, `unsupported`, `unavailable`, or `stale` |
| `renderer_sample_t` / `renderer_sample_age_ms` | Callback time in seconds from session start / age when the CSV row was written |
| `renderer_total` / `renderer_dropped` / `renderer_corrupted` | Apple's cumulative counters for the current renderer measurement period |
| `renderer_delay_total_ms` | Apple's accumulated presentation delay in milliseconds; not USB or capture-to-screen latency |
| `renderer_displayed_fps_estimate` | Renderer-derived FPS over two valid samples; empty when unavailable |
| `renderer_generation` | Invalidates samples across session, flush, and unavailable/stale-query boundaries |
| `log_skipped_rows` | Session total of log rows rejected because logging was full, closed, or failed |

Empty numeric fields mean unavailable, not zero. Counters can reset across flushes; use valid samples within one generation. The implementation uses per-sample dictionaries for `DisplayImmediately` and `NotSync`, as required by [Apple's sample-buffer attachment contract](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue(_:)). The renderer measurement API is [available from iPadOS 17.4](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/loadvideoperformancemetrics(completionhandler:)).

## Arrival and display rhythm (build 5)

Build **1.1 (5)** adds **Kare geliş aralığı** and **Ekran callback ritmi** to diagnostics. Both show the reporting window's p95 upper bound and maximum interval. Display rhythm also shows callback frequency. These complement the existing renderer FPS estimate; callback frequency is not a count of newly displayed video frames or a measurement of physical panel scanout.

Incoming video frames are timestamped with the socket read callback that completes the frame, before parsing that batch. Multiple frames completed in the same read batch therefore have zero inter-arrival gaps. Chunk assembly time runs from the first to last read callback for that frame. These values include receiver scheduling and transport batching; they are not USB wire latency or capture-to-screen latency. Long idle gaps and the existing static heartbeat are retained, so a long gap while nothing changes is expected.

A single `CADisplayLink` runs only while streaming, the video view is attached to a window, and the application is active. It keeps the system's default frame-rate preference. Each callback updates fixed numeric histograms; reports/UI/logs are produced about once per second. View replacement, disconnect, pause and stale reports cannot overwrite the current session's measurements. Low-power and thermal state are sampled with each display report. Adding a display link can itself affect scheduling; this instrumentation does not prove the uninstrumented app's physical refresh behavior.

Additional CSV fields:

| Field or prefix | Meaning |
| --- | --- |
| `frame_completed` / `frame_completed_hz` | Completed input frames / rate over the actual RX reporting window, including static heartbeats |
| `frame_last_id` / `frame_last_age_ms` | Latest DC2F frame ID (empty for legacy unchunked frames) / age of the last completed frame |
| `rx_timing_window_s` | Actual RX logging window duration |
| `frame_gap_*` | Completed-frame inter-arrival intervals |
| `frame_assembly_*` | First-to-last chunk read-callback duration |
| `display_rhythm_state` | `waiting`, `available`, `paused`, or `stale` |
| `display_sample_t` / `display_sample_age_ms` / `display_window_s` | Uptime-based report time relative to session start / age / display-timestamp window duration |
| `display_callback_hz` | Number of observed callback intervals divided by their elapsed display timestamps |
| `display_expected_hz` | Inverse mean of `targetTimestamp - timestamp`; Core Animation's reported callback refresh interval, not video FPS |
| `display_callback_gap_*` | Consecutive display-link timestamp intervals |
| `display_expected_interval_*` | `targetTimestamp - timestamp` intervals |
| `display_callback_offset_*` | Callback entry time minus display timestamp; includes the normal callback offset and is not a video deadline-miss count |
| `low_power_mode` / `thermal_state` | System power-mode flag / thermal raw value (0 nominal, 1 fair, 2 serious, 3 critical) |

Each statistics prefix contains `count`, `mean_ms`, `p50_upper_ms`, `p95_upper_ms`, `p99_upper_ms`, `max_ms`, `gt16_667`, `gt25`, and `gt50`. Quantiles are nearest-rank upper bounds from fixed 0.25 ms bins through 64 ms. The overflow bin uses that window's observed maximum, so an overflow quantile can be a loose bound. Long intervals are never clipped. Counts use strict greater-than thresholds of 16.667, 25 and 50 ms. Empty values mean unavailable. RX and display reports have separate windows and timestamps; compare aligned windows rather than assuming every value on one CSV row covers the same instant.

On 28 October 2026, nine focused helper checks passed, the signed arm64 Release package built at low CPU/I/O priority with one logical CPU affinity, and native Windows USB installation confirmed **1.1 build 5**. No motion benchmark or physical cadence test was run. The package is `iPadClient/artifacts/WinSideUSBClient-performance2.ipa`; package/install logs and validation metadata use the `performance2-` prefix.

## Build and Validate

For a short local check of the production logger and renderer-rate arithmetic:

```powershell
.\scripts\Sync-iPadClient.ps1
.\tests\Run-iPadPerformanceTests.ps1
```

This uses one Swift compiler job with low CPU/I/O priority. It does not access USB or start a display benchmark. CoreMedia attachment read-back runs only on an Apple runtime; the WSL runner explicitly skips that case.

On 27 October 2026, build **1.1 (4)** passed six focused helper checks (three logger lifecycle checks and three renderer-rate checks). The final source, including log sharing after a short disconnected session, passed an unsigned arm64 iPadOS Release cross-build on 28 October. The build ran at low CPU/I/O priority with CPU affinity limited to one logical processor. The Apple-runtime attachment check and on-device video/FPS validation were not run. The local build log is `iPadClient/artifacts/performance1-build.log`.

On 28 October, the same source was signed, packaged as `iPadClient/artifacts/WinSideUSBClient-performance1.ipa`, and installed using the existing native Windows Apple USB connection. Installed metadata confirmed **1.1 build 4**. No performance benchmark or streaming test was run during installation. The install log/result are `performance1-install.log` and `performance1-install-result.json` in the same artifacts directory.

The PowerShell helper uses the configured WSL Ubuntu installation and xtool. Its default release build is unsigned:

```powershell
.\scripts\Build-iPadClient.ps1
```

To sign with the existing local Apple configuration and produce an IPA:

```powershell
.\scripts\Build-iPadClient.ps1 -Sign -Ipa
```

The package is copied to the ignored local path `iPadClient/artifacts/WinSideUSBClient-recovery.ipa`. Building does not install the application on a device. See [`iPadClient/README.md`](../iPadClient/README.md) for local build options and the existing USB install command.

Run the transport checks from the repository root:

```powershell
.\scripts\Sync-iPadClient.ps1
.\tests\Run-iPadTransportTests.ps1
```

The runner extracts and compiles the production BSD listener, then exercises it with real local sockets. **7/7 transport tests passed**, and the native iOS release build passed. Physical iPad streaming, USB reconnects, background/foreground recovery and visual/accessibility checks still require device validation.

## Port Changes

If ports must be changed, update both canonical sources:

```text
WinSideUSB/WinSideUSB.cpp
WinSideUSB/swiftclientcode.swift
```

Then run `scripts/Sync-iPadClient.ps1` to update the native iPad target. Keep handshake strings versioned when changing transport behavior so old Playgrounds runs cannot be mistaken for the current app.
