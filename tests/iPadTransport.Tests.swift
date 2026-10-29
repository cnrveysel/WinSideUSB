import Foundation
import Dispatch
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// Compiled with the listener extracted from swiftclientcode.swift. No UIKit,
// renderer, USB device, privileged port, or replacement transport is involved.
struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure(description: message) }
}

func closeSocket(_ fd: Int32) {
    if fd >= 0 { _ = close(fd) }
}

func makeSocket() throws -> Int32 {
#if os(Linux)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
#endif
    try check(fd >= 0, "socket() failed: \(errno)")
#if !os(Linux)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
#endif
    return fd
}

func address(_ port: UInt16, host: String = "127.0.0.1") -> sockaddr_in {
    var value = sockaddr_in()
#if !os(Linux)
    value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
    value.sin_family = sa_family_t(AF_INET)
    value.sin_port = port.bigEndian
    _ = host.withCString { inet_pton(AF_INET, $0, &value.sin_addr) }
    return value
}

func withAddress<T>(_ value: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &value) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

func occupiedPort() throws -> (Int32, UInt16) {
    let fd = try makeSocket()
    var value = address(0)
    guard withAddress(&value, { bind(fd, $0, $1) }) == 0, listen(fd, 8) == 0 else {
        closeSocket(fd)
        throw TestFailure(description: "Could not reserve test port: \(errno)")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &value) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    try check(result == 0, "getsockname failed")
    return (fd, UInt16(bigEndian: value.sin_port))
}

func freePort() throws -> UInt16 {
    let (fd, port) = try occupiedPort()
    closeSocket(fd)
    return port
}

func connectClient(_ port: UInt16, host: String = "127.0.0.1") throws -> Int32 {
    let fd = try makeSocket()
    var value = address(port, host: host)
    guard withAddress(&value, { connect(fd, $0, $1) }) == 0 else {
        closeSocket(fd)
        throw TestFailure(description: "Connect to \(host):\(port) failed: \(errno)")
    }
    return fd
}

func readable(_ fd: Int32, milliseconds: Int32) throws -> Bool {
    var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let result = poll(&event, 1, milliseconds)
    if result < 0 && errno == EINTR { return try readable(fd, milliseconds: milliseconds) }
    try check(result >= 0, "poll() failed: \(errno)")
    return result > 0
}

func readReady(_ fd: Int32) throws {
    var result = Data()
    let deadline = Date().addingTimeInterval(3)
    while !result.contains(0x0A), Date() < deadline {
        guard try readable(fd, milliseconds: 100) else { continue }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = recv(fd, &bytes, bytes.count, 0)
        try check(count > 0, "Connection closed before READY2")
        result.append(contentsOf: bytes.prefix(count))
    }
    try check(result == Data("WSUSB_READY2\n".utf8), "READY2 bytes differ: \(result as NSData)")
}

func sendAll(_ fd: Int32, _ bytes: Data) throws {
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
#if os(Linux)
            let count = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, Int32(MSG_NOSIGNAL))
#else
            let count = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
#endif
            if count < 0 && errno == EINTR { continue }
            try check(count > 0, "send() failed: \(errno)")
            offset += count
        }
    }
}

final class Probe {
    let queue = DispatchQueue(label: "com.winsideusb.transport-tests.\(UUID().uuidString)")
    let lock = NSCondition()
    let listener: BSDVideoListener
    var ports: [UInt16] = []
    var connected = 0
    var disconnected = 0
    var failures: [String] = []
    var bytes = Data()

    init(_ candidates: [UInt16]) {
        listener = BSDVideoListener(queue: queue, ports: candidates)
        listener.onListening = { [weak self] port in self?.record { $0.ports.append(port) } }
        listener.onConnected = { [weak self] in self?.record { $0.connected += 1 } }
        listener.onDisconnected = { [weak self] _ in self?.record { $0.disconnected += 1 } }
        listener.onFailure = { [weak self] error in self?.record { $0.failures.append(error) } }
        listener.onData = { [weak self] data in self?.record { $0.bytes.append(data) } }
    }

    func record(_ body: (Probe) -> Void) {
        lock.lock()
        body(self)
        lock.broadcast()
        lock.unlock()
    }

    func wait(_ message: String, timeout: TimeInterval = 4, _ predicate: (Probe) -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while !predicate(self) {
            if !lock.wait(until: deadline) {
                throw TestFailure(description: "Timed out: \(message); failures=\(failures)")
            }
        }
    }

    func snapshot<T>(_ body: (Probe) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    func start() { queue.sync { listener.start() } }
    func stop() { queue.sync { listener.stop() } }
    func retry() { queue.sync { listener.retry() } }
    func restart() { queue.sync { listener.stop(); listener.start() } }
}

func testSplitAndLargeDelivery() throws {
    let port = try freePort()
    let probe = Probe([port])
    probe.start()
    defer { probe.stop() }
    try probe.wait("listener ready") { $0.ports.last == port }
    let fd = try connectClient(port)
    defer { closeSocket(fd) }
    try readReady(fd)
    let hello = Data("WSUSB_HELLO2\n".utf8)
    var expected = hello
    expected.append(Data((0..<(2 * 1024 * 1024 + 37)).map { UInt8(truncatingIfNeeded: $0) }))
    // Deliberately split the textual handshake and length-like bytes over writes.
    for byte in hello {
        try sendAll(fd, Data([byte]))
        Thread.sleep(forTimeInterval: 0.002)
    }
    var offset = hello.count
    for size in [1, 3, 7, 64, 1023, 65537] {
        let end = min(expected.count, offset + size)
        try sendAll(fd, expected.subdata(in: offset..<end))
        offset = end
    }
    try sendAll(fd, expected.subdata(in: offset..<expected.count))
    try probe.wait("all split/large data delivered byte-for-byte") { $0.bytes.count >= expected.count }
    try check(probe.snapshot { $0.bytes == expected }, "Transport reordered, duplicated, or truncated data")
    try check(probe.snapshot { $0.connected == 1 }, "Unexpected connection count")
}

func testEOFAndReplacement() throws {
    let port = try freePort()
    let probe = Probe([port])
    probe.start()
    defer { probe.stop() }
    try probe.wait("listener ready") { !$0.ports.isEmpty }
    let first = try connectClient(port)
    try readReady(first)
    closeSocket(first)
    try probe.wait("EOF handled") { $0.disconnected >= 1 }

    let stale = try connectClient(port)
    defer { closeSocket(stale) }
    try readReady(stale)
    // Keep the previous peer open and silent: this formerly blocked accept forever.
    let replacement = try connectClient(port)
    defer { closeSocket(replacement) }
    try readReady(replacement)
    try probe.wait("replacement accepted") { $0.connected == 3 }
    let marker = Data("replacement-is-live".utf8)
    try sendAll(replacement, marker)
    try probe.wait("replacement data delivered") { $0.bytes == marker }
    let staleReadable = try readable(stale, milliseconds: 1000)
    try check(staleReadable, "Superseded client was left open")
    var byte: UInt8 = 0
    try check(recv(stale, &byte, 1, 0) <= 0, "Superseded client can still receive")
}

func testIdleAndIdempotentStart() throws {
    let port = try freePort()
    let probe = Probe([port])
    probe.start()
    probe.start()
    defer { probe.stop() }
    try probe.wait("listener ready") { !$0.ports.isEmpty }
    let fd = try connectClient(port)
    defer { closeSocket(fd) }
    try readReady(fd)
    // Static Windows desktops can have no packets; silence is not disconnection.
    Thread.sleep(forTimeInterval: 3)
    try check(probe.snapshot { $0.connected == 1 && $0.disconnected == 0 }, "Idle stream was disconnected")
    try sendAll(fd, Data("after-idle".utf8))
    try probe.wait("idle client remains usable") { $0.bytes == Data("after-idle".utf8) }
    try check(probe.snapshot { $0.ports.count == 1 && $0.failures.isEmpty }, "Repeated start reopened listener")
}

func testStopRestartAndRapidCycles() throws {
    let port = try freePort()
    let probe = Probe([port])
    probe.start()
    defer { probe.stop() }
    try probe.wait("first listener ready") { $0.ports.count == 1 }
    let active = try connectClient(port)
    try readReady(active)
    probe.stop()
    let stoppedReadable = try readable(active, milliseconds: 1000)
    try check(stoppedReadable, "Stop left active peer open")
    closeSocket(active)
    probe.stop()
    probe.start()
    try probe.wait("same port restarted") { $0.ports.count >= 2 }
    for cycle in 0..<30 {
        let fd = try connectClient(port)
        try readReady(fd)
        try sendAll(fd, Data([UInt8(cycle)]))
        try probe.wait("cycle \(cycle) data delivered") { $0.bytes.count >= cycle + 1 }
        closeSocket(fd)
        try probe.wait("cycle \(cycle) disconnected") { $0.disconnected >= cycle + 1 }
    }
    try check(probe.snapshot { $0.bytes == Data((0..<30).map { UInt8($0) }) }, "Rapid cycle data leaked across sessions")
    // Stop while accept is idle, then start once more to check source teardown.
    probe.restart()
    try probe.wait("idle listener restarted") { $0.ports.count >= 3 }
    let final = try connectClient(port)
    defer { closeSocket(final) }
    try readReady(final)
}

func testOccupiedFallbackAndRetry() throws {
    let (blocker, busyPort) = try occupiedPort()
    var blockerToClose = blocker
    defer { closeSocket(blockerToClose) }
    let fallback = try freePort()
    let probe = Probe([busyPort, fallback])
    probe.start()
    defer { probe.stop() }
    try probe.wait("fallback listener ready") { !$0.ports.isEmpty }
    try check(probe.snapshot { $0.ports.last == fallback }, "Listener failed to select free fallback port")
    let fd = try connectClient(fallback)
    try readReady(fd)
    closeSocket(fd)
    probe.stop()

    let failed = Probe([busyPort])
    failed.start()
    defer { failed.stop() }
    try failed.wait("occupied-port failure reported") { !$0.failures.isEmpty }
    closeSocket(blocker)
    blockerToClose = -1
    failed.retry()
    try failed.wait("retry recovered after port freed") { $0.ports.last == busyPort }
    let recovered = try connectClient(busyPort)
    defer { closeSocket(recovered) }
    try readReady(recovered)
}

func testEarlyPeerClose() throws {
    let port = try freePort()
    let probe = Probe([port])
    probe.start()
    defer { probe.stop() }
    try probe.wait("listener ready") { !$0.ports.isEmpty }
    for _ in 0..<40 {
        let fd = try connectClient(port)
        // RST before/while READY is sent must not terminate the process (SIGPIPE).
        var reset = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
        closeSocket(fd)
        Thread.sleep(forTimeInterval: 0.003)
    }
    let healthy = try connectClient(port)
    defer { closeSocket(healthy) }
    try readReady(healthy)
    try sendAll(healthy, Data("still-alive".utf8))
    try probe.wait("listener survived early closes") { $0.bytes == Data("still-alive".utf8) }
}

func testLoopbackOnly() throws {
    let port = try freePort()
    let probe = Probe([port])
    probe.start()
    defer { probe.stop() }
    try probe.wait("listener ready") { !$0.ports.isEmpty }
    let healthy = try connectClient(port)
    defer { closeSocket(healthy) }
    try readReady(healthy)
    // 127/8 is local on Linux, but binding 127.0.0.1 excludes 127.0.0.2. A
    // wildcard listener incorrectly accepts both, exposing the USB-only server.
#if os(Linux)
    let fd = try makeSocket()
    defer { closeSocket(fd) }
    var other = address(port, host: "127.0.0.2")
    let result = withAddress(&other) { connect(fd, $0, $1) }
    try check(result != 0, "Listener bound wildcard instead of 127.0.0.1")
#endif
}

let tests: [(String, () throws -> Void)] = [
    ("READY2 and arbitrary split/large delivery", testSplitAndLargeDelivery),
    ("EOF and stale-peer replacement", testEOFAndReplacement),
    ("Static idle stream and idempotent start", testIdleAndIdempotentStart),
    ("Stop/restart and 30 rapid connection cycles", testStopRestartAndRapidCycles),
    ("Occupied fallback port and retry recovery", testOccupiedFallbackAndRetry),
    ("40 peers closing before READY", testEarlyPeerClose),
    ("Listener restricted to loopback", testLoopbackOnly),
]
var failures = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS: \(name)")
    } catch {
        failures += 1
        fputs("FAIL: \(name): \(error)\n", stderr)
    }
}
print("\(tests.count - failures)/\(tests.count) iPad transport tests passed")
exit(failures == 0 ? 0 : 1)
