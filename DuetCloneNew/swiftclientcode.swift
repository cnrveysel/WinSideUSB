import SwiftUI
import Foundation
import Network
import AVFoundation
import VideoToolbox
import Darwin

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - VideoReceiver (TCP SERVER - USB 120Hz)

final class VideoReceiver: NSObject, ObservableObject {
    @Published var status = "PC Bekleniyor..."
    @Published var debug  = "CFG: - | SPS: - | PPS: -"
    @Published var frames = 0
    @Published var layerInfo = ""
    @Published var logFile = "Log: -"
    @Published var logURL: URL?
    
    private var listener: NWListener?
    private var connection: NWConnection?
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var socketListenerStarted = false
    private let parseQueue = DispatchQueue(label: "com.duet.parse", qos: .userInteractive)
    private var rx = Data()
    private let listenPorts: [UInt16] = [17326, 17325, 17324, 17323, 17322, 17321]
    private var activeListenPort: UInt16 = 0
    
    private var formatDesc: CMVideoFormatDescription?
    private var gotConfig = false
    private var nalHeaderLength = 4
    private var chunkFrameId: UInt32?
    private var chunkExpectedTotal = 0
    private var chunkBuffer = Data()
    
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

    private var logHandle: FileHandle?
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
        logHandle?.closeFile()
        if clientFd >= 0 { Darwin.close(clientFd) }
        if listenFd >= 0 { Darwin.close(listenFd) }
    }
    
    func start() {
        if ProcessInfo.processInfo.environment["WSUSB_USE_NW"] != "1" {
            startSocketListener()
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        
        guard let port = NWEndpoint.Port(rawValue: 8080) else {
            DispatchQueue.main.async { self.status = "Geçersiz Port" }
            return
        }
        
        listener = try? NWListener(using: params, on: port)
        
        guard let listener = listener else {
            DispatchQueue.main.async { self.status = "Listener başlatılamadı, port meşgul olabilir." }
            return
        }
        
        listener.stateUpdateHandler = { [weak self] state in
            print("[NET] Listener: \(state)")
            DispatchQueue.main.async {
                if case .ready = state { self?.status = "Port 8080 - PC bekleniyor..." }
            }
        }
        
        listener.newConnectionHandler = { [weak self] newConn in
            guard let self = self else { return }
            self.connection?.cancel()
            self.connection = newConn
            
            print("[NET] PC connected!")
            DispatchQueue.main.async {
                self.status = "PC baglandi! (USB 120Hz)"
                self.frames = 0
            }
            
            self.rx = Data(capacity: 2 * 1024 * 1024)
            self.gotConfig = false
            self.formatDesc = nil
            self.nalHeaderLength = 4
            self.chunkFrameId = nil
            self.chunkExpectedTotal = 0
            self.chunkBuffer.removeAll(keepingCapacity: true)
            self.frameIndex = 0
            self.enqueueCount = 0
            self.droppedFrames = 0
            self.notReadyStreak = 0
            self.queueRefreshes = 0
            self.waitingForSync = false
            self.firstReceiveLogged = false
            self.firstConfigFailLogged = false
            self.pcHelloBuffer.removeAll(keepingCapacity: true)
            self.sawPcHello = false
            self.openLog()
            
            var receiveStarted = false
            newConn.stateUpdateHandler = { [weak self, weak newConn] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    guard let conn = newConn, !receiveStarted else { return }
                    receiveStarted = true
                    self.receive()
                    self.sendReadyHandshake(on: conn)
                case .failed(_), .cancelled:
                    DispatchQueue.main.async { self.status = "Koptu, bekleniyor..." }
                default:
                    break
                }
            }
            newConn.start(queue: self.parseQueue)
        }
        
        listener.start(queue: parseQueue)
    }

    private func resetForNewConnection() {
        rx = Data(capacity: 2 * 1024 * 1024)
        gotConfig = false
        formatDesc = nil
        nalHeaderLength = 4
        chunkFrameId = nil
        chunkExpectedTotal = 0
        chunkBuffer.removeAll(keepingCapacity: true)
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
        openLog()
    }

    private func startSocketListener() {
        guard !socketListenerStarted else { return }
        socketListenerStarted = true

        parseQueue.async { [weak self] in
            self?.runSocketListener()
        }
    }

    private func runSocketListener() {
        var fd: Int32 = -1
        var selectedPort: UInt16 = 0
        var lastError: Int32 = 0

        for port in listenPorts {
            let candidate = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            if candidate < 0 {
                lastError = Darwin.errno
                continue
            }

            var yes: Int32 = 1
            setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
#if os(iOS)
            setsockopt(candidate, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
#endif

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: 0)

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(candidate, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0 {
                fd = candidate
                selectedPort = port
                break
            }

            lastError = Darwin.errno
            Darwin.close(candidate)
        }

        guard fd >= 0 else {
            DispatchQueue.main.async { self.status = "Portlar dolu: \(lastError)" }
            return
        }

        guard Darwin.listen(fd, 2) == 0 else {
            let err = Darwin.errno
            Darwin.close(fd)
            DispatchQueue.main.async { self.status = "Listen hatasi: \(err)" }
            return
        }

        listenFd = fd
        activeListenPort = selectedPort
        DispatchQueue.main.async {
            self.status = "Port \(selectedPort) acik - PC bekleniyor..."
            self.debug = "BSD socket listener v2"
        }

        while true {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let cfd = withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &len)
                }
            }
            if cfd < 0 {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            if clientFd >= 0 {
                Darwin.close(clientFd)
            }
            clientFd = cfd

            var one: Int32 = 1
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            resetForNewConnection()

            DispatchQueue.main.async {
                self.status = "PC baglandi! (USB socket)"
                self.frames = 0
                self.debug = "USB accept OK"
            }

            sendReadyHandshakeSocket(cfd)
            receiveSocketLoop(cfd)

            if clientFd == cfd {
                clientFd = -1
            }
            Darwin.close(cfd)
            DispatchQueue.main.async { self.status = "Koptu, bekleniyor..." }
        }
    }

    private func sendReadyHandshakeSocket(_ fd: Int32) {
        let bytes = Array("WSUSB_READY2\n".utf8)
        _ = bytes.withUnsafeBytes {
            Darwin.send(fd, $0.baseAddress, bytes.count, 0)
        }
        DispatchQueue.main.async {
            self.debug = "READY2 sent"
            self.status = "Hazir - PC yayini bekleniyor..."
        }
    }

    private func receiveSocketLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 512 * 1024)
        while true {
            let capacity = buffer.count
            let n = buffer.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress, capacity, 0)
            }
            if n <= 0 { break }

            let d = Data(buffer.prefix(n))
            handleIncomingData(d)
            logStatsIfNeeded()
        }
    }

    private func handleIncomingData(_ d: Data) {
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
        guard displayLayer != nil else {
            guard attempt < 40 else {
                DispatchQueue.main.async { self.status = "Video layer hazir degil" }
                return
            }
            parseQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.sendReadyHandshake(on: conn, attempt: attempt + 1)
            }
            return
        }

        let ready = Data("WSUSB_READY2\n".utf8)
        conn.send(content: ready, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if error == nil {
                DispatchQueue.main.async {
                    self.status = "Hazir - PC yayini bekleniyor..."
                }
            } else {
                DispatchQueue.main.async {
                    self.status = "Hazirlik sinyali gonderilemedi"
                }
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
        logHandle?.closeFile()
        logHandle = nil
        logStart = ProcessInfo.processInfo.systemUptime
        lastLog = logStart
        resetLogCounters()

        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let name = "duet_rx_\(Int(Date().timeIntervalSince1970)).csv"
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            DispatchQueue.main.async {
                self.logURL = nil
                self.logFile = "Log: olusturulamadi"
            }
            return
        }
        logHandle = handle
        writeLogLine("t,rx_bytes,packets,payload_bytes,max_payload,rx_buffer_max,enqueued,idr,not_ready,sync_drops,renderer_failed,queue_refresh,invalid_packets,total_enqueued,total_drops,total_refresh,waiting_for_sync,renderer_status\n")

        DispatchQueue.main.async {
            self.logURL = url
            self.logFile = "Log: \(name)"
        }
    }

    private func writeLogLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        logHandle?.write(data)
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

    private func logStatsIfNeeded(renderer: AVSampleBufferVideoRenderer? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLog >= 1.0 else { return }

        let rendererStatus: String
        if let r = renderer {
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
        writeLogLine(String(format: "%.3f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%@\n",
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
                            rendererStatus))
        logHandle?.synchronizeFile()
        resetLogCounters()
        lastLog = now
    }
    
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                if !self.firstReceiveLogged {
                    self.firstReceiveLogged = true
                    let preview = d.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
                    DispatchQueue.main.async {
                        self.status = "PC verisi geldi"
                        self.debug = "RX \(d.count)b | \(preview)"
                    }
                }
                self.rxBytesLog += d.count
                let streamData = self.stripPCHandshake(d)
                guard !streamData.isEmpty else {
                    self.logStatsIfNeeded()
                    self.receive()
                    return
                }
                self.rx.append(streamData)
                if self.rx.count > self.rxBufferMaxLog { self.rxBufferMaxLog = self.rx.count }
                self.parsePackets()
            }
            self.logStatsIfNeeded()
            if isComplete || error != nil {
                DispatchQueue.main.async { self.status = "Koptu, bekleniyor..." }
                return
            }
            self.receive()
        }
    }
    
    private func parsePackets() {
        var offset = 0
        while rx.count - offset >= 4 {
            let len = Int(UInt32(rx[offset]) << 24 | UInt32(rx[offset+1]) << 16 | UInt32(rx[offset+2]) << 8 | UInt32(rx[offset+3]))
            let total = 4 + len
            guard len > 0, len < 10_000_000 else {
                invalidPacketLog += 1
                rx.removeAll(keepingCapacity: true)
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
                    DispatchQueue.main.async {
                        self.displayLayer?.sampleBufferRenderer.flush()
                        self.debug = "CFG OK | 2732x2048 120Hz"
                        self.status = "Yayin aliniyor..."
                    }
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
            resetChunkFrame()
            enqueueFrame(frame)
        }
        return true
    }
    
    // MARK: - Enqueue
    
    private func enqueueFrame(_ payload: Data) {
        guard let format = formatDesc else { return }
        let payloadIsAnnexB = looksLikeAnnexB(payload)
        let au = payloadIsAnnexB ? annexBToAVCC(payload) : payload
        let isIDR = containsIDR(au, nalHeaderLength: payloadIsAnnexB ? 4 : nalHeaderLength)
        guard let layer = self.displayLayer else { return }
        let renderer = layer.sampleBufferRenderer
        if isIDR { idrLog += 1 }

        if renderer.status == .failed {
            rendererFailedLog += 1
            renderer.flush()
            waitingForSync = true
        }

        if waitingForSync {
            guard isIDR else {
                droppedFrames += 1
                syncDropLog += 1
                reportDropsIfNeeded()
                logStatsIfNeeded(renderer: renderer)
                return
            }
            renderer.flush()
            waitingForSync = false
            notReadyStreak = 0
            frameIndex = 0
        }

        if !renderer.isReadyForMoreMediaData {
            notReadyLog += 1
            notReadyStreak += 1
            if isIDR && notReadyStreak >= 3 {
                renderer.flush()
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
        CMSetAttachment(s, key: kCMSampleAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        if !isIDR {
            CMSetAttachment(s, key: kCMSampleAttachmentKey_NotSync,
                            value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        renderer.enqueue(s)
        self.enqueueCount += 1
        self.enqueuedLog += 1
        if self.enqueueCount % 60 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.frames = self?.enqueueCount ?? 0
                self?.status = "Streaming"
            }
        }
        logStatsIfNeeded(renderer: renderer)
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

// MARK: - Full-screen video UIView

final class VideoLayerUIView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill   // fill the whole screen
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        layer.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
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
        return v
    }
    func updateUIView(_ uiView: VideoLayerUIView, context: Context) {}
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

// MARK: - Main View

struct MainView: View {
    @StateObject var rx = VideoReceiver()
    @State private var showOverlay = true
    @State private var hideTask: DispatchWorkItem?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Full-screen video
            VideoView(rx: rx).ignoresSafeArea()
            
            // Tap anywhere to toggle overlay
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleOverlay() }
            
            // Status overlay — auto-hides after 3 s
            if showOverlay {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rx.status)
                        .foregroundColor(.green)
                        .font(.caption2.monospaced())
                    Text(rx.debug)
                        .foregroundColor(.yellow)
                        .font(.caption2.monospaced())
                    Text("Frames: \(rx.frames)")
                        .foregroundColor(.white)
                        .font(.caption2.monospaced())
                    Text(rx.logFile)
                        .foregroundColor(.cyan)
                        .font(.caption2.monospaced())
                    if let logURL = rx.logURL {
                        ShareLink(item: logURL) {
                            Text("Share Log")
                                .foregroundColor(.cyan)
                                .font(.caption2.monospaced())
                        }
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.leading, 12)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: showOverlay)
            }
        }
        // Hide system chrome (status bar, home indicator)
        .statusBar(hidden: true)
        .ignoresSafeArea()
        .onAppear {
            rx.start()
            scheduleHide()   // auto-hide overlay after 3 s on launch
        }
    }
    
    private func toggleOverlay() {
        withAnimation { showOverlay.toggle() }
        if showOverlay { scheduleHide() }
    }
    
    private func scheduleHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation { showOverlay = false }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }
}
