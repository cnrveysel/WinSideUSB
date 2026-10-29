import SwiftUI
import Foundation
import Dispatch
import Network
import AVFoundation
import VideoToolbox
import Darwin
import UIKit
import QuartzCore

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}

// MARK: - Async video logging

/// One logging session. Text is written verbatim; callers include CSV newlines.
/// `append` only reserves memory and submits work. All file operations run on a
/// private serial utility queue, including initial creation and final close.
final class AsyncVideoLog {
    private final class Admission {
        let lock = NSLock()
        let limit: Int
        var pendingBytes = 0
        var accepting = true

        init(limit: Int) { self.limit = limit }

        func finished(_ count: Int) {
            lock.lock()
            pendingBytes -= count
            lock.unlock()
        }

        func stopAccepting() {
            lock.lock()
            accepting = false
            lock.unlock()
        }
    }

    /// Mutable fields in this object belong exclusively to the I/O queue.
    private final class IOState {
        let url: URL
        let callbackQueue: DispatchQueue
        let onOpened: (URL) -> Void
        let onFailure: (String) -> Void
        let admission: Admission
        var handle: FileHandle?
        var failed = false

        init(url: URL, callbackQueue: DispatchQueue, admission: Admission,
             onOpened: @escaping (URL) -> Void,
             onFailure: @escaping (String) -> Void) {
            self.url = url
            self.callbackQueue = callbackQueue
            self.admission = admission
            self.onOpened = onOpened
            self.onFailure = onFailure
        }

        func open(header: Data) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                fail("Could not create video log.")
                return
            }
            do {
                handle = try FileHandle(forWritingTo: url)
                try handle?.write(contentsOf: header)
                let opened = onOpened
                let openedURL = url
                callbackQueue.async { opened(openedURL) }
            } catch {
                fail("Could not open video log: \(error.localizedDescription)")
            }
        }

        func write(_ data: Data) {
            guard !failed, let handle = handle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                fail("Could not write video log: \(error.localizedDescription)")
            }
        }

        func close() {
            guard let handle = handle else { return }
            self.handle = nil
            do {
                try handle.close()
            } catch {
                fail("Could not close video log: \(error.localizedDescription)")
            }
        }

        func fail(_ message: String) {
            guard !failed else { return }
            failed = true
            admission.stopAccepting()
            let oldHandle = handle
            handle = nil
            try? oldHandle?.close()
            let report = onFailure
            callbackQueue.async { report(message) }
        }
    }

    private let admission: Admission
    private let io: IOState
    private let ioQueue: DispatchQueue

    /// Use a fresh URL for every session. `ioTargetQueue` is only needed to
    /// control scheduling in tests; file operations still use a private queue.
    init(url: URL, header: String, callbackQueue: DispatchQueue = .main,
         pendingByteLimit: Int = 64 * 1024,
         ioTargetQueue: DispatchQueue? = nil,
         onOpened: @escaping (URL) -> Void,
         onFailure: @escaping (String) -> Void) {
        precondition(pendingByteLimit > 0)
        let gate = Admission(limit: pendingByteLimit)
        admission = gate
        io = IOState(url: url, callbackQueue: callbackQueue, admission: gate,
                     onOpened: onOpened, onFailure: onFailure)
        ioQueue = DispatchQueue(label: "WinSideUSB.video-log.\(UUID().uuidString)",
                                qos: .utility, target: ioTargetQueue)
        let headerData = Data(header.utf8)
        if headerData.count > pendingByteLimit {
            gate.accepting = false
            ioQueue.async { [io] in io.fail("Video log header exceeds pending byte limit.") }
        } else {
            gate.pendingBytes = headerData.count
            ioQueue.async { [io, gate] in
                defer { gate.finished(headerData.count) }
                io.open(header: headerData)
            }
        }
    }

    /// False means closed, failed, or full. Callers can count rejected lines.
    /// Pending bytes include the write currently in progress and the header.
    @discardableResult
    func append(_ line: String) -> Bool {
        let data = Data(line.utf8)
        admission.lock.lock()
        guard admission.accepting,
              data.count <= admission.limit - admission.pendingBytes else {
            admission.lock.unlock()
            return false
        }
        if data.isEmpty {
            admission.lock.unlock()
            return true
        }
        admission.pendingBytes += data.count
        // Submission shares the admission lock with close, preserving order
        // even when append and close are called from different threads.
        ioQueue.async { [io, admission] in
            defer { admission.finished(data.count) }
            io.write(data)
        }
        admission.lock.unlock()
        return true
    }

    /// Stops admission immediately; queued writes finish before the handle
    /// closes. Optional completion runs on callbackQueue after close finishes.
    /// No fsync is performed. Repeated close calls are safe.
    func close(completion: (() -> Void)? = nil) {
        admission.lock.lock()
        admission.accepting = false
        ioQueue.async { [io] in
            io.close()
            if let completion = completion {
                io.callbackQueue.async { completion() }
            }
        }
        admission.lock.unlock()
    }

    // Work blocks retain their own state rather than this logger, so releasing
    // the last logger reference schedules close after every accepted append.
    deinit { close() }
}

// MARK: - Renderer FPS counter

// These are renderer counters, not enqueue counts or physical panel refreshes.
// All access is serialized on the receiver queue; missing/reset samples rebase.
struct RendererFPSCounter {
    private var previous: (total: Int, dropped: Int, time: TimeInterval)?

    mutating func reset() { previous = nil }

    mutating func observe(total: Int, dropped: Int, at time: TimeInterval) -> Double? {
        guard total >= 0, dropped >= 0, dropped <= total, time.isFinite else {
            reset()
            return nil
        }
        let current = (total: total, dropped: dropped, time: time)
        defer { previous = current }
        guard let old = previous, time > old.time, time - old.time <= 3,
              total >= old.total, dropped >= old.dropped else { return nil }
        let frameDelta = total - old.total
        let dropDelta = dropped - old.dropped
        guard dropDelta <= frameDelta else { return nil }
        return Double(frameDelta - dropDelta) / (time - old.time)
    }
}

// MARK: - Interval timing statistics

/// Bounded-memory interval statistics. Record every real interval, including
/// long idle gaps; reset at the caller's reporting boundary, usually once a second.
/// The caller serializes access. No clock, timer, I/O, or retained samples exist.
struct IntervalStats {
    static let binWidthMs = 0.25
    static let histogramLimitMs = 64.0
    static let longIntervalThresholdMs = 16.667
    private static let regularBinCount = 256

    struct Summary: Equatable {
        let count: Int
        let meanMs: Double?
        let maxMs: Double?
        // Nearest-rank quantile upper bounds, not exact per-frame quantiles.
        // Regular bins are 0.25 ms wide. A quantile in the overflow bin uses
        // the observed maximum, which can be far above that quantile.
        let p50UpperBoundMs: Double?
        let p95UpperBoundMs: Double?
        let p99UpperBoundMs: Double?
        let over16_667Ms: Int
        let over25Ms: Int
        let over50Ms: Int
    }

    private var binCounts = [Int](repeating: 0, count: IntervalStats.regularBinCount + 1)
    private var count = 0
    private var meanMs = 0.0
    private var maxMs = 0.0
    private var over16_667Ms = 0
    private var over25Ms = 0
    private var over50Ms = 0

    /// O(1) admission and update. False leaves all counters unchanged.
    /// Threshold counts are strict >16.667, >25, and >50 milliseconds.
    @discardableResult
    mutating func record(_ milliseconds: Double) -> Bool {
        guard milliseconds.isFinite, milliseconds >= 0 else { return false }
        let index: Int
        if milliseconds > Self.histogramLimitMs {
            index = Self.regularBinCount
        } else {
            // Bin 0 includes [0, 0.25]; following bins include (lower, upper].
            index = max(0, Int((milliseconds / Self.binWidthMs).rounded(.up)) - 1)
        }
        binCounts[index] += 1
        count += 1
        // Online mean avoids overflowing a sum of long but finite intervals.
        meanMs += (milliseconds - meanMs) / Double(count)
        maxMs = max(maxMs, milliseconds)
        if milliseconds > Self.longIntervalThresholdMs { over16_667Ms += 1 }
        if milliseconds > 25 { over25Ms += 1 }
        if milliseconds > 50 { over50Ms += 1 }
        return true
    }

    /// O(number of fixed bins), independent of the number of recorded samples.
    func snapshot() -> Summary {
        Summary(count: count,
                meanMs: count == 0 ? nil : meanMs,
                maxMs: count == 0 ? nil : maxMs,
                p50UpperBoundMs: quantileUpperBound(0.50),
                p95UpperBoundMs: quantileUpperBound(0.95),
                p99UpperBoundMs: quantileUpperBound(0.99),
                over16_667Ms: over16_667Ms,
                over25Ms: over25Ms,
                over50Ms: over50Ms)
    }

    mutating func reset() {
        for index in binCounts.indices { binCounts[index] = 0 }
        count = 0
        meanMs = 0
        maxMs = 0
        over16_667Ms = 0
        over25Ms = 0
        over50Ms = 0
    }

    private func quantileUpperBound(_ fraction: Double) -> Double? {
        guard count > 0 else { return nil }
        let rank = max(1, Int((Double(count) * fraction).rounded(.up)))
        var cumulative = 0
        for index in binCounts.indices {
            cumulative += binCounts[index]
            if cumulative >= rank {
                if index == Self.regularBinCount { return maxMs }
                // The observed maximum is also a valid upper bound. This
                // preserves an exact zero for an all-zero interval window.
                return min(Double(index + 1) * Self.binWidthMs, maxMs)
            }
        }
        return maxMs
    }
}

func timingColumnNames(_ prefix: String) -> [String] {
    let suffixes = ["count", "mean_ms", "p50_upper_ms", "p95_upper_ms", "p99_upper_ms",
                    "max_ms", "gt16_667", "gt25", "gt50"]
    return suffixes.map { prefix + "_" + $0 }
}

extension IntervalStats.Summary {
    var csvFields: [String] {
        var fields = [String(count)]
        let values: [Double?] = [meanMs, p50UpperBoundMs, p95UpperBoundMs, p99UpperBoundMs, maxMs]
        for value in values {
            fields.append(value.map { String(format: "%.3f", $0) } ?? "")
        }
        fields.append(String(over16_667Ms))
        fields.append(String(over25Ms))
        fields.append(String(over50Ms))
        return fields
    }
}

// MARK: - Video sample attachments

@discardableResult
func setVideoSampleAttachments(_ sample: CMSampleBuffer, isIDR: Bool) -> Bool {
    // kCMSampleAttachmentKey_* keys belong to the per-sample dictionary.
    guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
          CFArrayGetCount(array) > 0 else { return false }
    let attachments = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(attachments,
                         Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    CFDictionarySetValue(attachments,
                         Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                         Unmanaged.passUnretained(isIDR ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
    return true
}

// MARK: - Recoverable BSD listener

// All methods and callbacks run on the receiver queue. Read sources keep an idle
// USB tunnel from blocking accept, foreground recovery, or the retry button.
final class BSDVideoListener {
    var onListening: ((UInt16) -> Void)?
    var onConnected: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let queue: DispatchQueue
    private let ports: [UInt16]
    private var listenerSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var clientFD: Int32 = -1
    private var listenerClosing = false
    private var restartAfterClose = false
    private var listenerGeneration = 0
    private var clientGeneration = 0
    private var readyOffset = 0
    private let ready = Array("WSUSB_READY2\n".utf8)
    private var buffer = [UInt8](repeating: 0, count: 512 * 1024)

    init(queue: DispatchQueue, ports: [UInt16] = [17326, 17325, 17324, 17323, 17322, 17321]) {
        self.queue = queue
        self.ports = ports
    }

    deinit {
        clientSource?.cancel()
        listenerSource?.cancel()
    }

    func start() {
        guard listenerSource == nil else { return }
        // Cancellation closes the old descriptor asynchronously on this queue.
        // Defer a same-port restart until that close has actually completed.
        guard !listenerClosing else { restartAfterClose = true; return }
        var lastError: Int32 = 0
        for port in ports {
#if os(Linux)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
#endif
            guard fd >= 0 else { lastError = errno; continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
#if !os(Linux)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0, listen(fd, 4) == 0, makeNonblocking(fd) else {
                lastError = errno
                close(fd)
                continue
            }
            listenerGeneration += 1
            let generation = listenerGeneration
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self = self, self.listenerGeneration == generation else { return }
                self.acceptClients(fd)
            }
            // The source owns this descriptor, including while cancellation is pending.
            source.setCancelHandler { [weak self] in
                close(fd)
                guard let self = self else { return }
                self.listenerClosing = false
                if self.restartAfterClose {
                    self.restartAfterClose = false
                    self.start()
                }
            }
            listenerSource = source
            source.resume()
            onListening?(port)
            return
        }
        onFailure?("USB dinleyicisi açılamadı (\(lastError)). Otomatik yeniden deneniyor.")
    }

    func stop() {
        closeClient()
        restartAfterClose = false
        listenerGeneration += 1
        if listenerSource != nil { listenerClosing = true }
        listenerSource?.cancel()
        listenerSource = nil
    }

    func retry() {
        // Keep a healthy listener bound so Windows can reconnect immediately.
        closeClient()
        start()
    }

    private func makeNonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private func acceptClients(_ fd: Int32) {
        // Bound each pass so connection churn cannot starve lifecycle operations.
        for _ in 0..<8 {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                let reason = "USB dinleyici hatası (\(errno)). Yeniden hazırlanıyor."
                stop()
                onFailure?(reason)
                return
            }
            guard makeNonblocking(client) else { close(client); continue }
            var yes: Int32 = 1
            setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &yes, socklen_t(MemoryLayout<Int32>.size))
#if !os(Linux)
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var idle: Int32 = 5
            var interval: Int32 = 2
            var probes: Int32 = 3
            setsockopt(client, Int32(IPPROTO_TCP), TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, Int32(IPPROTO_TCP), TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, Int32(IPPROTO_TCP), TCP_KEEPCNT, &probes, socklen_t(MemoryLayout<Int32>.size))
#endif
            if clientFD >= 0 {
                closeClient()
                onDisconnected?("Yeni USB bağlantısı alındı; önceki oturum temizlendi.")
            }
            clientFD = client
            clientGeneration += 1
            let generation = clientGeneration
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self = self, self.clientGeneration == generation else { return }
                self.readAvailable(client, generation: generation)
            }
            source.setCancelHandler { close(client) }
            clientSource = source
            source.resume()
            readyOffset = 0
            onConnected?()
            sendReady(client, generation: generation)
        }
    }

    private func sendReady(_ fd: Int32, generation: Int, attempt: Int = 0) {
        guard clientGeneration == generation, clientFD == fd else { return }
        while readyOffset < ready.count {
#if os(Linux)
            let flags = Int32(MSG_NOSIGNAL)
#else
            let flags: Int32 = 0
#endif
            let sent = ready.withUnsafeBytes {
                send(fd, $0.baseAddress!.advanced(by: readyOffset), ready.count - readyOffset, flags)
            }
            if sent > 0 { readyOffset += sent; continue }
            if sent < 0 && errno == EINTR { continue }
            if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                guard attempt < 100 else {
                    disconnect("Hazırlık sinyali zamanında gönderilemedi.")
                    return
                }
                // A short handshake needs no second dispatch source sharing
                // descriptor ownership with the read source during teardown.
                queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.sendReady(fd, generation: generation, attempt: attempt + 1)
                }
                return
            }
            disconnect("Hazırlık sinyali gönderilemedi (\(errno)).")
            return
        }
    }

    private func readAvailable(_ fd: Int32, generation: Int) {
        // A static desktop can be silent indefinitely. Only EOF/socket failure
        // or an explicit replacement ends it; there is no video-idle timeout.
        for _ in 0..<8 {
            guard clientGeneration == generation, clientFD == fd else { return }
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                onData?(Data(buffer.prefix(count)))
                continue
            }
            if count == 0 { disconnect("Bilgisayar bağlantıyı kapattı."); return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            disconnect("USB bağlantısı kesildi (\(errno)).")
            return
        }
    }

    private func disconnect(_ reason: String) {
        closeClient()
        onDisconnected?(reason)
    }

    private func closeClient() {
        clientGeneration += 1
        if clientFD >= 0 { _ = shutdown(clientFD, Int32(SHUT_RDWR)) }
        clientSource?.cancel()
        clientSource = nil
        clientFD = -1
    }
}


// MARK: - VideoReceiver (TCP SERVER - USB 120Hz)

final class VideoReceiver: NSObject, ObservableObject {
    @Published private(set) var phase: ClientConnectionState = .waiting
    @Published private(set) var recoveryDetail = ""
    @Published var status = "PC Bekleniyor..."
    @Published var debug  = "CFG: - | SPS: - | PPS: -"
    @Published var frames = 0
    @Published var layerInfo = ""
    @Published var logFile = "Log: -"
    @Published var logURL: URL?
    @Published private(set) var displayedFPS = "—"
    @Published private(set) var displayedFPSDetail = "Yayın başlayınca ölçülür."
    @Published private(set) var timingSession: UUID?
    @Published private(set) var frameArrivalTiming = "—"
    @Published private(set) var screenRhythm = "—"
    
    private var listener: NWListener?
    private var connection: NWConnection?
    private let parseQueue = DispatchQueue(label: "com.winsideusb.parse", qos: .userInteractive)
    private var rx = Data()
    private var isRunning = false
    private var listenerRetry: DispatchWorkItem?
    private var listenerRetryAttempt = 0

    private var formatDesc: CMVideoFormatDescription?
    private var gotConfig = false
    private var nalHeaderLength = 4
    private var chunkFrameId: UInt32?
    private var chunkExpectedTotal = 0
    private var chunkBuffer = Data()
    private var chunkStartedAt: TimeInterval?
    private var receiveBatchTime: TimeInterval = 0
    private var previousFrameArrival: TimeInterval?
    private var lastArrivedFrameID: UInt32?
    private var completedFramesLog = 0
    private var frameGapStats = IntervalStats()
    private var assemblyStats = IntervalStats()
    private var displayRhythmReport: DisplayRhythmMonitor.Report?
    private var displayRhythmState = "waiting"
    private var displayMonitorID: UUID?
    
    private var frameIndex: Int64 = 0
    private let fps: Int32 = 120
    private var enqueueCount = 0
    private var droppedFrames = 0
    private var notReadyStreak = 0
    private var queueRefreshes = 0
    private var waitingForSync = false
    private var firstReceiveLogged = false
    private var firstConfigFailLogged = false
    private let pcHello = Data("WSUSB_HELLO2\n".utf8)
    private var pcHelloBuffer = Data()
    private var sawPcHello = false

    private var csvLog: AsyncVideoLog?
    private var activeSession: UUID?
    // Retain the latest log identity after disconnect so delayed I/O callbacks
    // can still publish the finished file; a newer session replaces this token.
    private var latestLogSession: UUID?
    private var telemetryTimer: DispatchSourceTimer?
    private var logSkippedRows = 0
    private var metricsGeneration: UInt64 = 0
    private var metricsRequest: UInt64 = 0
    private var metricsRequestStart: TimeInterval?
    private var rendererFPSCounter = RendererFPSCounter()
    private var rendererFPS: Double?
    private var rendererMetricsState = "waiting"
    private var rendererSample: (time: TimeInterval, total: Int, dropped: Int,
                                 corrupted: Int, delay: TimeInterval)?
    private var logStart = ProcessInfo.processInfo.systemUptime
    private var lastLog = ProcessInfo.processInfo.systemUptime
    private var rxBytesLog = 0
    private var packetCountLog = 0
    private var payloadBytesLog = 0
    private var maxPayloadBytesLog = 0
    private var rxBufferMaxLog = 0
    private var enqueuedLog = 0
    private var idrLog = 0
    private var notReadyLog = 0
    private var syncDropLog = 0
    private var rendererFailedLog = 0
    private var refreshLog = 0
    private var invalidPacketLog = 0
    
    weak var displayLayer: AVSampleBufferDisplayLayer?

    deinit {
        listenerRetry?.cancel()
        listener?.cancel()
        connection?.cancel()
        telemetryTimer?.cancel()
        csvLog?.close()
    }

    func start() { resume() }

    func resume() {
        parseQueue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true
            self.listenerRetryAttempt = 0
            self.startTransport()
        }
    }

    func suspend() {
        parseQueue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            self.listenerRetry?.cancel()
            self.listenerRetry = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.closeNetworkConnection()
            self.socketTransport.stop()
            self.finishSession()
            self.publishStatus("Uygulama arka planda; dönüşte bağlantı hazırlanacak.", phase: .waiting)
        }
    }

    func retryConnection() {
        parseQueue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = true
            self.listenerRetry?.cancel()
            self.listenerRetry = nil
            self.listenerRetryAttempt = 0
            self.closeNetworkConnection()
            self.finishSession()
            self.publishStatus("Yeniden bağlanmaya hazır; PC bekleniyor...", phase: .reconnecting,
                               detail: "USB alıcısı yeniden hazırlandı.")
            if ProcessInfo.processInfo.environment["WSUSB_USE_NW"] == "1" {
                self.listener?.stateUpdateHandler = nil
                self.listener?.cancel()
                self.listener = nil
                self.startNetworkListener()
            } else {
                self.socketTransport.retry()
            }
        }
    }

    private func publishStatus(_ message: String, phase: ClientConnectionState,
                               debug: String? = nil, detail: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.status = message
            self.phase = phase
            if let debug = debug { self.debug = debug }
            if let detail = detail { self.recoveryDetail = detail }
        }
    }

    private func startTransport() {
        guard isRunning else { return }
        if ProcessInfo.processInfo.environment["WSUSB_USE_NW"] == "1" {
            startNetworkListener()
        } else {
            socketTransport.start()
        }
    }

    private lazy var socketTransport: BSDVideoListener = {
        let transport = BSDVideoListener(queue: parseQueue)
        transport.onListening = { [weak self] port in
            guard let self = self else { return }
            self.listenerRetryAttempt = 0
            self.publishStatus("Port \(port) açık - PC bekleniyor...", phase: .waiting,
                               debug: "USB alıcısı hazır · HELLO2 / READY2")
        }
        transport.onConnected = { [weak self] in
            guard let self = self else { return }
            self.resetForNewConnection()
            self.publishStatus("Hazır - PC yayını bekleniyor...", phase: .preparing,
                               debug: "USB bağlantısı kabul edildi", detail: "")
        }
        transport.onData = { [weak self] data in
            self?.handleIncomingData(data)
        }
        transport.onDisconnected = { [weak self] reason in
            guard let self = self else { return }
            self.finishSession()
            self.publishStatus("Bağlantı koptu; yeniden bağlanmaya hazır.", phase: .reconnecting,
                               debug: "USB alıcısı yeni bağlantıyı bekliyor", detail: reason)
        }
        transport.onFailure = { [weak self] reason in self?.scheduleListenerRetry(reason) }
        return transport
    }()

    private func scheduleListenerRetry(_ reason: String) {
        guard isRunning else { return }
        finishSession()
        listenerRetry?.cancel()
        let delay = min(pow(2.0, Double(min(listenerRetryAttempt, 3))), 8.0)
        listenerRetryAttempt += 1
        publishStatus(reason, phase: .error, detail: "\(Int(delay)) saniye içinde otomatik yeniden denenecek.")
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.startTransport()
        }
        listenerRetry = work
        parseQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeNetworkConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func startNetworkListener() {
        guard listener == nil, isRunning else { return }
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.enableKeepalive = true
        do {
            let newListener = try NWListener(using: NWParameters(tls: nil, tcp: options), on: 8080)
            listener = newListener
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self = self, let current = newListener,
                      self.listener === current, self.isRunning else { return }
                switch state {
                case .ready:
                    self.listenerRetryAttempt = 0
                    self.publishStatus("Port 8080 - PC bekleniyor...", phase: .waiting)
                case .failed(let error):
                    current.cancel()
                    self.listener = nil
                    self.closeNetworkConnection()
                    self.scheduleListenerRetry("Dinleyici hatası: \(error)")
                default: break
                }
            }
            newListener.newConnectionHandler = { [weak self, weak newListener] conn in
                guard let self = self, let current = newListener,
                      self.listener === current, self.isRunning else { conn.cancel(); return }
                self.closeNetworkConnection()
                self.connection = conn
                self.resetForNewConnection()
                self.publishStatus("PC bağlandı; yayın bekleniyor...", phase: .preparing, detail: "")
                var receiveStarted = false
                conn.stateUpdateHandler = { [weak self, weak conn] state in
                    guard let self = self, let conn = conn, self.connection === conn else { return }
                    switch state {
                    case .ready:
                        guard !receiveStarted else { return }
                        receiveStarted = true
                        self.receive(on: conn)
                        self.sendReadyHandshake(on: conn)
                    case .failed(let error): self.networkDisconnected(conn, reason: "Bağlantı hatası: \(error)")
                    case .cancelled: self.networkDisconnected(conn, reason: "Bilgisayar bağlantıyı kapattı.")
                    default: break
                    }
                }
                conn.start(queue: self.parseQueue)
            }
            newListener.start(queue: parseQueue)
        } catch {
            scheduleListenerRetry("Dinleyici başlatılamadı: \(error)")
        }
    }

    private func networkDisconnected(_ conn: NWConnection, reason: String) {
        guard connection === conn else { return }
        closeNetworkConnection()
        finishSession()
        publishStatus("Bağlantı koptu; yeniden bağlanmaya hazır.", phase: .reconnecting, detail: reason)
    }

    private func clearStreamState() {
        rx = Data(capacity: 2 * 1024 * 1024)
        gotConfig = false
        formatDesc = nil
        nalHeaderLength = 4
        resetChunkFrame()
        previousFrameArrival = nil
        lastArrivedFrameID = nil
        completedFramesLog = 0
        frameGapStats.reset()
        assemblyStats.reset()
        displayRhythmReport = nil
        displayRhythmState = "waiting"
        frameIndex = 0
        enqueueCount = 0
        droppedFrames = 0
        notReadyStreak = 0
        queueRefreshes = 0
        waitingForSync = false
        firstReceiveLogged = false
        firstConfigFailLogged = false
        pcHelloBuffer.removeAll(keepingCapacity: true)
        sawPcHello = false
        flushRenderer()
        DispatchQueue.main.async { [weak self] in
            self?.frames = 0
            self?.timingSession = nil
            self?.frameArrivalTiming = "—"
            self?.screenRhythm = "—"
        }
    }

    private func finishSession() {
        telemetryTimer?.cancel()
        telemetryTimer = nil
        logStatsIfNeeded(force: true)
        activeSession = nil
        csvLog?.close()
        csvLog = nil
        clearStreamState()
    }

    private func recoverFromStreamError(_ reason: String) {
        closeNetworkConnection()
        finishSession()
        if ProcessInfo.processInfo.environment["WSUSB_USE_NW"] != "1" {
            socketTransport.retry()
        }
        publishStatus("Yayın okunamadı; yeni bağlantı bekleniyor.", phase: .reconnecting, detail: reason)
    }

    private func resetForNewConnection() {
        finishSession()
        openLog()
    }


    private func handleIncomingData(_ d: Data) {
        // Stamp the read callback before parsing. Frames completed in the same
        // socket batch share this time, revealing coalesced arrivals as zero gaps.
        receiveBatchTime = ProcessInfo.processInfo.systemUptime
        if !firstReceiveLogged {
            firstReceiveLogged = true
            let preview = d.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
            DispatchQueue.main.async {
                self.status = "PC verisi geldi"
                self.debug = "RX \(d.count)b | \(preview)"
            }
        }
        rxBytesLog += d.count
        let streamData = stripPCHandshake(d)
        guard !streamData.isEmpty else { return }
        rx.append(streamData)
        if rx.count > rxBufferMaxLog { rxBufferMaxLog = rx.count }
        parsePackets()
    }

    private func sendReadyHandshake(on conn: NWConnection, attempt: Int = 0) {
        guard connection === conn, isRunning else { return }
        guard displayLayer != nil else {
            guard attempt < 40 else {
                networkDisconnected(conn, reason: "Video katmanı hazırlanamadı.")
                return
            }
            parseQueue.asyncAfter(deadline: .now() + 0.05) { [weak self, weak conn] in
                guard let conn = conn else { return }
                self?.sendReadyHandshake(on: conn, attempt: attempt + 1)
            }
            return
        }
        conn.send(content: Data("WSUSB_READY2\n".utf8), completion: .contentProcessed { [weak self, weak conn] error in
            guard let self = self, let conn = conn, self.connection === conn else { return }
            if let error = error {
                self.networkDisconnected(conn, reason: "Hazırlık sinyali gönderilemedi: \(error)")
            }
        })
    }

    private func stripPCHandshake(_ incoming: Data) -> Data {
        guard !sawPcHello else { return incoming }

        pcHelloBuffer.append(incoming)

        if pcHelloBuffer.count < pcHello.count {
            if pcHello.starts(with: pcHelloBuffer) {
                return Data()
            }

            sawPcHello = true
            let buffered = pcHelloBuffer
            pcHelloBuffer.removeAll(keepingCapacity: true)
            return buffered
        }

        if pcHelloBuffer.starts(with: pcHello) {
            sawPcHello = true
            let rest = Data(pcHelloBuffer.dropFirst(pcHello.count))
            pcHelloBuffer.removeAll(keepingCapacity: true)
            DispatchQueue.main.async {
                self.debug = "USB HELLO OK"
            }
            return rest
        }

        sawPcHello = true
        let buffered = pcHelloBuffer
        pcHelloBuffer.removeAll(keepingCapacity: true)
        return buffered
    }

    private func openLog() {
        let session = UUID()
        activeSession = session
        latestLogSession = session
        logStart = ProcessInfo.processInfo.systemUptime
        lastLog = logStart
        logSkippedRows = 0
        resetLogCounters()
        resetRendererMetrics(state: "waiting")
        startTelemetry()
        DispatchQueue.main.async { [weak self] in
            self?.timingSession = session
            self?.logURL = nil
            self?.logFile = "Log: hazırlanıyor…"
        }

        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            DispatchQueue.main.async { [weak self] in self?.logFile = "Log: oluşturulamadı" }
            return
        }
        let name = "winsideusb_rx_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).csv"
        let url = dir.appendingPathComponent(name)
        let baseHeader = "t,rx_bytes,packets,payload_bytes,max_payload,rx_buffer_max,enqueued,idr,not_ready,sync_drops,renderer_failed,queue_refresh,invalid_packets,total_enqueued,total_drops,total_refresh,waiting_for_sync,renderer_status,renderer_metrics_state,renderer_sample_t,renderer_sample_age_ms,renderer_total,renderer_dropped,renderer_corrupted,renderer_delay_total_ms,renderer_displayed_fps_estimate,renderer_generation,log_skipped_rows"
        var timingHeaders = ["frame_completed", "frame_completed_hz", "frame_last_id",
                             "frame_last_age_ms", "rx_timing_window_s"]
        timingHeaders += timingColumnNames("frame_gap")
        timingHeaders += timingColumnNames("frame_assembly")
        timingHeaders += ["display_rhythm_state", "display_sample_t", "display_sample_age_ms",
                          "display_window_s", "display_callback_hz", "display_expected_hz",
                          "low_power_mode", "thermal_state"]
        timingHeaders += timingColumnNames("display_callback_gap")
        timingHeaders += timingColumnNames("display_expected_interval")
        timingHeaders += timingColumnNames("display_callback_offset")
        let header = baseHeader + "," + timingHeaders.joined(separator: ",") + "\n"
        csvLog = AsyncVideoLog(url: url, header: header, callbackQueue: parseQueue,
            onOpened: { [weak self] openedURL in
                guard let self = self, self.latestLogSession == session else { return }
                DispatchQueue.main.async {
                    self.logURL = openedURL
                    self.logFile = "Log: \(openedURL.lastPathComponent)"
                }
            },
            onFailure: { [weak self] _ in
                guard let self = self, self.latestLogSession == session else { return }
                DispatchQueue.main.async {
                    self.logFile = "Kayıt yazılamadı."
                }
            })
    }

    private func writeLogLine(_ line: String) {
        guard let log = csvLog else { return }
        if !log.append(line) { logSkippedRows += 1 }
    }

    private func startTelemetry() {
        telemetryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: parseQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.activeSession != nil else { return }
            self.pollRendererMetrics()
            self.logStatsIfNeeded()
        }
        telemetryTimer = timer
        timer.resume()
    }

    // UIView/CADisplayLink callbacks arrive on main. Receiver state stays on parseQueue.
    func attachDisplayMonitor(id: UUID) {
        parseQueue.async { [weak self] in
            self?.displayMonitorID = id
            self?.displayRhythmReport = nil
            self?.displayRhythmState = "waiting"
            DispatchQueue.main.async { [weak self] in self?.screenRhythm = "—" }
        }
    }

    func receiveDisplayRhythm(_ report: DisplayRhythmMonitor.Report, monitorID: UUID) {
        parseQueue.async { [weak self] in
            guard let self = self, self.activeSession == report.session,
                  self.displayMonitorID == monitorID,
                  ProcessInfo.processInfo.systemUptime - report.sampledAt < 3 else { return }
            self.displayRhythmReport = report
            self.displayRhythmState = "available"
            let text = String(format: "%.1f/sn · p95 ≤ %.2f ms · max %.2f ms",
                              report.callbackHz,
                              report.callbackIntervals.p95UpperBoundMs ?? 0,
                              report.callbackIntervals.maxMs ?? 0)
            DispatchQueue.main.async { [weak self] in self?.screenRhythm = text }
        }
    }

    func displayRhythmUnavailable(session: UUID, monitorID: UUID) {
        parseQueue.async { [weak self] in
            guard let self = self, self.activeSession == session,
                  self.displayMonitorID == monitorID else { return }
            self.displayRhythmReport = nil
            self.displayRhythmState = "paused"
            DispatchQueue.main.async { [weak self] in self?.screenRhythm = "—" }
        }
    }

    private func publishRendererFPS() {
        let text = rendererFPS.map { String(format: "%.1f", $0) } ?? "—"
        let detail: String
        switch rendererMetricsState {
        case "available":
            detail = "iPad görüntüleyicisinin toplam ve düşen karelerinden hesaplanır; panel Hz ölçümü değildir."
        case "unsupported":
            detail = "Gösterim ölçümü iPadOS 17.4 veya sonrası gerektirir."
        case "unavailable", "stale":
            detail = "Güncel gösterim ölçümü alınamadı."
        case "warming_up":
            detail = "Gösterim ölçülüyor…"
        default:
            detail = "Yayın başlayınca ölçülür."
        }
        DispatchQueue.main.async { [weak self] in
            self?.displayedFPS = text
            self?.displayedFPSDetail = detail
        }
    }

    private func resetRendererMetrics(state: String = "warming_up") {
        metricsGeneration &+= 1
        metricsRequestStart = nil
        rendererFPSCounter.reset()
        rendererSample = nil
        rendererFPS = nil
        rendererMetricsState = activeSession == nil ? "inactive" : state
        publishRendererFPS()
    }

    private func flushRenderer(_ renderer: AVSampleBufferVideoRenderer? = nil) {
        (renderer ?? displayLayer?.sampleBufferRenderer)?.flush()
        // A flush may reset Apple's counters. Also reject any pre-flush callback.
        resetRendererMetrics()
    }

    private func pollRendererMetrics() {
        guard #available(iOS 17.4, *) else {
            if rendererMetricsState != "unsupported" {
                resetRendererMetrics(state: "unsupported")
            }
            return
        }
        guard let session = activeSession, gotConfig,
              let renderer = displayLayer?.sampleBufferRenderer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let sample = rendererSample, now - sample.time >= 3 {
            // Expire the visible value even while a query is still pending.
            rendererFPSCounter.reset()
            rendererSample = nil
            rendererFPS = nil
            rendererMetricsState = "stale"
            publishRendererFPS()
        }
        if let started = metricsRequestStart {
            guard now - started >= 3 else { return } // Only one query at a time.
            resetRendererMetrics(state: "stale")
        }
        metricsRequest &+= 1
        let request = metricsRequest
        let generation = metricsGeneration
        metricsRequestStart = now
        renderer.loadVideoPerformanceMetrics { [weak self, weak renderer] metrics in
            // The callback queue is unspecified. Copy values before hopping back.
            let sampledAt = ProcessInfo.processInfo.systemUptime
            let values = metrics.map {
                (total: $0.totalNumberOfFrames, dropped: $0.numberOfDroppedFrames,
                 corrupted: $0.numberOfCorruptedFrames, delay: $0.totalAccumulatedFrameDelay)
            }
            guard let self = self else { return }
            self.parseQueue.async { [weak self, weak renderer] in
                guard let self = self, let renderer = renderer,
                      self.activeSession == session, self.metricsGeneration == generation,
                      self.metricsRequest == request,
                      self.displayLayer?.sampleBufferRenderer === renderer else { return }
                self.metricsRequestStart = nil
                guard sampledAt - now < 3,
                      ProcessInfo.processInfo.systemUptime - sampledAt < 3 else {
                    self.resetRendererMetrics(state: "stale")
                    return
                }
                guard let values = values, values.total >= 0, values.dropped >= 0,
                      values.dropped <= values.total, values.corrupted >= 0,
                      values.delay.isFinite, values.delay >= 0 else {
                    self.resetRendererMetrics(state: "unavailable")
                    return
                }
                self.rendererFPS = self.rendererFPSCounter.observe(
                    total: values.total, dropped: values.dropped, at: sampledAt)
                self.rendererSample = (sampledAt, values.total, values.dropped,
                                       values.corrupted, values.delay)
                self.rendererMetricsState = self.rendererFPS == nil ? "warming_up" : "available"
                self.publishRendererFPS()
            }
        }
    }

    private func resetLogCounters() {
        rxBytesLog = 0
        packetCountLog = 0
        payloadBytesLog = 0
        maxPayloadBytesLog = 0
        rxBufferMaxLog = 0
        enqueuedLog = 0
        idrLog = 0
        notReadyLog = 0
        syncDropLog = 0
        rendererFailedLog = 0
        refreshLog = 0
        invalidPacketLog = 0
    }

    private func logStatsIfNeeded(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard activeSession != nil, force || now - lastLog >= 0.9 else { return }

        let rendererStatus: String
        if let r = displayLayer?.sampleBufferRenderer {
            switch r.status {
            case .unknown: rendererStatus = "unknown"
            case .rendering: rendererStatus = "rendering"
            case .failed: rendererStatus = "failed"
            @unknown default: rendererStatus = "other"
            }
        } else {
            rendererStatus = "none"
        }

        let t = now - logStart
        let counters = String(format: "%.3f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%@",
                            t,
                            rxBytesLog,
                            packetCountLog,
                            payloadBytesLog,
                            maxPayloadBytesLog,
                            rxBufferMaxLog,
                            enqueuedLog,
                            idrLog,
                            notReadyLog,
                            syncDropLog,
                            rendererFailedLog,
                            refreshLog,
                            invalidPacketLog,
                            enqueueCount,
                            droppedFrames,
                            queueRefreshes,
                            waitingForSync ? 1 : 0,
                            rendererStatus)
        // Blank values mean unavailable; zero remains a valid measured result.
        var performance: [String] = [rendererMetricsState]
        if let sample = rendererSample {
            performance.append(String(format: "%.3f", sample.time - logStart))
            performance.append(String(format: "%.3f", (now - sample.time) * 1000))
            performance.append(String(sample.total))
            performance.append(String(sample.dropped))
            performance.append(String(sample.corrupted))
            performance.append(String(format: "%.3f", sample.delay * 1000))
        } else {
            performance.append(contentsOf: Array(repeating: "", count: 6))
        }
        performance.append(rendererFPS.map { String(format: "%.3f", $0) } ?? "")
        performance.append(String(metricsGeneration))
        performance.append(String(logSkippedRows))
        let windowSeconds = now - lastLog
        var timingFields = [String(completedFramesLog)]
        timingFields.append(windowSeconds > 0
            ? String(format: "%.3f", Double(completedFramesLog) / windowSeconds) : "")
        timingFields.append(lastArrivedFrameID.map { String($0) } ?? "")
        timingFields.append(previousFrameArrival.map { String(format: "%.3f", (now - $0) * 1000) } ?? "")
        timingFields.append(String(format: "%.3f", windowSeconds))
        let frameGaps = frameGapStats.snapshot()
        timingFields += frameGaps.csvFields
        timingFields += assemblyStats.snapshot().csvFields
        if let report = displayRhythmReport, now - report.sampledAt >= 3 {
            displayRhythmReport = nil
            displayRhythmState = "stale"
            DispatchQueue.main.async { [weak self] in self?.screenRhythm = "—" }
        }
        timingFields.append(displayRhythmState)
        if let report = displayRhythmReport {
            timingFields.append(String(format: "%.3f", report.sampledAt - logStart))
            timingFields.append(String(format: "%.3f", (now - report.sampledAt) * 1000))
            timingFields.append(String(format: "%.3f", report.durationSeconds))
            timingFields.append(String(format: "%.3f", report.callbackHz))
            if let expected = report.expectedIntervals.meanMs, expected > 0 {
                timingFields.append(String(format: "%.3f", 1000 / expected))
            } else {
                timingFields.append("")
            }
            timingFields.append(report.lowPower ? "1" : "0")
            timingFields.append(String(report.thermalState))
            timingFields += report.callbackIntervals.csvFields
            timingFields += report.expectedIntervals.csvFields
            timingFields += report.callbackOffsets.csvFields
        } else {
            timingFields.append(contentsOf: Array(repeating: "", count: 7 + 3 * 9))
        }
        performance += timingFields
        writeLogLine(counters + "," + performance.joined(separator: ",") + "\n")
        let arrivalText: String
        if let p95 = frameGaps.p95UpperBoundMs, let maximum = frameGaps.maxMs {
            arrivalText = String(format: "p95 ≤ %.2f ms · max %.2f ms", p95, maximum)
        } else {
            arrivalText = "—"
        }
        DispatchQueue.main.async { [weak self] in self?.frameArrivalTiming = arrivalText }
        frameGapStats.reset()
        assemblyStats.reset()
        completedFramesLog = 0
        resetLogCounters()
        lastLog = now
    }
    
    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn, self.connection === conn, self.isRunning else { return }
            if let data = data, !data.isEmpty { self.handleIncomingData(data) }
            if isComplete || error != nil {
                self.networkDisconnected(conn, reason: error.map { "Bağlantı hatası: \($0)" } ?? "Bilgisayar bağlantıyı kapattı.")
                return
            }
            self.receive(on: conn)
        }
    }

    private func parsePackets() {
        var offset = 0
        while rx.count - offset >= 4 {
            let len = Int(UInt32(rx[offset]) << 24 | UInt32(rx[offset+1]) << 16 | UInt32(rx[offset+2]) << 8 | UInt32(rx[offset+3]))
            let total = 4 + len
            guard len > 0, len < 10_000_000 else {
                invalidPacketLog += 1
                recoverFromStreamError("Geçersiz video paket uzunluğu: \(len). USB oturumu sıfırlandı.")
                return
            }
            guard rx.count - offset >= total else { break }
            let payload = rx.subdata(in: (offset + 4)..<(offset + total))
            packetCountLog += 1
            payloadBytesLog += len
            if len > maxPayloadBytesLog { maxPayloadBytesLog = len }
            offset += total
            if !gotConfig {
                if makeFormatDescFromConfig(payload) {
                    gotConfig = true
                    print("[CFG] Config received!")
                    self.waitingForSync = false
                    // Flush on the enqueue queue before the first IDR arrives.
                    self.flushRenderer()
                    self.publishStatus("Yayın alınıyor...", phase: .preparing,
                                       debug: "CFG OK | video stream ready")
                } else if !firstConfigFailLogged {
                    firstConfigFailLogged = true
                    let preview = payload.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    DispatchQueue.main.async {
                        self.debug = "CFG FAIL len=\(payload.count) | \(preview)"
                    }
                }
            } else {
                if !handleChunkPacket(payload) {
                    enqueueFrame(payload)
                }
            }
        }
        if offset > 0 {
            if offset == rx.count { rx.removeAll(keepingCapacity: true) }
            else                  { rx.removeSubrange(0..<offset) }
        }
    }

    private func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        return UInt32(data[offset]) << 24 |
               UInt32(data[offset + 1]) << 16 |
               UInt32(data[offset + 2]) << 8 |
               UInt32(data[offset + 3])
    }

    private func resetChunkFrame() {
        chunkFrameId = nil
        chunkExpectedTotal = 0
        chunkBuffer.removeAll(keepingCapacity: true)
        chunkStartedAt = nil
    }

    private func handleChunkPacket(_ payload: Data) -> Bool {
        guard payload.count >= 20 else { return false }
        guard payload[0] == 0x44, payload[1] == 0x43, payload[2] == 0x32, payload[3] == 0x46 else {
            return false
        }
        guard payload[4] == 1 else {
            invalidPacketLog += 1
            resetChunkFrame()
            return true
        }

        let flags = payload[5]
        let frameId = readBE32(payload, 8)
        let offset = Int(readBE32(payload, 12))
        let total = Int(readBE32(payload, 16))
        let chunkStart = 20
        let chunkSize = payload.count - chunkStart
        let isLast = (flags & 0x02) != 0

        guard total > 0, total < 10_000_000, chunkSize >= 0, offset >= 0, offset + chunkSize <= total else {
            invalidPacketLog += 1
            resetChunkFrame()
            return true
        }

        if chunkFrameId != frameId {
            chunkFrameId = frameId
            chunkExpectedTotal = total
            chunkBuffer = Data(capacity: total)
            chunkStartedAt = receiveBatchTime
        }

        guard chunkExpectedTotal == total, offset == chunkBuffer.count else {
            invalidPacketLog += 1
            resetChunkFrame()
            return true
        }

        chunkBuffer.append(payload.subdata(in: chunkStart..<payload.count))

        if isLast || chunkBuffer.count == total {
            guard chunkBuffer.count == total else {
                invalidPacketLog += 1
                resetChunkFrame()
                return true
            }
            let frame = chunkBuffer
            let assemblyMs = chunkStartedAt.map { (receiveBatchTime - $0) * 1000 }
            resetChunkFrame()
            enqueueFrame(frame, frameID: frameId, assemblyMs: assemblyMs)
        }
        return true
    }
    
    // MARK: - Enqueue
    
    private func enqueueFrame(_ payload: Data, frameID: UInt32? = nil, assemblyMs: Double? = nil) {
        if let previous = previousFrameArrival {
            frameGapStats.record((receiveBatchTime - previous) * 1000)
        }
        previousFrameArrival = receiveBatchTime
        lastArrivedFrameID = frameID
        completedFramesLog += 1
        if let assemblyMs = assemblyMs { assemblyStats.record(assemblyMs) }
        guard let format = formatDesc else { return }
        let payloadIsAnnexB = looksLikeAnnexB(payload)
        let au = payloadIsAnnexB ? annexBToAVCC(payload) : payload
        let isIDR = containsIDR(au, nalHeaderLength: payloadIsAnnexB ? 4 : nalHeaderLength)
        guard let layer = self.displayLayer else { return }
        let renderer = layer.sampleBufferRenderer
        if isIDR { idrLog += 1 }

        if renderer.status == .failed {
            rendererFailedLog += 1
            flushRenderer(renderer)
            waitingForSync = true
        }

        if waitingForSync {
            guard isIDR else {
                droppedFrames += 1
                syncDropLog += 1
                reportDropsIfNeeded()
                return
            }
            flushRenderer(renderer)
            waitingForSync = false
            notReadyStreak = 0
            frameIndex = 0
        }

        if !renderer.isReadyForMoreMediaData {
            notReadyLog += 1
            notReadyStreak += 1
            if isIDR && notReadyStreak >= 3 {
                flushRenderer(renderer)
                queueRefreshes += 1
                refreshLog += 1
                notReadyStreak = 0
                frameIndex = 0
            }
        } else {
            notReadyStreak = 0
        }

        var block: CMBlockBuffer?
        let st1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: au.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0,
            dataLength: au.count, flags: 0, blockBufferOut: &block)
        guard st1 == kCMBlockBufferNoErr, let bb = block else { return }
        au.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb,
                                              offsetIntoDestination: 0, dataLength: au.count)
            }
        }
        var sampleSize: Int = au.count
        let pts = CMTime(value: frameIndex, timescale: fps)
        let dur = CMTime(value: 1, timescale: fps)
        frameIndex += 1
        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let st2 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard st2 == noErr, let s = sample else { return }
        guard setVideoSampleAttachments(s, isIDR: isIDR) else { return }
        renderer.enqueue(s)
        self.enqueueCount += 1
        self.enqueuedLog += 1
        // Reveal the video on the first frame; keep periodic UI updates inexpensive.
        if self.enqueueCount == 1 || self.enqueueCount % 60 == 0 {
            let count = enqueueCount
            DispatchQueue.main.async { [weak self] in
                self?.frames = count
                self?.status = "Streaming"
                self?.phase = .streaming
            }
        }
    }

    private func reportDropsIfNeeded() {
        guard droppedFrames % 30 == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.debug = "CFG OK | drop: \(self.droppedFrames) | refresh: \(self.queueRefreshes)"
        }
    }
    
    // MARK: - Config
    
    private func makeFormatDescFromConfig(_ cfg: Data) -> Bool {
        if makeFormatDescFromAVCC(cfg) { return true }
        if let (sps, pps) = extractSpsPpsFromAnnexB(cfg) {
            if makeFormatDescFromSpsPps(sps: sps, pps: pps, nalHeaderLen: 4) { return true }
        }
        return false
    }
    
    private func makeFormatDescFromAVCC(_ avcc: Data) -> Bool {
        guard avcc.count >= 7, avcc[0] == 1 else { return false }
        var i = 4
        guard i < avcc.count else { return false }
        let nalHeaderLen = Int32(avcc[i] & 0x03) + 1; i += 1
        guard i < avcc.count else { return false }
        let numSPS = Int(avcc[i] & 0x1F); i += 1
        guard numSPS > 0 else { return false }
        var spsData: Data?
        for _ in 0..<numSPS {
            guard i + 2 <= avcc.count else { return false }
            let spsLen = Int(UInt16(avcc[i]) << 8 | UInt16(avcc[i+1])); i += 2
            guard i + spsLen <= avcc.count else { return false }
            if spsData == nil { spsData = avcc.subdata(in: i..<(i+spsLen)) }
            i += spsLen
        }
        guard i < avcc.count else { return false }
        let numPPS = Int(avcc[i]); i += 1
        guard numPPS > 0 else { return false }
        var ppsData: Data?
        for _ in 0..<numPPS {
            guard i + 2 <= avcc.count else { return false }
            let ppsLen = Int(UInt16(avcc[i]) << 8 | UInt16(avcc[i+1])); i += 2
            guard i + ppsLen <= avcc.count else { return false }
            if ppsData == nil { ppsData = avcc.subdata(in: i..<(i+ppsLen)) }
            i += ppsLen
        }
        guard let sps = spsData, let pps = ppsData else { return false }
        return makeFormatDescFromSpsPps(sps: sps, pps: pps, nalHeaderLen: nalHeaderLen)
    }
    
    private func makeFormatDescFromSpsPps(sps: Data, pps: Data, nalHeaderLen: Int32) -> Bool {
        var desc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                guard let sB = spsPtr.baseAddress, let pB = ppsPtr.baseAddress else { return OSStatus(-1) }
                var ptrs: [UnsafePointer<UInt8>] = [sB.assumingMemoryBound(to: UInt8.self),
                                                    pB.assumingMemoryBound(to: UInt8.self)]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: nalHeaderLen, formatDescriptionOut: &desc)
            }
        }
        if status == noErr, let d = desc {
            self.formatDesc = d
            self.nalHeaderLength = Int(nalHeaderLen)
            return true
        }
        return false
    }
    
    // MARK: - AnnexB helpers
    
    private func looksLikeAnnexB(_ d: Data) -> Bool {
        if d.count >= 4, d[0]==0, d[1]==0, d[2]==0, d[3]==1 { return true }
        if d.count >= 3, d[0]==0, d[1]==0, d[2]==1          { return true }
        return false
    }
    
    private func extractNalUnitsFromAnnexB(_ data: Data) -> [Data] {
        guard data.count >= 4 else { return [] }
        var starts: [(Int,Int)] = []
        var i = 0
        while i < data.count - 2 {
            if data[i]==0, data[i+1]==0 {
                if i+3 < data.count, data[i+2]==0, data[i+3]==1 { starts.append((i,4)); i+=4; continue }
                else if data[i+2]==1                              { starts.append((i,3)); i+=3; continue }
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }
        var nalus: [Data] = []
        for s in 0..<starts.count {
            let a = starts[s].0 + starts[s].1
            let b = (s+1 < starts.count) ? starts[s+1].0 : data.count
            if a < b { nalus.append(data.subdata(in: a..<b)) }
        }
        return nalus
    }
    
    private func extractSpsPpsFromAnnexB(_ data: Data) -> (Data, Data)? {
        let nalus = extractNalUnitsFromAnnexB(data)
        var sps: Data?, pps: Data?
        for n in nalus where !n.isEmpty {
            let t = n[0] & 0x1F
            if t == 7, sps == nil { sps = n }
            if t == 8, pps == nil { pps = n }
            if sps != nil, pps != nil { break }
        }
        if let s = sps, let p = pps { return (s, p) }
        return nil
    }
    
    private func annexBToAVCC(_ data: Data) -> Data {
        let nalus = extractNalUnitsFromAnnexB(data)
        if nalus.isEmpty { return data }
        var out = Data(); out.reserveCapacity(data.count)
        for n in nalus {
            var len = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(n)
        }
        return out
    }

    private func containsIDR(_ avcc: Data, nalHeaderLength: Int) -> Bool {
        guard nalHeaderLength > 0, nalHeaderLength <= 4 else { return false }
        var i = 0
        while i + nalHeaderLength < avcc.count {
            var len = 0
            for j in 0..<nalHeaderLength {
                len = (len << 8) | Int(avcc[i + j])
            }
            guard len > 0, i + nalHeaderLength + len <= avcc.count else { return false }
            let nalType = avcc[i + nalHeaderLength] & 0x1F
            if nalType == 5 { return true }
            i += nalHeaderLength + len
        }
        return false
    }
}

// MARK: - Display callback rhythm (diagnostics only)

// Requires IntervalStats from TimingStatistics.swift. These are Core Animation
// callback measurements, not counts of newly displayed video frames or proof of
// physical panel scanout. The link keeps the system's default frame-rate policy.
@MainActor
final class DisplayRhythmMonitor: NSObject {
    struct Report {
        let session: UUID
        // ProcessInfo uptime shares the receiver's existing monotonic clock.
        let sampledAt: TimeInterval
        // Elapsed display timestamps, not a nominal one-second timer interval.
        let durationSeconds: TimeInterval
        let callbackHz: Double
        let callbackIntervals: IntervalStats.Summary
        let expectedIntervals: IntervalStats.Summary
        // Time from the display timestamp to callback entry. This includes the
        // normal callback offset; it is not a missed-deadline or video-delay count.
        let callbackOffsets: IntervalStats.Summary
        let lowPower: Bool
        // ProcessInfo.ThermalState rawValue, sampled once per report.
        let thermalState: Int
    }

    // Both closures execute on the main thread. Consumers should still check
    // the session when forwarding a report to the receiver's serial queue.
    var onReport: ((Report) -> Void)?
    var onUnavailable: ((UUID) -> Void)?

    private var requestedSession: UUID?
    private var streaming = false
    private var viewIsInWindow = false
    private var applicationIsActive = false
    private var activeSession: UUID?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayRhythmTarget?
    private var previousTimestamp: CFTimeInterval?
    private var windowStartTimestamp: CFTimeInterval?
    private var callbackIntervals = IntervalStats()
    private var expectedIntervals = IntervalStats()
    private var callbackOffsets = IntervalStats()

    override init() {
        super.init()
        applicationIsActive = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillResignActive(_:)),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        displayLink?.invalidate()
    }

    func update(session: UUID?, streaming: Bool, viewIsInWindow: Bool) {
        requestedSession = session
        self.streaming = streaming
        self.viewIsInWindow = viewIsInWindow
        reconcile()
    }

    // Explicit teardown for UIViewRepresentable dismantling. A later update can
    // start a fresh link; no history crosses a stop, view detach or scene pause.
    func stop() {
        requestedSession = nil
        streaming = false
        viewIsInWindow = false
        deactivate()
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        applicationIsActive = false
        reconcile()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        applicationIsActive = true
        reconcile()
    }

    private func reconcile() {
        guard streaming, viewIsInWindow, applicationIsActive,
              let session = requestedSession else {
            deactivate()
            return
        }
        if activeSession == session, displayLink != nil { return }
        deactivate()
        activeSession = session
        let target = DisplayRhythmTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayRhythmTarget.tick(_:)))
        displayLinkTarget = target
        displayLink = link
        // Deliberately leave preferredFrameRateRange / preferredFramesPerSecond
        // at their defaults. A 120-Hz preference is a separate future A/B change.
        link.add(to: .main, forMode: .common)
    }

    private func deactivate() {
        let oldSession = activeSession
        activeSession = nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        clearHistory()
        if let oldSession = oldSession { onUnavailable?(oldSession) }
    }

    private func clearHistory() {
        previousTimestamp = nil
        windowStartTimestamp = nil
        callbackIntervals.reset()
        expectedIntervals.reset()
        callbackOffsets.reset()
    }

    fileprivate func record(_ link: CADisplayLink) {
        guard displayLink === link, let session = activeSession else { return }
        // Per callback: only timestamp arithmetic and fixed-size numeric bins.
        // No dispatch, string formatting, UI mutation, disk I/O or array growth.
        let timestamp = link.timestamp
        let targetTimestamp = link.targetTimestamp
        let enteredAt = CACurrentMediaTime()
        guard timestamp.isFinite, timestamp >= 0 else {
            clearHistory()
            return
        }
        if let previous = previousTimestamp {
            guard timestamp > previous else {
                clearHistory()
                previousTimestamp = timestamp
                windowStartTimestamp = timestamp
                return
            }
            callbackIntervals.record((timestamp - previous) * 1000)
        } else {
            windowStartTimestamp = timestamp
        }
        previousTimestamp = timestamp
        if targetTimestamp.isFinite, targetTimestamp > timestamp {
            expectedIntervals.record((targetTimestamp - timestamp) * 1000)
        }
        if enteredAt.isFinite {
            callbackOffsets.record(max(0, enteredAt - timestamp) * 1000)
        }
        guard let start = windowStartTimestamp, timestamp - start >= 1 else { return }
        let duration = timestamp - start
        let intervals = callbackIntervals.snapshot()
        guard intervals.count > 0 else { return }
        let process = ProcessInfo.processInfo
        let report = Report(
            session: session,
            sampledAt: process.systemUptime,
            durationSeconds: duration,
            callbackHz: Double(intervals.count) / duration,
            callbackIntervals: intervals,
            expectedIntervals: expectedIntervals.snapshot(),
            callbackOffsets: callbackOffsets.snapshot(),
            lowPower: process.isLowPowerModeEnabled,
            thermalState: process.thermalState.rawValue)
        // Retain the last timestamp so the next window includes its first gap.
        windowStartTimestamp = timestamp
        callbackIntervals.reset()
        expectedIntervals.reset()
        callbackOffsets.reset()
        onReport?(report)
    }
}

// CADisplayLink retains its target. This proxy prevents a link -> monitor cycle.
@MainActor
private final class DisplayRhythmTarget: NSObject {
    weak var owner: DisplayRhythmMonitor?

    init(owner: DisplayRhythmMonitor) {
        self.owner = owner
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) { owner?.record(link) }
}

// MARK: - Full-screen video UIView

final class VideoLayerUIView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let rhythmMonitor = DisplayRhythmMonitor()
    private let rhythmMonitorID = UUID()
    private var rhythmSession: UUID?
    private var streaming = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill   // fill the whole screen
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        layer.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    func bindRhythm(to receiver: VideoReceiver) {
        let monitorID = rhythmMonitorID
        receiver.attachDisplayMonitor(id: monitorID)
        rhythmMonitor.onReport = { [weak receiver] report in
            receiver?.receiveDisplayRhythm(report, monitorID: monitorID)
        }
        rhythmMonitor.onUnavailable = { [weak receiver] session in
            receiver?.displayRhythmUnavailable(session: session, monitorID: monitorID)
        }
    }
    func updateRhythm(session: UUID?, streaming: Bool) {
        rhythmSession = session
        self.streaming = streaming
        rhythmMonitor.update(session: session, streaming: streaming, viewIsInWindow: window != nil)
    }
    func stopRhythm() { rhythmMonitor.stop() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        rhythmMonitor.update(session: rhythmSession, streaming: streaming, viewIsInWindow: window != nil)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
}

struct VideoView: UIViewRepresentable {
    @ObservedObject var rx: VideoReceiver
    func makeUIView(context: Context) -> VideoLayerUIView {
        let v = VideoLayerUIView()
        rx.displayLayer = v.displayLayer
        v.bindRhythm(to: rx)
        return v
    }
    func updateUIView(_ uiView: VideoLayerUIView, context: Context) {
        uiView.updateRhythm(session: rx.timingSession, streaming: rx.phase == .streaming)
    }
    static func dismantleUIView(_ uiView: VideoLayerUIView, coordinator: ()) {
        uiView.stopRhythm()
    }
}

// MARK: - Full-screen host controller (hides status bar)

final class FullScreenHostController: UIHostingController<AnyView> {
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

// MARK: - App entry that uses the custom host controller

struct FullScreenWindowGroup: UIViewControllerRepresentable {
    let content: AnyView
    func makeUIViewController(context: Context) -> UIViewController {
        FullScreenHostController(rootView: content)
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

// MARK: - iPad connection presentation

// The receiver publishes explicit phases so presentation never depends on log text.
enum ClientConnectionState: Equatable {
    case waiting, preparing, streaming, reconnecting, error

    var title: String {
        switch self {
        case .waiting: return "İkinci ekranınız hazır."
        case .preparing: return "Ekranınız hazırlanıyor."
        case .streaming: return "Windows ekranı bağlı"
        case .reconnecting: return "Yeniden bağlantı bekleniyor."
        case .error: return "Bağlantıyı kontrol edin."
        }
    }

    var subtitle: String {
        switch self {
        case .waiting: return "iPad'inizi USB ile bağlayın. Windows'taki WinSideUSB bağlantıyı otomatik kurar."
        case .preparing: return "Bilgisayar bağlı. İlk görüntü geldiğinde bu panel kendiliğinden gizlenir."
        case .streaming: return "USB üzerinden görüntü aktarılıyor."
        case .reconnecting: return "USB kablosunu ve Windows'taki WinSideUSB'yi kontrol edin. İstemci yeni bağlantıyı otomatik bekler."
        case .error: return "Kabloyu ve bilgisayardaki WinSideUSB'yi kontrol edin. Buradan yeniden deneyebilirsiniz."
        }
    }

    var label: String {
        switch self {
        case .waiting: return "BAĞLANTIYA HAZIR"
        case .preparing: return "GÖRÜNTÜ BEKLENİYOR"
        case .streaming: return "BAĞLI"
        case .reconnecting: return "YENİDEN BAĞLANIYOR"
        case .error: return "BAĞLANTI SORUNU"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "cable.connector"
        case .preparing, .reconnecting: return "arrow.triangle.2.circlepath"
        case .streaming: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .waiting, .preparing: return .teal
        case .streaming: return .green
        case .reconnecting, .error: return .orange
        }
    }

    var canRetry: Bool {
        self == .waiting || self == .preparing || self == .reconnecting || self == .error
    }
}

// MARK: - Main View

struct MainView: View {
    @StateObject private var rx = VideoReceiver()
    @State private var showOverlay = true
    @State private var showDiagnostics = false
    @State private var retryCoolingDown = false
    @State private var voiceOverRunning = UIAccessibility.isVoiceOverRunning
    @State private var hideTask: DispatchWorkItem?
    @State private var retryTask: DispatchWorkItem?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var connectionState: ClientConnectionState { rx.phase }
    private var isStreaming: Bool { connectionState == .streaming }
    private var panelAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.25)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoView(rx: rx)
                    .ignoresSafeArea()
                    .onTapGesture { revealControls() }
                    .accessibilityHidden(true)

                if !isStreaming {
                    waitingBackground
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if showOverlay {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            ViewThatFits(in: .vertical) {
                                connectionPanel
                                ScrollView(showsIndicators: false) {
                                    connectionPanel
                                }
                                .frame(maxHeight: max(0, geometry.size.height - 40))
                            }
                            .frame(maxWidth: isStreaming ? 380 : 520)
                            if isStreaming { Spacer(minLength: 0) }
                        }
                        if !isStreaming { Spacer(minLength: 0) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
                    .transition(.opacity)
                } else if voiceOverRunning {
                    // Touch users reveal controls by tapping the video. Keep a
                    // discoverable button only when VoiceOver hides the panel.
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: revealControls) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 48, height: 48)
                                    .background {
                                        if reduceTransparency {
                                            Circle().fill(Color(uiColor: .secondarySystemBackground))
                                        } else {
                                            Circle().fill(.regularMaterial)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .accessibilityLabel("Bağlantı kontrollerini göster")
                            .accessibilityHint("Durumu ve kayıt paylaşma seçeneklerini açar")
                        }
                        Spacer()
                    }
                    .padding(20)
                    .transition(.opacity)
                }
            }
        }
        .statusBar(hidden: true)
        .onAppear { rx.start() }
        .onDisappear {
            hideTask?.cancel()
            retryTask?.cancel()
            retryCoolingDown = false
        }
        .onChange(of: rx.phase) { updateControlsForConnection() }
        .onChange(of: showDiagnostics) { scheduleHide() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: rx.resume()
            case .background:
                hideTask?.cancel()
                rx.suspend()
            case .inactive: break
            @unknown default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            voiceOverRunning = UIAccessibility.isVoiceOverRunning
            if voiceOverRunning { revealControls() }
            else { scheduleHide() }
        }
    }

    private var waitingBackground: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.07, green: 0.12, blue: 0.16), Color(red: 0.025, green: 0.04, blue: 0.07)]
                    : [Color(red: 0.95, green: 0.98, blue: 0.99), Color(red: 0.89, green: 0.93, blue: 0.97)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack {
                HStack {
                    Circle()
                        .fill(Color.teal.opacity(colorScheme == .dark ? 0.12 : 0.09))
                        .frame(width: 400, height: 400)
                        .blur(radius: 80)
                        .offset(x: -150, y: -130)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: isStreaming ? 20 : 26) {
            panelHeader

            if !isStreaming { displayIllustration }

            VStack(alignment: .leading, spacing: 12) {
                Label(connectionState.label, systemImage: connectionState.symbol)
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(connectionState.tint)
                Text(connectionState.title)
                    .font(isStreaming ? .title3.weight(.semibold) : .largeTitle.weight(.semibold))
                    .tracking(isStreaming ? 0 : -0.6)
                    .fixedSize(horizontal: false, vertical: true)
                Text(connectionState.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if connectionState == .waiting {
                VStack(alignment: .leading, spacing: 14) {
                    connectionStep(number: "1", text: "iPad'i USB kablosuyla bilgisayara bağlayın.")
                    connectionStep(number: "2", text: "Windows'ta WinSideUSB'yi açın ve bu uygulamayı açık tutun.")
                }
            } else if connectionState == .preparing {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.teal)
                    Text("İlk video karesi bekleniyor")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if connectionState == .reconnecting || connectionState == .error {
                recoveryActions
            }

            if showDiagnostics {
                diagnostics
                    .transition(.opacity)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    diagnosticsButton
                    Spacer(minLength: 0)
                    if connectionState == .waiting || connectionState == .preparing { refreshButton }
                    shareLogButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    diagnosticsButton
                    if connectionState == .waiting || connectionState == .preparing { refreshButton }
                    shareLogButton
                }
            }
        }
        .padding(isStreaming ? 22 : 30)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            } else {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 30, y: 16)
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            if !isStreaming {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 44, height: 44)
                    .background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("WinSideUSB")
                    .font(.headline)
                Text("iPad için ikinci ekran")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if isStreaming {
                Button(action: hideControls) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kontrolleri gizle")
            } else {
                Text("USB")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            }
        }
    }

    private var displayIllustration: some View {
        HStack(alignment: .center, spacing: 12) {
            deviceTile(symbol: "display", label: "Windows")
            VStack(spacing: 8) {
                Image(systemName: connectionState == .error ? "exclamationmark" : "arrow.right")
                    .font(.caption.weight(.semibold))
                Capsule().fill(connectionState.tint.opacity(0.24)).frame(width: 32, height: 3)
            }
            .foregroundStyle(connectionState.tint)
            deviceTile(symbol: "ipad.landscape", label: "iPad")
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    private func deviceTile(symbol: String, label: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(connectionState.tint)
                .frame(height: 48)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(connectionState.tint.opacity(0.10), lineWidth: 1)
        }
    }

    private func connectionStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.teal)
                .frame(width: 26, height: 26)
                .background(Color.teal.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Uygulama yeni bağlantıları otomatik bekler.", systemImage: "arrow.clockwise.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: retryConnection) {
                Label(retryCoolingDown ? "Yenileniyor…" : "Yeniden dene", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(connectionState.tint)
            .disabled(retryCoolingDown)
            .accessibilityHint("Bağlantı alıcısını uygulamayı kapatmadan yeniden hazırlar")
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    metric(title: "Bağlantı", value: "USB")
                    metric(title: "Video", value: "H.264")
                    metric(title: "İşlenen kare", value: rx.frames.formatted())
                    metric(title: "Gösterim FPS", value: rx.displayedFPS)
                }
                VStack(alignment: .leading, spacing: 12) {
                    metric(title: "Bağlantı", value: "USB · H.264")
                    metric(title: "İşlenen kare", value: rx.frames.formatted())
                    metric(title: "Gösterim FPS", value: rx.displayedFPS)
                }
            }
            Text(rx.displayedFPSDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            metric(title: "Kare geliş aralığı", value: rx.frameArrivalTiming)
            metric(title: "Ekran callback ritmi", value: rx.screenRhythm)
            Text("Callback ritmi Core Animation ölçümüdür; her callback yeni video karesi anlamına gelmez. Sabit görüntüde kare geliş aralıkları doğal olarak uzar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(rx.status)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if !rx.recoveryDetail.isEmpty {
                Text(rx.recoveryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(rx.debug)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !rx.layerInfo.isEmpty {
                Text(rx.layerInfo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(rx.logFile)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var diagnosticsButton: some View {
        Button {
            withAnimation(panelAnimation) { showDiagnostics.toggle() }
        } label: {
            Label("Ayrıntılar", systemImage: showDiagnostics ? "chevron.up" : "chevron.down")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityValue(showDiagnostics ? "Açık" : "Kapalı")
    }

    private var refreshButton: some View {
        Button(action: retryConnection) {
            Label(retryCoolingDown ? "Yenileniyor…" : "Yenile", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.teal)
        .disabled(retryCoolingDown)
        .accessibilityLabel("Bağlantı alıcısını yenile")
    }

    @ViewBuilder
    private var shareLogButton: some View {
        if let logURL = rx.logURL {
            ShareLink(item: logURL) {
                Label("Kaydı paylaş", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .tint(.teal)
        }
    }

    private func retryConnection() {
        guard connectionState.canRetry, !retryCoolingDown else { return }
        retryCoolingDown = true
        rx.retryConnection()
        let task = DispatchWorkItem { retryCoolingDown = false }
        retryTask?.cancel()
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private func updateControlsForConnection() {
        if !isStreaming {
            hideTask?.cancel()
            withAnimation(panelAnimation) { showOverlay = true }
        } else if showOverlay {
            scheduleHide()
        }
    }

    private func revealControls() {
        withAnimation(panelAnimation) { showOverlay = true }
        scheduleHide()
    }

    private func hideControls() {
        hideTask?.cancel()
        withAnimation(panelAnimation) {
            showOverlay = false
            showDiagnostics = false
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isStreaming, showOverlay, !showDiagnostics,
              !voiceOverRunning else { return }
        let task = DispatchWorkItem {
            withAnimation(panelAnimation) { showOverlay = false }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
}
