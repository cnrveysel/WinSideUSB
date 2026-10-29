import Foundation
import Dispatch

// Compiled with the production helpers extracted from swiftclientcode.swift.
// Local files and arithmetic only: no sockets, USB device, or display workload.
enum AsyncVideoLogTests {
    private enum Failure: Error { case assertion(String) }

    private final class Failures {
        private let lock = NSLock()
        private var messages: [String] = []

        func add(_ message: String) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return messages.count
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    private static func wait(_ semaphore: DispatchSemaphore) throws {
        try require(semaphore.wait(timeout: .now() + 5) == .success,
                    "Asynchronous log work did not finish.")
    }

    static func run() throws {
        try preservesOrderAndClosesAfterAcceptedWrites()
        try rejectsOverflowWhileIOIsPaused()
        try reportsOpenFailureOnceAndStopsAdmission()
    }

    private static func preservesOrderAndClosesAfterAcceptedWrites() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-log-order-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let target = DispatchQueue(label: "video-log-test.order-target")
        let callbacks = DispatchQueue(label: "video-log-test.order-callbacks")
        target.suspend()
        let failures = Failures()
        let finished = DispatchSemaphore(value: 0)
        let logger = AsyncVideoLog(url: url, header: "header\n", callbackQueue: callbacks,
                                   ioTargetQueue: target, onOpened: { _ in },
                                   onFailure: { failures.add($0) })
        let firstAccepted = logger.append("first\n")
        let secondAccepted = logger.append("second\n")
        logger.close { finished.signal() }
        let acceptedAfterClose = logger.append("late\n")
        target.resume()
        try wait(finished)
        try require(firstAccepted && secondAccepted && !acceptedAfterClose,
                    "Close did not reject subsequent appends.")
        try require(try String(contentsOf: url, encoding: .utf8) == "header\nfirst\nsecond\n",
                    "Accepted records were lost or reordered before close.")
        try require(failures.count == 0, "Ordered writes unexpectedly failed.")
    }

    private static func rejectsOverflowWhileIOIsPaused() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-log-bound-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let target = DispatchQueue(label: "video-log-test.bound-target")
        let callbacks = DispatchQueue(label: "video-log-test.bound-callbacks")
        target.suspend()
        let failures = Failures()
        let finished = DispatchSemaphore(value: 0)
        let logger = AsyncVideoLog(url: url, header: "h\n", callbackQueue: callbacks,
                                   pendingByteLimit: 10, ioTargetQueue: target,
                                   onOpened: { _ in }, onFailure: { failures.add($0) })
        let filledBudget = logger.append("12345678")
        let acceptedOverflow = logger.append("x")
        logger.close { finished.signal() }
        target.resume()
        try wait(finished)
        try require(filledBudget && !acceptedOverflow,
                    "Header and pending data did not share the byte limit.")
        try require(try String(contentsOf: url, encoding: .utf8) == "h\n12345678",
                    "A rejected record reached the file.")
        try require(failures.count == 0, "Bounded writes unexpectedly failed.")
    }

    private static func reportsOpenFailureOnceAndStopsAdmission() throws {
        // The random parent deliberately does not exist.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-log-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("log.csv")
        let callbacks = DispatchQueue(label: "video-log-test.failure-callbacks")
        let failures = Failures()
        let reported = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let logger = AsyncVideoLog(url: url, header: "h\n", callbackQueue: callbacks,
                                   onOpened: { _ in failures.add("Unexpected successful open.") },
                                   onFailure: { failures.add($0); reported.signal() })
        try wait(reported)
        let acceptedAfterFailure = logger.append("late\n")
        logger.close()
        logger.close { finished.signal() }
        try wait(finished)
        try require(!acceptedAfterFailure && failures.count == 1,
                    "Open failure did not stop admission or was reported repeatedly.")
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func testRendererRates() {
    var meter = RendererFPSCounter()
    check(meter.observe(total: 100, dropped: 4, at: 10) == nil, "First sample must be a baseline")
    check(meter.observe(total: 340, dropped: 14, at: 12) == 115,
          "Rate must subtract renderer drops and use actual elapsed time")
    check(meter.observe(total: 340, dropped: 14, at: 13) == 0, "Idle is a valid zero rate")
    print("PASS renderer rate, dropped frames, actual interval, idle")
}

private func testRendererReset() {
    var meter = RendererFPSCounter()
    _ = meter.observe(total: 1000, dropped: 10, at: 1)
    check(meter.observe(total: 10, dropped: 0, at: 2) == nil, "Counter rollback must rebase")
    check(meter.observe(total: 130, dropped: 0, at: 3) == 120, "Recovery baseline must be usable")
    meter.reset()
    check(meter.observe(total: 5000, dropped: 100, at: 4) == nil, "New generation must not inherit a rate")
    print("PASS renderer reset and counter rollback")
}

private func testRendererInvalidSamples() {
    var meter = RendererFPSCounter()
    _ = meter.observe(total: 10, dropped: 0, at: 1)
    check(meter.observe(total: 11, dropped: 2, at: 2) == nil, "Delayed drops must not create a negative rate")
    check(meter.observe(total: 12, dropped: 2, at: 2) == nil, "Zero interval is unavailable")
    check(meter.observe(total: 1000, dropped: 2, at: 10) == nil, "Stale intervals must rebase")
    check(meter.observe(total: 1001, dropped: 1002, at: 11) == nil, "Invalid totals must reset")
    check(meter.observe(total: 1002, dropped: 2, at: 12) == nil, "Invalid input must discard old baseline")
    check(meter.observe(total: 1003, dropped: 2, at: .nan) == nil, "Nonfinite time is unavailable")
    print("PASS invalid, delayed and stale renderer samples")
}

#if canImport(CoreMedia) && canImport(CoreVideo)
import CoreMedia
import CoreVideo

private func testSampleAttachments() {
    var pixel: CVPixelBuffer?
    check(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA,
                             nil, &pixel) == kCVReturnSuccess, "Pixel buffer creation")
    var format: CMVideoFormatDescription?
    check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
          imageBuffer: pixel!, formatDescriptionOut: &format) == noErr, "Video format creation")
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 120),
                                    presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
          imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing,
          sampleBufferOut: &sample) == noErr, "Sample creation")
    for isIDR in [true, false] {
        check(setVideoSampleAttachments(sample!, isIDR: isIDR), "Set per-sample keys")
        let array = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: false)!
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFDictionary.self)
        let immediate = CFDictionaryGetValue(dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque())
        let notSync = CFDictionaryGetValue(dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        check(immediate == UnsafeRawPointer(Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()),
              "Immediate flag must be on the sample")
        check(notSync == UnsafeRawPointer(Unmanaged.passUnretained(isIDR ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()),
              "IDR/P sync marker must be correct")
        check(CMGetAttachment(sample!, key: kCMSampleAttachmentKey_DisplayImmediately,
                              attachmentModeOut: nil) == nil, "No buffer-level immediate key")
    }
    print("PASS CoreMedia per-sample immediate and IDR/P flags")
}
#endif

// Deterministic snippet only. Compile alongside TimingStatistics.swift and call
// `try TimingStatisticsTests.run()` from the shared helper test entry point.
// No timers, sleeps, file access, device operations, or test execution here.
enum TimingStatisticsTests {
    private enum Failure: Error { case assertion(String) }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    static func run() throws {
        try histogramQuantilesAreExplicitUpperBounds()
        try longIdleGapsAndStrictThresholdsArePreserved()
        try invalidValuesDoNotChangeTheWindowAndResetClearsIt()
    }

    private static func histogramQuantilesAreExplicitUpperBounds() throws {
        var stats = IntervalStats()
        for value in [8.1, 8.2, 8.3, 8.4, 8.5] { stats.record(value) }
        let sample = stats.snapshot()
        try require(sample.count == 5 && abs((sample.meanMs ?? 0) - 8.3) < 0.000001,
                    "Count or online mean is incorrect.")
        try require(sample.maxMs == 8.5 && sample.p50UpperBoundMs == 8.5,
                    "Median should expose its 8.5ms bin bound, not an exact 8.3ms claim.")
        try require(sample.p95UpperBoundMs == 8.5 && sample.p99UpperBoundMs == 8.5,
                    "Tail upper bounds are incorrect.")
        stats.reset()
        stats.record(0)
        try require(stats.snapshot().p99UpperBoundMs == 0,
                    "An all-zero window should retain a zero upper bound.")
    }

    private static func longIdleGapsAndStrictThresholdsArePreserved() throws {
        var stats = IntervalStats()
        for value in [16.667, 25.0, 50.0, 64.0, 10_000.0] { stats.record(value) }
        let sample = stats.snapshot()
        try require(sample.count == 5 && sample.maxMs == 10_000,
                    "Long idle intervals were discarded or capped.")
        try require(abs((sample.meanMs ?? 0) - 2031.1334) < 0.000001,
                    "The long idle interval did not contribute to the mean.")
        try require(sample.over16_667Ms == 4 && sample.over25Ms == 3 && sample.over50Ms == 2,
                    "Threshold counts should use strict greater-than comparisons.")
        try require(sample.p50UpperBoundMs == 50 && sample.p99UpperBoundMs == 10_000,
                    "Regular or overflow quantile bounds are incorrect.")
    }

    private static func invalidValuesDoNotChangeTheWindowAndResetClearsIt() throws {
        var stats = IntervalStats()
        stats.record(8.25)
        let before = stats.snapshot()
        let acceptedNegative = stats.record(-1)
        let acceptedNaN = stats.record(.nan)
        let acceptedInfinity = stats.record(.infinity)
        try require(!acceptedNegative && !acceptedNaN && !acceptedInfinity && stats.snapshot() == before,
                    "Invalid intervals changed the existing window.")
        stats.reset()
        let empty = stats.snapshot()
        try require(empty.count == 0 && empty.meanMs == nil && empty.maxMs == nil &&
                    empty.p50UpperBoundMs == nil && empty.p95UpperBoundMs == nil &&
                    empty.p99UpperBoundMs == nil && empty.over16_667Ms == 0 &&
                    empty.over25Ms == 0 && empty.over50Ms == 0,
                    "Reset left stale samples or estimates in the next window.")
    }
}

do {
    try TimingStatisticsTests.run()
    print("PASS 3 timing-statistics checks: quantile bounds, idle gaps, invalid/reset")
    try AsyncVideoLogTests.run()
    print("PASS 3 async log checks: ordered close, bounded backlog, failed open")
    testRendererRates()
    testRendererReset()
    testRendererInvalidSamples()
#if canImport(CoreMedia) && canImport(CoreVideo)
    testSampleAttachments()
#else
    print("SKIP CoreMedia attachment runtime check: requires an Apple runtime")
#endif
    print("All available iPad performance helper checks passed.")
} catch {
    fatalError("iPad performance helper test failed: \(error)")
}
