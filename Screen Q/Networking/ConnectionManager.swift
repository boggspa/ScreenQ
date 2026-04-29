//
//  ConnectionManager.swift
//  Screen Q
//
//  Owns NWConnections and pumps them through the FrameStreamDecoder. Each
//  connection — whether opened by a viewer dialing a host or accepted by
//  the host's listener — is wrapped in a `ScreenQConnection` actor so we
//  can send/receive messages with structured concurrency.
//

import Foundation
import Network

/// Identity of a single peer connection.
typealias ConnectionID = UUID

/// Inbound message routed to the app layer.
nonisolated enum InboundMessage: Sendable {
    case hello(HelloMessage)
    case helloAck(HelloAckMessage)
    case pairingRequest(PairingRequestMessage)
    case pairingApproved(PairingApprovedMessage)
    case pairingRejected(PairingRejectedMessage)
    case videoFormat(VideoFormat)
    case videoFrame(VideoFrameMeta, Data)
    case cursorUpdate(CursorUpdateMessage)
    case inputEvent(RemoteInputEvent)
    case clipboardOffer(ClipboardOfferMessage)
    case clipboardRequest(ClipboardRequestMessage)
    case clipboardData(ClipboardDataMessage)
    case audioFormat(AudioFormatMessage)
    case audioFrame(Data)
    case displayList(DisplayListMessage)
    case displaySwitch(DisplaySwitchMessage)
    case reconnectToken(ReconnectTokenMessage)
    case fileOffer(FileOfferMessage)
    case fileAccept(FileAcceptMessage)
    case fileReject(FileRejectMessage)
    case fileChunk(FileChunkMessage)
    case fileComplete(FileCompleteMessage)
    case remoteCommand(RemoteCommandMessage)
    case commandOutput(CommandOutputMessage)
    case systemAction(SystemActionMessage)
    case systemActionResult(SystemActionResultMessage)
    case systemReportRequest(SystemReportRequestMessage)
    case systemReport(SystemReportMessage)
    case packageInstallReq(PackageInstallRequestMessage)
    case packageInstallResult(PackageInstallResultMessage)
    case streamQuality(StreamQualityMessage)
    case ping(PingMessage)
    case pong(PongMessage)
    case stats(StatsMessage)
    case error(ErrorMessage)
    case endSession(EndSessionMessage)
    case unknown(MessageType)
}

actor ConnectionManager {

    private(set) var connections: [ConnectionID: ScreenQConnection] = [:]

    func adopt(_ connection: NWConnection, role: ScreenQConnection.Role) -> ScreenQConnection {
        let id = UUID()
        let wrapper = ScreenQConnection(id: id, connection: connection, role: role)
        connections[id] = wrapper
        Task { await wrapper.start() }
        return wrapper
    }

    func dial(host: String, port: UInt16) async throws -> ScreenQConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        return adopt(connection, role: .viewer)
    }

    func dial(_ endpoint: NWEndpoint) async throws -> ScreenQConnection {
        let connection = NWConnection(to: endpoint, using: .tcp)
        return adopt(connection, role: .viewer)
    }

    func remove(_ id: ConnectionID) {
        if let conn = connections.removeValue(forKey: id) {
            Task { await conn.stop() }
        }
    }

    func closeAll() {
        for (_, conn) in connections {
            Task { await conn.stop() }
        }
        connections.removeAll()
    }
}

/// Wraps a single NWConnection. Owns the read loop and the FrameStreamDecoder.
actor ScreenQConnection {

    enum Role { case host, viewer }

    let id: ConnectionID
    let role: Role
    private let connection: NWConnection
    private let decoder = FrameStreamDecoder()
    private var sendSequence: UInt64 = 0
    private var inboundContinuation: AsyncStream<InboundMessage>.Continuation?
    private var pendingInboundMessages: [InboundMessage] = []
    private var pendingSends: [PendingSend] = []
    private var sendInProgress = false
    private let maxQueuedVideoFrames = 2
    private var droppedQueuedVideoFrames = 0
    private(set) var isOpen = false
    private(set) var lastError: Error?

    // Encryption (nil = plaintext)
    private var keyMaterial: SecureSessionKeyMaterial?
    private var sendNonce = NonceCounter()
    private var recvNonce = NonceCounter()

    init(id: ConnectionID, connection: NWConnection, role: Role) {
        self.id = id
        self.connection = connection
        self.role = role
    }

    private enum SendKind {
        case control
        case video(isKeyFrame: Bool)

        var isVideo: Bool {
            if case .video = self { return true }
            return false
        }

        var isNonKeyVideo: Bool {
            if case .video(let isKeyFrame) = self { return !isKeyFrame }
            return false
        }
    }

    private struct PendingSend {
        let data: Data
        let kind: SendKind
        let completion: CheckedContinuation<Void, Error>?
    }

    /// Enable encryption after key exchange completes.
    func enableEncryption(_ material: SecureSessionKeyMaterial) {
        self.keyMaterial = material
        self.sendNonce = NonceCounter()
        self.recvNonce = NonceCounter()
        Logger.shared.info("Encryption enabled for connection \(id) (peer: \(material.peerFingerprint.prefix(16))...)")
    }

    func inboundMessages() -> AsyncStream<InboundMessage> {
        AsyncStream { continuation in
            self.inboundContinuation = continuation
            for message in self.pendingInboundMessages {
                continuation.yield(message)
            }
            self.pendingInboundMessages.removeAll()
            continuation.onTermination = { _ in
                Task { await self.stop() }
            }
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        isOpen = true
        scheduleReceive()
    }

    func stop() {
        connection.cancel()
        isOpen = false
        let queued = pendingSends
        pendingSends.removeAll()
        sendInProgress = false
        for item in queued {
            item.completion?.resume(throwing: CancellationError())
        }
        inboundContinuation?.finish()
        inboundContinuation = nil
    }

    func sendJSON<T: Encodable>(_ type: MessageType, _ message: T) async throws {
        sendSequence &+= 1
        let frame = try FrameCodec.encodeJSONMessage(type: type, sequence: sendSequence, message: message)
        try await enqueueSend(try maybeEncryptFrame(frame), kind: .control, waitForCompletion: true)
    }

    func sendVideoFrame(meta: VideoFrameMeta, payload: Data) async throws {
        guard acceptIncomingVideoFrame(isKeyFrame: meta.isKeyFrame) else { return }
        sendSequence &+= 1
        let frame = try FrameCodec.encodeVideoFrame(sequence: sendSequence, meta: meta, payload: payload)
        try await enqueueSend(try maybeEncryptFrame(frame), kind: .video(isKeyFrame: meta.isKeyFrame), waitForCompletion: false)
    }

    /// Send raw audio frame bytes.
    func sendAudioFrame(_ payload: Data) async throws {
        sendSequence &+= 1
        let header = ScreenQHeader(type: .audioFrame, sequence: sendSequence, bodyLength: UInt32(payload.count))
        var data = FrameCodec.encodeHeader(header)
        data.append(payload)
        try await enqueueSend(try maybeEncryptFrame(data), kind: .control, waitForCompletion: true)
    }

    private func maybeEncryptFrame(_ data: Data) throws -> Data {
        guard let km = keyMaterial else { return data }
        guard data.count >= ScreenQProtocol.headerSize else {
            throw SecureSessionError.sealFailed
        }
        let header = try FrameCodec.decodeHeader(data.prefix(ScreenQProtocol.headerSize))
        if plaintextAllowed(for: header.type) {
            return data
        }
        let body = data.subdata(in: ScreenQProtocol.headerSize..<data.count)
        do {
            let sealedBody = try SecureSessionCipher.seal(body, key: km.outboundKey, nonce: sendNonce.next())
            var encryptedHeader = header
            encryptedHeader.flags |= ScreenQProtocol.Flags.encryptedBody
            encryptedHeader.bodyLength = UInt32(sealedBody.count)
            var out = FrameCodec.encodeHeader(encryptedHeader)
            out.append(sealedBody)
            return out
        } catch {
            Logger.shared.error("Encryption seal failed: \(error)")
            throw SecureSessionError.sealFailed
        }
    }

    private func decryptFrameIfNeeded(_ frame: DecodedFrame) throws -> DecodedFrame {
        let encrypted = (frame.header.flags & ScreenQProtocol.Flags.encryptedBody) != 0
        guard encrypted else {
            if keyMaterial != nil && !plaintextAllowed(for: frame.header.type) {
                throw SecureSessionError.openFailed
            }
            return frame
        }
        guard let km = keyMaterial else {
            throw SecureSessionError.openFailed
        }
        do {
            let body = try SecureSessionCipher.open(frame.body, key: km.inboundKey)
            var header = frame.header
            header.flags &= ~ScreenQProtocol.Flags.encryptedBody
            header.bodyLength = UInt32(body.count)
            return DecodedFrame(header: header, body: body)
        } catch {
            Logger.shared.error("Encryption open failed: \(error)")
            throw SecureSessionError.openFailed
        }
    }

    private func plaintextAllowed(for type: MessageType) -> Bool {
        type == .hello || type == .helloAck
    }

    private func enqueueSend(_ data: Data, kind: SendKind, waitForCompletion: Bool) async throws {
        guard isOpen else { throw CancellationError() }
        if waitForCompletion {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                pendingSends.append(PendingSend(data: data, kind: kind, completion: cont))
                startNextSendIfNeeded()
            }
        } else {
            pendingSends.append(PendingSend(data: data, kind: kind, completion: nil))
            startNextSendIfNeeded()
        }
    }

    private func acceptIncomingVideoFrame(isKeyFrame: Bool) -> Bool {
        if isKeyFrame {
            dropQueuedVideoFrames()
            return true
        }

        var queuedVideoCount = pendingSends.filter { $0.kind.isVideo }.count
        while queuedVideoCount >= maxQueuedVideoFrames {
            guard let index = pendingSends.firstIndex(where: { $0.kind.isNonKeyVideo }) else {
                droppedQueuedVideoFrames &+= 1
                logVideoDropIfNeeded()
                return false
            }
            pendingSends.remove(at: index).completion?.resume(throwing: CancellationError())
            queuedVideoCount -= 1
            droppedQueuedVideoFrames &+= 1
        }
        return true
    }

    private func dropQueuedVideoFrames() {
        var kept: [PendingSend] = []
        kept.reserveCapacity(pendingSends.count)
        for item in pendingSends {
            if item.kind.isVideo {
                item.completion?.resume(throwing: CancellationError())
                droppedQueuedVideoFrames &+= 1
            } else {
                kept.append(item)
            }
        }
        pendingSends = kept
        logVideoDropIfNeeded()
    }

    private func logVideoDropIfNeeded() {
        if droppedQueuedVideoFrames > 0 && droppedQueuedVideoFrames % 30 == 0 {
            Logger.shared.debug("Dropped \(droppedQueuedVideoFrames) queued video frames on \(id) to keep latency bounded")
        }
    }

    private func startNextSendIfNeeded() {
        guard !sendInProgress, isOpen, !pendingSends.isEmpty else { return }
        let item = pendingSends.removeFirst()
        sendInProgress = true
        connection.send(content: item.data, completion: .contentProcessed { [weak self] error in
            Task { await self?.finishSend(item: item, error: error) }
        })
    }

    private func finishSend(item: PendingSend, error: NWError?) {
        sendInProgress = false
        if let error {
            lastError = error
            item.completion?.resume(throwing: error)
            Logger.shared.error("Send error: \(error.localizedDescription)")
            stop()
            return
        }
        item.completion?.resume()
        startNextSendIfNeeded()
    }

    // MARK: - Receive loop

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error = error {
            self.lastError = error
            Logger.shared.error("Receive error: \(error.localizedDescription)")
            stop()
            return
        }
        if let data = data, !data.isEmpty {
            decoder.feed(data)
            do {
                while let frame = try decoder.nextFrame() {
                    let inbound = try interpret(frame: decryptFrameIfNeeded(frame))
                    emitInbound(inbound)
                }
            } catch {
                Logger.shared.error("Frame decode error: \(error)")
                emitInbound(.error(ErrorMessage(code: "decode", message: "\(error)")))
                stop()
                return
            }
        }
        if isComplete {
            stop()
            return
        }
        if isOpen {
            scheduleReceive()
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            Logger.shared.info("Connection ready: \(connection.endpoint)")
        case .failed(let err):
            Logger.shared.error("Connection failed: \(err.localizedDescription)")
            lastError = err
            stop()
        case .cancelled:
            isOpen = false
        default:
            break
        }
    }

    private func emitInbound(_ message: InboundMessage) {
        if let continuation = inboundContinuation {
            continuation.yield(message)
        } else {
            pendingInboundMessages.append(message)
            if pendingInboundMessages.count > 256 {
                pendingInboundMessages.removeFirst(pendingInboundMessages.count - 256)
            }
        }
    }

    private func interpret(frame: DecodedFrame) throws -> InboundMessage {
        let dec = JSONDecoder.screenQDefault
        switch frame.header.type {
        case .hello:
            return .hello(try dec.decode(HelloMessage.self, from: frame.body))
        case .helloAck:
            return .helloAck(try dec.decode(HelloAckMessage.self, from: frame.body))
        case .pairingRequest:
            return .pairingRequest(try dec.decode(PairingRequestMessage.self, from: frame.body))
        case .pairingApproved:
            return .pairingApproved(try dec.decode(PairingApprovedMessage.self, from: frame.body))
        case .pairingRejected:
            return .pairingRejected(try dec.decode(PairingRejectedMessage.self, from: frame.body))
        case .videoFormat:
            return .videoFormat(try dec.decode(VideoFormat.self, from: frame.body))
        case .videoFrame:
            let (meta, payload) = try FrameCodec.decodeVideoFrame(body: frame.body)
            return .videoFrame(meta, payload)
        case .inputEvent:
            return .inputEvent(try dec.decode(RemoteInputEvent.self, from: frame.body))
        case .ping:
            return .ping(try dec.decode(PingMessage.self, from: frame.body))
        case .pong:
            return .pong(try dec.decode(PongMessage.self, from: frame.body))
        case .stats:
            return .stats(try dec.decode(StatsMessage.self, from: frame.body))
        case .error:
            return .error(try dec.decode(ErrorMessage.self, from: frame.body))
        case .endSession:
            return .endSession(try dec.decode(EndSessionMessage.self, from: frame.body))
        case .cursorUpdate:
            return .cursorUpdate(try dec.decode(CursorUpdateMessage.self, from: frame.body))
        case .clipboardOffer:
            return .clipboardOffer(try dec.decode(ClipboardOfferMessage.self, from: frame.body))
        case .clipboardRequest:
            return .clipboardRequest(try dec.decode(ClipboardRequestMessage.self, from: frame.body))
        case .clipboardData:
            return .clipboardData(try dec.decode(ClipboardDataMessage.self, from: frame.body))
        case .audioFormat:
            return .audioFormat(try dec.decode(AudioFormatMessage.self, from: frame.body))
        case .audioFrame:
            return .audioFrame(frame.body)
        case .displayList:
            return .displayList(try dec.decode(DisplayListMessage.self, from: frame.body))
        case .displaySwitch:
            return .displaySwitch(try dec.decode(DisplaySwitchMessage.self, from: frame.body))
        case .reconnectToken:
            return .reconnectToken(try dec.decode(ReconnectTokenMessage.self, from: frame.body))
        case .fileOffer:
            return .fileOffer(try dec.decode(FileOfferMessage.self, from: frame.body))
        case .fileAccept:
            return .fileAccept(try dec.decode(FileAcceptMessage.self, from: frame.body))
        case .fileReject:
            return .fileReject(try dec.decode(FileRejectMessage.self, from: frame.body))
        case .fileChunk:
            return .fileChunk(try dec.decode(FileChunkMessage.self, from: frame.body))
        case .fileComplete:
            return .fileComplete(try dec.decode(FileCompleteMessage.self, from: frame.body))
        case .remoteCommand:
            return .remoteCommand(try dec.decode(RemoteCommandMessage.self, from: frame.body))
        case .commandOutput:
            return .commandOutput(try dec.decode(CommandOutputMessage.self, from: frame.body))
        case .systemAction:
            return .systemAction(try dec.decode(SystemActionMessage.self, from: frame.body))
        case .systemActionResult:
            return .systemActionResult(try dec.decode(SystemActionResultMessage.self, from: frame.body))
        case .systemReportRequest:
            return .systemReportRequest(try dec.decode(SystemReportRequestMessage.self, from: frame.body))
        case .systemReport:
            return .systemReport(try dec.decode(SystemReportMessage.self, from: frame.body))
        case .packageInstallReq:
            return .packageInstallReq(try dec.decode(PackageInstallRequestMessage.self, from: frame.body))
        case .packageInstallResult:
            return .packageInstallResult(try dec.decode(PackageInstallResultMessage.self, from: frame.body))
        case .streamQuality:
            return .streamQuality(try dec.decode(StreamQualityMessage.self, from: frame.body))
        default:
            return .unknown(frame.header.type)
        }
    }
}
