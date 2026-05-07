//
//  RemoteScreenView.swift
//  Screen Q
//
//  The actual viewer surface: handshake -> pairing code prompt -> live
//  remote screen with stats overlay and (where allowed) input controls.
//

import SwiftUI
import Network
import Combine

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ViewerSession: ObservableObject {

    let connection: ScreenQConnection
    let peerLabel: String
    private let endpoint: NWEndpoint?
    let renderer = RemoteScreenRenderer()
    let inputMapper = InputMappingService()
    let stats = TransportStats()
    let cursorState = CursorOverlayState()
    let audioPlayer = AudioPlayerService()
    let fileTransfer = FileTransferService()
    let terminalState = RemoteTerminalState()
    let reportState = SystemReportState()
    let recorder = SessionRecorder()
    let controlPreferenceScope: ViewerControlPreferenceScope

    @Published var phase: SessionState = .handshake
    @Published var pairingPrompt: String = ""
    @Published var hostCapabilities: Capabilities = .viewerOnly
    @Published var grantedPermissions: PermissionSet = .standard
    @Published var fitMode: Bool = true
    @Published var remoteDisplays: [DisplayInfo] = []
    @Published var activeDisplayID: UInt32 = 0
    @Published var shareTargets: [ShareTargetInfo] = []
    @Published var activeShareTargetID: String?
    @Published var encryptionEnabled: Bool = false
    @Published var encryptionStatusKnown: Bool = false
    @Published private(set) var controlChannelActive: Bool = false

    private weak var app: AppState?
    private var secureSessionFactory: SecureSessionFactory?
    private var localEphemeralPublicKey: String?
    private var localPeerID: UUID?
    private var localIdentityFingerprint: String?
    private var lastViewportHint: ViewerViewportMessage?
    private var lastViewportHintSentAt: Date = .distantPast
    private var latencyProbeTask: Task<Void, Never>?
    private var statsReportTask: Task<Void, Never>?
    private var hostClockOffsetSeconds: TimeInterval?
    private var hostClockOffsetUpdatedAt: Date?
    private var approvedSessionID: UUID?
    private var controlConnection: ScreenQConnection?
    private var controlChannelTask: Task<Void, Never>?
    private var handshakeWatchdogTask: Task<Void, Never>?
    private var firstFrameWatchdogTask: Task<Void, Never>?
    private var didReceiveFirstRenderableFrame = false

    init(
        connection: ScreenQConnection,
        peerLabel: String,
        app: AppState,
        endpoint: NWEndpoint? = nil,
        controlPreferenceScope: ViewerControlPreferenceScope? = nil
    ) {
        self.connection = connection
        self.peerLabel = peerLabel
        self.endpoint = endpoint
        self.app = app
        self.controlPreferenceScope = controlPreferenceScope ?? ViewerControlPreferenceScope(
            connectionProtocol: .screenQ,
            host: peerLabel,
            port: ScreenQProtocol.defaultPort
        )

        inputMapper.sendEvent = { [weak self] event in
            guard let self else { return }
            let hostAdjustedSentAt = Date().timeIntervalSince1970 + (self.hostClockOffsetSeconds ?? 0)
            let connection = self.controlConnection ?? self.connection
            Task { try? await connection.sendInputEvent(event, sentAt: hostAdjustedSentAt) }
        }
        fileTransfer.sendMessage = { [weak self] type, msg in
            guard let self else { return }
            Task { try? await self.connection.sendJSON(type, msg) }
        }
        terminalState.sendCommand = { [weak self] cmd in
            guard let self else { return }
            Task { try? await self.connection.sendJSON(.remoteCommand, cmd) }
        }
        reportState.requestReport = { [weak self] in
            guard let self else { return }
            let req = SystemReportRequestMessage(requestID: UUID())
            Task { try? await self.connection.sendJSON(.systemReportRequest, req) }
        }
    }

    func beginHandshake() async {
        phase = .handshake
        startHandshakeWatchdog()
        let inbound = await connection.inboundMessages()
        Task {
            for await message in inbound {
                await handle(message)
            }
            stopHandshakeWatchdog()
            stopFirstFrameWatchdog()
            stopLatencyProbes()
            stopStatsReports()
            await stopControlChannel()
            inputMapper.isControlEnabled = false
            inputMapper.cancelPendingInput()
            // Stream ended — if we never got past handshake, the connection was lost.
            if case .handshake = phase {
                let errMsg = await connection.lastError.map { "\($0.localizedDescription)" } ?? "Connection closed before handshake completed"
                phase = .failed(reason: errMsg)
            } else if case .awaitingPairingCode = phase {
                phase = .failed(reason: "Connection lost during pairing")
            } else if case .awaitingHostApproval = phase {
                phase = .failed(reason: "Connection lost while waiting for host approval")
            }
        }

        let secureFactory = SecureSessionFactory()
        let localPublicKey = secureFactory.publicKeyBase64
        secureSessionFactory = secureFactory
        localEphemeralPublicKey = localPublicKey
        let peerID = app?.localDeviceID ?? UUID()
        let displayName = app?.localDeviceName ?? "Viewer"
        localPeerID = peerID
        let proof = DeviceIdentityStore.proof(
            peerID: peerID,
            displayName: displayName,
            ephemeralPublicKey: localPublicKey
        )
        localIdentityFingerprint = proof?.fingerprint

        let hello = HelloMessage(
            peerID: peerID,
            displayName: displayName,
            platform: currentPlatform(),
            appVersion: "1.0",
            capabilities: .viewerOnly,
            ephemeralPublicKey: localPublicKey,
            identityPublicKey: proof?.publicKeyBase64,
            identitySignature: proof?.signatureBase64
        )
        try? await connection.sendJSON(.hello, hello)
    }

    func sendPairingRequest() async {
        guard !pairingPrompt.isEmpty else { return }
        phase = .awaitingHostApproval
        let req = PairingRequestMessage(
            viewerID: app?.localDeviceID ?? UUID(),
            displayName: app?.localDeviceName ?? "Viewer",
            claimedCode: pairingPrompt
        )
        try? await connection.sendJSON(.pairingRequest, req)
    }

    func switchDisplay(_ displayID: UInt32) async {
        let msg = DisplaySwitchMessage(displayID: displayID)
        try? await connection.sendJSON(.displaySwitch, msg)
        activeDisplayID = displayID
    }

    func switchShareTarget(_ targetID: String) async {
        let msg = ShareTargetSwitchMessage(targetID: targetID)
        try? await connection.sendJSON(.shareTargetSwitch, msg)
        activeShareTargetID = targetID
    }

    func updateStreamQuality(_ quality: Double, profile: StreamProfile? = nil) {
        guard encryptionEnabled else { return }
        switch phase {
        case .approved, .streaming, .viewOnly:
            break
        default:
            return
        }
        let baseMessage: StreamQualityMessage
        if let profile {
            baseMessage = StreamQualityMessage(quality: quality, profile: profile)
        } else {
            baseMessage = StreamQualityPreference(quality: quality).nativeMessage
        }
        #if os(iOS)
        let message = baseMessage.cappedForMobileViewer()
        #else
        let message = baseMessage
        #endif
        Task { try? await connection.sendJSON(.streamQuality, message) }
    }

    func updateViewerViewport(_ message: ViewerViewportMessage, force: Bool = false) {
        guard encryptionEnabled else { return }
        switch phase {
        case .approved, .streaming, .viewOnly:
            break
        default:
            return
        }

        let now = Date()
        guard force || shouldSendViewportHint(message, now: now) else { return }
        lastViewportHint = message
        lastViewportHintSentAt = now
        Task { try? await connection.sendJSON(.viewerViewport, message) }
    }

    func tearDown(reason: String) async {
        stopHandshakeWatchdog()
        stopFirstFrameWatchdog()
        stopLatencyProbes()
        stopStatsReports()
        await stopControlChannel()
        inputMapper.isControlEnabled = false
        inputMapper.cancelPendingInput()
        try? await connection.sendJSON(.endSession, EndSessionMessage(reason: reason))
        await connection.stop()
        phase = .ended(reason: reason)
    }

    private func startLatencyProbesIfNeeded() {
        guard latencyProbeTask == nil else { return }
        latencyProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendLatencyProbeIfAllowed()
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
        }
        startStatsReportsIfNeeded()
    }

    private func startStatsReportsIfNeeded() {
        guard statsReportTask == nil else { return }
        statsReportTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendStatsReportIfAllowed()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func startControlChannelIfNeeded(sessionID: UUID) {
        guard controlChannelTask == nil,
              controlConnection == nil,
              let endpoint,
              let app else {
            return
        }
        controlChannelTask = Task { @MainActor [weak self, weak app] in
            guard let self, let app else { return }
            do {
                let connection = try await app.connectionManager.dial(endpoint)
                guard !Task.isCancelled else {
                    await connection.stop()
                    return
                }
                let inbound = await connection.inboundMessages()
                let secureFactory = SecureSessionFactory()
                let localPublicKey = secureFactory.publicKeyBase64
                let peerID = app.localDeviceID
                let displayName = app.localDeviceName
                let proof = DeviceIdentityStore.proof(
                    peerID: peerID,
                    displayName: displayName,
                    ephemeralPublicKey: localPublicKey
                )
                let hello = HelloMessage(
                    peerID: peerID,
                    displayName: displayName,
                    platform: currentPlatform(),
                    appVersion: "1.0",
                    capabilities: .viewerOnly,
                    channel: .control,
                    sessionID: sessionID,
                    ephemeralPublicKey: localPublicKey,
                    identityPublicKey: proof?.publicKeyBase64,
                    identitySignature: proof?.signatureBase64
                )
                try await connection.sendJSON(.hello, hello, waitForCompletion: false)
                guard !Task.isCancelled else {
                    await connection.stop()
                    return
                }

                var didEnableControlChannel = false
                for await message in inbound {
                    guard !Task.isCancelled else { return }
                    switch message {
                    case .helloAck(let ack):
                        guard ack.encryptionEnabled,
                              let hostPublicKey = ack.ephemeralPublicKey else {
                            throw NSError(
                                domain: "ScreenQ.ControlChannel",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Host did not accept encrypted control channel."]
                            )
                        }
                        let material = try secureFactory.deriveKey(
                            peerPublicKeyBase64: hostPublicKey,
                            salt: ScreenQSecureSessionTranscript.salt(
                                viewerID: peerID,
                                hostID: ack.peerID
                            ),
                            info: ScreenQSecureSessionTranscript.info(
                                viewerPublicKey: localPublicKey,
                                hostPublicKey: hostPublicKey
                            ),
                            role: .viewer
                        )
                        await connection.enableEncryption(material)
                        self.controlConnection = connection
                        self.controlChannelActive = true
                        didEnableControlChannel = true
                        Logger.shared.info("Screen Q control channel attached to \(self.peerLabel)")
                    case .pong(let pong):
                        self.updateLatencyOffset(from: pong, receivedAt: Date().timeIntervalSince1970)
                    case .endSession, .error:
                        return
                    default:
                        break
                    }
                }
                if didEnableControlChannel {
                    Logger.shared.info("Screen Q control channel closed for \(self.peerLabel)")
                }
            } catch {
                Logger.shared.warn("Screen Q control channel unavailable for \(self.peerLabel): \(error.localizedDescription)")
            }
            self.controlConnection = nil
            self.controlChannelActive = false
            self.controlChannelTask = nil
        }
    }

    private func stopControlChannel() async {
        controlChannelTask?.cancel()
        controlChannelTask = nil
        controlChannelActive = false
        if let controlConnection {
            self.controlConnection = nil
            await controlConnection.stop()
        }
    }

    private func startHandshakeWatchdog() {
        handshakeWatchdogTask?.cancel()
        handshakeWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .handshake = self.phase {
                await self.connection.stop()
                self.phase = .failed(reason: "Timed out waiting for the host handshake. If the Mac was asleep, save a Wake MAC address for this endpoint and make sure Wake for network access is enabled on the host.")
            }
        }
    }

    private func stopHandshakeWatchdog() {
        handshakeWatchdogTask?.cancel()
        handshakeWatchdogTask = nil
    }

    private func startFirstFrameWatchdogIfNeeded() {
        guard !didReceiveFirstRenderableFrame, firstFrameWatchdogTask == nil else { return }
        firstFrameWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, !Task.isCancelled, !self.renderer.hasRenderableFrame else { return }
            switch self.phase {
            case .approved, .streaming, .viewOnly:
                await self.connection.stop()
                self.phase = .failed(reason: "Timed out waiting for the first screen frame. The host may still be waking, locked before ScreenCaptureKit can produce frames, or unable to capture the selected target.")
            default:
                break
            }
        }
    }

    private func stopFirstFrameWatchdog() {
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
    }

    private func markFirstFrameReceivedIfRenderable() {
        guard renderer.hasRenderableFrame else { return }
        didReceiveFirstRenderableFrame = true
        stopFirstFrameWatchdog()
    }

    private func stopLatencyProbes() {
        latencyProbeTask?.cancel()
        latencyProbeTask = nil
        hostClockOffsetSeconds = nil
        hostClockOffsetUpdatedAt = nil
    }

    private func stopStatsReports() {
        statsReportTask?.cancel()
        statsReportTask = nil
    }

    private func sendLatencyProbeIfAllowed() async {
        guard encryptionEnabled else { return }
        switch phase {
        case .approved, .streaming, .viewOnly:
            let ping = PingMessage(clientTimestamp: Date().timeIntervalSince1970)
            let targetConnection = controlConnection ?? connection
            try? await targetConnection.sendJSON(.ping, ping, waitForCompletion: false)
        default:
            break
        }
    }

    private func sendStatsReportIfAllowed() async {
        guard encryptionEnabled else { return }
        switch phase {
        case .approved, .streaming, .viewOnly:
            let targetConnection = controlConnection ?? connection
            try? await targetConnection.sendJSON(.stats, stats.snapshotMessage(), waitForCompletion: false)
        default:
            break
        }
    }

    private func updateLatencyOffset(from pong: PongMessage, receivedAt receiveTimestamp: TimeInterval) {
        let rttSeconds = max(0, receiveTimestamp - pong.clientTimestamp)
        stats.recordRoundTrip(millis: rttSeconds * 1000)
        guard rttSeconds <= 1.5 else { return }
        let midpoint = pong.clientTimestamp + rttSeconds / 2
        let measuredOffset = pong.serverTimestamp - midpoint
        if let previous = hostClockOffsetSeconds {
            hostClockOffsetSeconds = previous * 0.8 + measuredOffset * 0.2
        } else {
            hostClockOffsetSeconds = measuredOffset
        }
        hostClockOffsetUpdatedAt = Date()
    }

    private func frameLatencyMillis(for meta: VideoFrameMeta, receivedAt receiveTimestamp: TimeInterval) -> Double? {
        guard let captureWallClock = meta.captureWallClockTimestamp else { return nil }
        guard let offset = hostClockOffsetSeconds,
              let offsetUpdatedAt = hostClockOffsetUpdatedAt,
              Date().timeIntervalSince(offsetUpdatedAt) <= 12 else {
            return nil
        }
        let millis = (receiveTimestamp - captureWallClock + offset) * 1000
        guard millis.isFinite, millis >= 0, millis <= 5_000 else { return nil }
        return millis
    }

    private func shouldDiscardStaleFrame(latencyMillis: Double?) -> Bool {
        guard let latencyMillis else { return false }
        return latencyMillis > 1_500
    }

    private func shouldSendViewportHint(_ next: ViewerViewportMessage, now: Date) -> Bool {
        guard let previous = lastViewportHint else { return true }
        if previous.displayID != next.displayID || previous.adaptiveEnabled != next.adaptiveEnabled {
            return true
        }
        if abs(previous.zoomScale - next.zoomScale) >= 0.04 {
            return now.timeIntervalSince(lastViewportHintSentAt) >= 0.18
        }
        if abs(previous.visibleRect.x - next.visibleRect.x) >= 0.04 ||
            abs(previous.visibleRect.y - next.visibleRect.y) >= 0.04 ||
            abs(previous.visibleRect.width - next.visibleRect.width) >= 0.04 ||
            abs(previous.visibleRect.height - next.visibleRect.height) >= 0.04 {
            return now.timeIntervalSince(lastViewportHintSentAt) >= 0.5
        }
        if abs(Double(previous.canvasPixelWidth - next.canvasPixelWidth)) >= 96 ||
            abs(Double(previous.canvasPixelHeight - next.canvasPixelHeight)) >= 96 {
            return true
        }
        return false
    }

    private func handle(_ message: InboundMessage) async {
        switch message {
        case .helloAck(let ack):
            stopHandshakeWatchdog()
            hostCapabilities = ack.capabilities
            encryptionEnabled = ack.encryptionEnabled
            encryptionStatusKnown = true
            guard ack.encryptionEnabled,
                  let hostPublicKey = ack.ephemeralPublicKey,
                  let viewerPublicKey = localEphemeralPublicKey,
                  let secureSessionFactory else {
                stopLatencyProbes()
                phase = .failed(reason: "Screen Q requires encrypted native sessions, but the host did not negotiate encryption.")
                return
            }
            do {
                let material = try secureSessionFactory.deriveKey(
                    peerPublicKeyBase64: hostPublicKey,
                    salt: ScreenQSecureSessionTranscript.salt(
                        viewerID: localPeerID ?? app?.localDeviceID ?? UUID(),
                        hostID: ack.peerID
                    ),
                    info: ScreenQSecureSessionTranscript.info(
                        viewerPublicKey: viewerPublicKey,
                        hostPublicKey: hostPublicKey
                    ),
                    role: .viewer
                )
                await connection.enableEncryption(material)
            } catch {
                stopLatencyProbes()
                phase = .failed(reason: "Unable to negotiate Screen Q encryption.")
                return
            }
            if ack.trustedByHost == true {
                // Host recognised us as a trusted peer — skip the code prompt.
                // The host will still require local approval before starting.
                phase = .awaitingHostApproval
            } else {
                phase = .awaitingPairingCode
            }
        case .pairingApproved(let approved):
            approvedSessionID = approved.sessionID
            hostCapabilities = approved.hostCapabilities
            grantedPermissions = approved.permissions ?? (approved.controlEnabled ? .standard : .viewOnly)
            inputMapper.isControlEnabled = grantedPermissions.contains(.control) && approved.hostCapabilities.supportsControl
            phase = grantedPermissions.contains(.control) ? .approved : .viewOnly
            startLatencyProbesIfNeeded()
            startFirstFrameWatchdogIfNeeded()
            if inputMapper.isControlEnabled {
                startControlChannelIfNeeded(sessionID: approved.sessionID)
            }
        case .pairingRejected(let r):
            stopHandshakeWatchdog()
            stopFirstFrameWatchdog()
            stopLatencyProbes()
            stopStatsReports()
            await stopControlChannel()
            inputMapper.isControlEnabled = false
            inputMapper.cancelPendingInput()
            phase = .failed(reason: r.reason)
        case .videoFormat(let format):
            renderer.updateFormat(format)
            phase = inputMapper.isControlEnabled ? .streaming : .viewOnly
            startLatencyProbesIfNeeded()
            startFirstFrameWatchdogIfNeeded()
        case .videoFrame(let meta, let payload):
            let receivedAt = Date().timeIntervalSince1970
            let latencyMillis = frameLatencyMillis(for: meta, receivedAt: receivedAt)
            if latencyMillis == nil {
                stats.clearFrameLatency()
            }
            if shouldDiscardStaleFrame(latencyMillis: latencyMillis) {
                stats.recordDiscardedFrame(byteCount: payload.count, latencyMillis: latencyMillis)
                break
            }
            renderer.ingest(
                meta: meta,
                payload: payload,
                stats: stats,
                frameLatencyMillis: latencyMillis
            )
            markFirstFrameReceivedIfRenderable()
        case .cursorUpdate(let cursor):
            cursorState.update(cursor)
            inputMapper.updateRemotePointer(NormalisedPoint(x: cursor.x, y: cursor.y))
        case .audioFormat(let fmt):
            audioPlayer.configure(format: fmt)
        case .audioFrame(let data):
            audioPlayer.ingest(data)
        case .displayList(let list):
            remoteDisplays = list.displays
            activeDisplayID = list.activeDisplayID
        case .shareTargetList(let list):
            shareTargets = list.targets
            activeShareTargetID = list.activeTargetID
        case .clipboardData(let data):
            #if os(macOS)
            if let rawData = Data(base64Encoded: data.base64Data) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(rawData, forType: NSPasteboard.PasteboardType(data.type))
            }
            #endif
        case .fileOffer(let offer):
            fileTransfer.handleOffer(offer)
        case .fileAccept(let accept):
            fileTransfer.handleAccept(accept)
        case .fileReject(let reject):
            fileTransfer.handleReject(reject)
        case .fileChunk(let chunk):
            fileTransfer.handleChunk(chunk)
        case .fileComplete(let complete):
            fileTransfer.handleComplete(complete)
        case .commandOutput(let output):
            terminalState.handleOutput(output)
        case .systemActionResult(let result):
            Logger.shared.info("SystemAction result: \(result.success) — \(result.message ?? "")")
        case .systemReport(let report):
            reportState.handleReport(report)
        case .packageInstallResult(let result):
            Logger.shared.info("PackageInstall result: \(result.success) — \(result.output)")
        case .pong(let p):
            let now = Date().timeIntervalSince1970
            updateLatencyOffset(from: p, receivedAt: now)
        case .endSession(let e):
            stopHandshakeWatchdog()
            stopFirstFrameWatchdog()
            stopLatencyProbes()
            stopStatsReports()
            await stopControlChannel()
            inputMapper.isControlEnabled = false
            inputMapper.cancelPendingInput()
            audioPlayer.stop()
            phase = .ended(reason: e.reason)
        case .error(let e):
            stopHandshakeWatchdog()
            stopFirstFrameWatchdog()
            stopLatencyProbes()
            stopStatsReports()
            await stopControlChannel()
            inputMapper.isControlEnabled = false
            inputMapper.cancelPendingInput()
            audioPlayer.stop()
            phase = .failed(reason: e.message)
        default:
            break
        }
    }

    private func currentPlatform() -> PeerPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return UIDevice_isPad() ? .iPadOS : .iOS
        #elseif os(visionOS)
        return .visionOS
        #else
        return .unknown
        #endif
    }
}

#if os(iOS)
fileprivate func UIDevice_isPad() -> Bool {
    UIDevice.current.userInterfaceIdiom == .pad
}
#endif

// MARK: - View

/// Touch interaction mode for iOS viewers (like Screens app).
enum TouchMode: String, CaseIterable, Identifiable {
    case directTouch   // tap where you touch = click there
    case trackpad      // multi-touch trackpad: 1-finger move, tap=click, long-press=right-click, 2-finger scroll, 3-finger drag
    case scrollOnly    // gestures only scroll, no clicking

    var id: String { rawValue }
    var label: String {
        switch self {
        case .directTouch: return "Direct Touch"
        case .trackpad:    return "Trackpad"
        case .scrollOnly:  return "Scroll Only"
        }
    }
    var icon: String {
        switch self {
        case .directTouch: return "hand.tap"
        case .trackpad:    return "rectangle.and.hand.point.up.left"
        case .scrollOnly:  return "scroll"
        }
    }
}

struct ShareTargetPickerContent: View {
    @ObservedObject var session: ViewerSession
    let onSelect: () -> Void

    private struct ShareTargetSection: Identifiable {
        let kind: ShareTargetKind
        let targets: [ShareTargetInfo]
        var id: ShareTargetKind { kind }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    Text(section.kind.pickerLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 14)
                        .padding(.top, (sections.first.map { $0.kind == section.kind } ?? false) ? 12 : 18)
                        .padding(.bottom, 6)

                    ForEach(section.targets) { target in
                        Button {
                            Task {
                                await session.switchShareTarget(target.id)
                                onSelect()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: target.kind.pickerIcon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.name)
                                        .lineLimit(1)
                                    if let detail = target.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 12)
                                if target.id == session.activeShareTargetID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 420, maxHeight: 560)
    }

    private var sections: [ShareTargetSection] {
        ShareTargetKind.pickerOrder.compactMap { kind in
            let targets = session.shareTargets.filter { $0.kind == kind }
            return targets.isEmpty ? nil : ShareTargetSection(kind: kind, targets: targets)
        }
    }
}

extension ShareTargetKind {
    static let pickerOrder: [ShareTargetKind] = [.allDisplays, .display, .application, .window]

    var pickerLabel: String {
        switch self {
        case .allDisplays: return "All Displays"
        case .display: return "Displays"
        case .application: return "Apps"
        case .window: return "Windows"
        }
    }

    var pickerIcon: String {
        switch self {
        case .allDisplays: return "display.2"
        case .display: return "display"
        case .application: return "app.dashed"
        case .window: return "macwindow"
        }
    }
}

struct RemoteScreenView: View {

    @EnvironmentObject private var app: AppState
    @ObservedObject var session: ViewerSession
    @ObservedObject private var renderer: RemoteScreenRenderer
    @ObservedObject private var stats: TransportStats
    var onDisconnect: () -> Void

    @StateObject private var controlPreferences: ViewerControlPreferences
    #if os(iOS)
    @StateObject private var modifierLatch = ModifierLatchController()
    #endif

    init(session: ViewerSession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self.renderer = session.renderer
        self.stats = session.stats
        self.onDisconnect = onDisconnect
        self._controlPreferences = StateObject(wrappedValue: ViewerControlPreferences(scope: session.controlPreferenceScope))
    }

    @State private var showStats = true
    @State private var showKeyboardEntry = false
    @State private var keyboardDraft = ""
    @State private var lastDragLocation: CGPoint = .zero
    @State private var touchMode: TouchMode = .directTouch
    @State private var isKeyboardActive = false
    @State private var showShareTargetPicker = false
    @State private var viewport: ViewportTransform = .identity
    @State private var lastCanvasSize: CGSize = .zero
    @State private var lastMagnificationScale: CGFloat = 1.0
    #if os(iOS)
    @State private var controlsVisible = true
    @State private var zoomHUDScale: CGFloat?
    @State private var dragFeedback: IOSDragFeedback?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            content
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                toolbarButtons
            }
            #endif
        }
        .onAppear {
            configureViewerControls()
        }
        .onReceive(controlPreferences.$streamQuality.removeDuplicates()) { _ in
            applyStreamControls()
        }
        .onReceive(controlPreferences.$streamProfile.removeDuplicates()) { _ in
            applyStreamControls()
        }
        .onChange(of: session.phase) { _ in
            applyStreamControls()
        }
        .onChange(of: session.activeShareTargetID) { _ in
            resetViewport()
        }
        .onReceive(renderer.$currentImage.compactMap { $0 }.throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)) { image in
            app.savedConnections.updateThumbnail(
                host: session.controlPreferenceScope.host,
                port: session.controlPreferenceScope.port,
                displayName: session.peerLabel,
                connectionProtocol: .screenQ,
                image: image
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .handshake, .connecting:
            ProgressView("Connecting to \(session.peerLabel)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .awaitingPairingCode:
            pairingForm
        case .awaitingHostApproval:
            ProgressView("Waiting for host approval…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .approved, .streaming, .viewOnly:
            screenCanvas
        case .failed(let r):
            VStack(spacing: 12) {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
                Text("Session failed").font(.title3)
                Text(r).foregroundColor(.secondary)
                Button("Disconnect") { onDisconnect() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .ended(let r):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("Session ended")
                Text(r).foregroundColor(.secondary)
                Button("Back") { onDisconnect() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .idle, .advertising, .browsing:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                    .foregroundColor(statusColor)
                Text(session.phase.humanDescription)
                    .font(.subheadline)
                    .lineLimit(1)
                if session.phase.isActive && session.encryptionStatusKnown {
                    Text(session.encryptionEnabled ? "Encrypted" : "Unencrypted")
                        .font(.caption.bold())
                        .foregroundColor(session.encryptionEnabled ? .green : .orange)
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            if showStats {
                statsView
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
    }

    private var statsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                statsLabel(String(format: "%.0f fps", stats.fps), systemImage: "speedometer")
                statsLabel(ByteFormatting.bitsPerSecond(stats.bytesPerSecond), systemImage: "arrow.down.circle")
                statsLabel(latencyLabel, systemImage: "timer")
                statsLabel(rttLabel, systemImage: "network")
                statsLabel(
                    session.inputMapper.isControlEnabled ? "Control" : "View only",
                    systemImage: session.inputMapper.isControlEnabled ? "cursorarrow.click" : "eye"
                )
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption.monospacedDigit())
        .foregroundColor(.secondary)
        .frame(minHeight: 18, maxHeight: 22)
    }

    private func statsLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var latencyLabel: String {
        guard stats.frameLatencyMillis > 0 else { return "delay --" }
        return String(format: "%.0f ms delay", stats.frameLatencyMillis)
    }

    private var rttLabel: String {
        guard stats.roundTripMillis > 0 else { return "RTT --" }
        return String(format: "%.0f ms RTT", stats.roundTripMillis)
    }

    private var statusSymbol: String {
        switch session.phase {
        case .streaming, .approved: return "circle.fill"
        case .viewOnly: return "eye"
        case .failed: return "xmark.octagon"
        case .ended:  return "checkmark.circle"
        default: return "circle.dotted"
        }
    }
    private var statusColor: Color {
        switch session.phase {
        case .streaming, .approved: return .green
        case .viewOnly: return .blue
        case .failed: return .red
        default: return .secondary
        }
    }

    private var toolbarButtons: some View {
        HStack(spacing: 12) {
            Button {
                controlPreferences.toolbarCondensed.toggle()
            } label: {
                Image(systemName: controlPreferences.toolbarCondensed ? "plus" : "minus")
            }
            .help(controlPreferences.toolbarCondensed ? "Expand toolbar" : "Condense toolbar")

            if !controlPreferences.toolbarCondensed {
                expandedToolbarButtons
            }

            Button { onDisconnect() } label: {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.red)
            }
            .help("Disconnect")
        }
    }

    @ViewBuilder
    private var expandedToolbarButtons: some View {
        Group {
            Button {
                showStats.toggle()
            } label: {
                Image(systemName: showStats ? "info.circle.fill" : "info.circle")
            }
            Button {
                session.fitMode.toggle()
            } label: {
                Image(systemName: session.fitMode ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward")
            }
            StreamQualityButton(
                quality: $controlPreferences.streamQuality,
                profile: $controlPreferences.streamProfile,
                stats: stats,
                protocolName: "Screen Q Native",
                detail: "Controls native host bitrate, frame cadence, viewport-aware detail, and compression.",
                compact: true
            )
            Button {
                controlPreferences.showCursorOverlay.toggle()
            } label: {
                Image(systemName: controlPreferences.showCursorOverlay ? "cursorarrow.rays" : "eye.slash")
            }
            .help(controlPreferences.showCursorOverlay ? "Hide overlay cursor" : "Show overlay cursor")
            #if os(iOS)
            if !viewport.isIdentity {
                Button {
                    resetViewport()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
            }
            #endif

            // Legacy display picker for older hosts that do not advertise share targets.
            if session.shareTargets.isEmpty && session.remoteDisplays.count > 1 {
                Menu {
                    ForEach(session.remoteDisplays) { display in
                        Button {
                            Task { await session.switchDisplay(display.id) }
                        } label: {
                            HStack {
                                Text(display.name)
                                if display.id == session.activeDisplayID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "display.2")
                }
            }

            if session.shareTargets.count > 1 {
                Button {
                    showShareTargetPicker.toggle()
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .help("Share target")
                .popover(isPresented: $showShareTargetPicker) {
                    ShareTargetPickerContent(session: session) {
                        showShareTargetPicker = false
                    }
                }
            }

            #if os(iOS)
            // Touch mode picker
            Menu {
                ForEach(TouchMode.allCases) { mode in
                    Button {
                        touchMode = mode
                    } label: {
                        HStack {
                            Label(mode.label, systemImage: mode.icon)
                            if mode == touchMode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: touchMode.icon)
            }
            #endif

            Menu {
                ForEach(KeyboardMapping.specialKeys, id: \.label) { entry in
                    Button(entry.label) { session.inputMapper.sendKey(entry.code) }
                }
            } label: {
                Image(systemName: "command.square")
            }

            #if os(iOS)
            Button {
                isKeyboardActive.toggle()
            } label: {
                Image(systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
            }
            #else
            Button {
                showKeyboardEntry.toggle()
            } label: {
                Image(systemName: "keyboard")
            }

            #if os(macOS)
            Button {
                MacWindowControls.toggleFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            #endif
            #endif
        }
    }

    @ViewBuilder
    private var pairingForm: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Enter the 6-digit pairing code shown on \(session.peerLabel).")
                .multilineTextAlignment(.center)
            TextField("123456", text: $session.pairingPrompt)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .font(.system(.title3, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
            Button("Send pairing request") {
                Task { await session.sendPairingRequest() }
            }
            .buttonStyle(.bordered)
            .disabled(session.pairingPrompt.count != 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var screenCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if renderer.hasRenderableFrame {
                    #if os(iOS)
                    iOSCanvasContent(canvasSize: proxy.size)
                    #else
                    remoteFrameLayer(canvasSize: proxy.size)
                        .gesture(dragGesture(in: proxy.size))
                    #endif
                } else {
                    ProgressView("Waiting for first frame…")
                        .foregroundColor(.white)
                }
                if controlPreferences.showCursorOverlay {
                    CursorOverlayView(
                        state: session.cursorState,
                        inputMapper: session.inputMapper,
                        canvasGeometry: canvasGeometry(size: proxy.size)
                    )
                }
                FileTransferOverlay(
                    service: session.fileTransfer,
                    isTransferEnabled: session.grantedPermissions.contains(.fileTransfer),
                    disabledReason: "File transfer is disabled for this session"
                )
                #if os(iOS)
                if let zoomHUDScale {
                    zoomHUD(scale: zoomHUDScale)
                }
                if let dragFeedback {
                    dragFeedbackOverlay(dragFeedback)
                }
                IOSSessionControlSurface(
                    session: session,
                    preferences: controlPreferences,
                    modifiers: modifierLatch,
                    touchMode: Binding(
                        get: { touchMode },
                        set: {
                            touchMode = $0
                            controlPreferences.touchMode = $0
                        }
                    ),
                    fitMode: Binding(
                        get: { session.fitMode },
                        set: {
                            session.fitMode = $0
                            controlPreferences.fitMode = $0
                        }
                    ),
                    showStats: Binding(
                        get: { showStats },
                        set: {
                            showStats = $0
                            controlPreferences.showStats = $0
                        }
                    ),
                    isKeyboardActive: $isKeyboardActive,
                    controlsVisible: $controlsVisible,
                    viewport: viewport,
                    resetViewport: resetViewport,
                    onDisconnect: onDisconnect
                )
                #endif
                #if os(macOS)
                if showKeyboardEntry {
                    keyboardEntryOverlay
                        .padding()
                }
                #endif
                #if os(iOS)
                // Hidden keyboard field — always in the hierarchy so
                // becomeFirstResponder works on demand.
                RemoteKeyboardView(
                    inputMapper: session.inputMapper,
                    isActive: $isKeyboardActive
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                #endif
            }
            .onChange(of: proxy.size) { new in
                updateCanvas(size: new)
            }
            .onChange(of: session.fitMode) { _ in
                clampViewport(for: proxy.size)
            }
            .onChange(of: viewport) { new in
                updateCanvas(size: proxy.size, viewport: new)
            }
            .onAppear { updateCanvas(size: proxy.size) }
            .clipped()
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func iOSCanvasContent(canvasSize: CGSize) -> some View {
        ZStack {
            remoteFrameLayer(canvasSize: canvasSize)
            TrackpadInputView(
                inputMapper: session.inputMapper,
                touchMode: touchMode,
                canvasSize: canvasSize,
                remotePixelSize: remotePixelSize,
                fit: session.fitMode,
                viewport: viewport,
                viewportPanInsets: ViewportPanInsets.zoomedViewerInsets(for: canvasSize, keyboardActive: isKeyboardActive),
                onViewportChange: { newViewport in
                    setViewport(newViewport, canvasSize: canvasSize)
                },
                onViewportScaleChange: { scale in
                    zoomHUDScale = scale
                },
                onControlsToggle: {
                    controlsVisible.toggle()
                },
                onDragFeedbackChange: { feedback in
                    dragFeedback = feedback
                }
            )
        }
    }
    #endif

    private func remoteFrameLayer(canvasSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let img = renderer.currentImage {
                remoteImageLayer(img, canvasSize: canvasSize)
            }
            if let regionFrame = renderer.currentRegionFrame {
                remoteRegionLayer(regionFrame, canvasSize: canvasSize)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .scaleEffect(viewport.scale, anchor: .center)
        .offset(viewport.offset)
        .clipped()
    }

    private func remoteImageLayer(_ img: CGImage, canvasSize: CGSize) -> some View {
        let drawRect = baseRemoteDrawRect(canvasSize: canvasSize)
        return Image(decorative: img, scale: 1.0)
            .resizable()
            .interpolation(.high)
            .frame(width: drawRect.width, height: drawRect.height)
            .position(x: drawRect.midX, y: drawRect.midY)
    }

    private func remoteRegionLayer(_ regionFrame: RemoteScreenRenderer.RegionFrame, canvasSize: CGSize) -> some View {
        let drawRect = baseRemoteDrawRect(canvasSize: canvasSize)
        let region = regionFrame.region
        let fullWidth = max(1, CGFloat(region.fullWidth))
        let fullHeight = max(1, CGFloat(region.fullHeight))
        let x = drawRect.minX + CGFloat(region.x) / fullWidth * drawRect.width
        let y = drawRect.minY + CGFloat(region.y) / fullHeight * drawRect.height
        let width = CGFloat(region.width) / fullWidth * drawRect.width
        let height = CGFloat(region.height) / fullHeight * drawRect.height
        return Image(decorative: regionFrame.image, scale: 1.0)
            .resizable()
            .interpolation(.high)
            .frame(width: max(1, width), height: max(1, height))
            .position(x: x + width / 2, y: y + height / 2)
    }

    private func baseRemoteDrawRect(canvasSize: CGSize) -> CGRect {
        CanvasGeometry(
            canvasSize: canvasSize,
            remotePixelSize: remotePixelSize,
            fit: session.fitMode,
            viewport: .identity
        ).remoteDrawRect()
    }

    #if os(iOS)
    // Direct Touch: tap = click at that point
    private func directTapGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { v in
                if session.inputMapper.isControlEnabled {
                    session.inputMapper.sendTap(localPoint: v.location)
                }
            }
    }

    // Direct Touch: drag = pointer move + down/up
    private func directDragGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                if session.inputMapper.isControlEnabled {
                    session.inputMapper.sendPointerMove(localPoint: v.location)
                }
            }
            .onEnded { v in
                if session.inputMapper.isControlEnabled {
                    session.inputMapper.sendPointerUp(localPoint: v.location)
                }
            }
    }

    // Two-finger scroll (works in Direct Touch & Scroll Only modes)
    private func twoFingerScrollGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let delta = CGSize(
                    width: v.translation.width - (v.startLocation.x - v.startLocation.x),
                    height: v.translation.height
                )
                session.inputMapper.sendScroll(
                    deltaX: Double(delta.width) * 0.5,
                    deltaY: Double(delta.height) * 0.5,
                    localPoint: v.location
                )
            }
    }

    private func localPinchZoomGesture(in canvasSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let delta = scale / max(lastMagnificationScale, 0.001)
                lastMagnificationScale = scale
                let anchor = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                applyViewportMagnification(delta, around: anchor, canvasSize: canvasSize)
            }
            .onEnded { _ in
                lastMagnificationScale = 1.0
            }
    }
    #endif

    #if os(macOS)
    private func dragGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                lastDragLocation = v.location
                if session.inputMapper.isControlEnabled {
                    session.inputMapper.sendPointerMove(localPoint: v.location)
                }
            }
            .onEnded { v in
                if session.inputMapper.isControlEnabled {
                    session.inputMapper.sendPointerDown(localPoint: v.location)
                    session.inputMapper.sendPointerUp(localPoint: v.location)
                }
            }
    }
    #endif

    private func updateCanvas(size: CGSize) {
        updateCanvas(size: size, viewport: viewport)
    }

    private func updateCanvas(size: CGSize, viewport: ViewportTransform) {
        lastCanvasSize = size
        session.inputMapper.canvas = canvasGeometry(size: size, viewport: viewport)
        #if os(iOS)
        sendViewportHint(canvasSize: size, viewport: viewport)
        #endif
    }

    private var remotePixelSize: CGSize {
        let remoteW = renderer.format?.pixelWidth ?? 1920
        let remoteH = renderer.format?.pixelHeight ?? 1080
        return CGSize(width: remoteW, height: remoteH)
    }

    private func canvasGeometry(size: CGSize, viewport: ViewportTransform? = nil) -> CanvasGeometry {
        CanvasGeometry(
            canvasSize: size,
            remotePixelSize: remotePixelSize,
            fit: session.fitMode,
            viewport: viewport ?? self.viewport,
            viewportPanInsets: ViewportPanInsets.zoomedViewerInsets(for: size, keyboardActive: isKeyboardActive)
        )
    }

    private func setViewport(_ newViewport: ViewportTransform, canvasSize: CGSize) {
        viewport = newViewport
        updateCanvas(size: canvasSize, viewport: newViewport)
    }

    private func applyViewportMagnification(_ magnification: CGFloat, around anchor: CGPoint, canvasSize: CGSize) {
        let geometry = canvasGeometry(size: canvasSize)
        let nextViewport = viewport.applyingMagnification(magnification, around: anchor, in: geometry)
        setViewport(nextViewport, canvasSize: canvasSize)
    }

    private func clampViewport(for canvasSize: CGSize) {
        let clamped = viewport.clamped(in: canvasGeometry(size: canvasSize))
        setViewport(clamped, canvasSize: canvasSize)
    }

    private func resetViewport() {
        setViewport(.identity, canvasSize: lastCanvasSize)
    }

    private func configureViewerControls() {
        applyStreamControls()
        #if os(iOS)
        touchMode = controlPreferences.touchMode
        showStats = controlPreferences.showStats
        session.fitMode = controlPreferences.fitMode
        session.inputMapper.activeModifiers = { [modifierLatch] in
            modifierLatch.activeModifiers
        }
        session.inputMapper.consumeMomentaryModifiers = { [modifierLatch] in
            modifierLatch.clearMomentaryModifiers()
        }
        #endif
    }

    private func applyStreamControls() {
        session.updateStreamQuality(
            controlPreferences.streamQuality,
            profile: controlPreferences.streamProfile
        )
        #if os(iOS)
        sendViewportHint(canvasSize: lastCanvasSize, viewport: viewport, force: true)
        #endif
    }

    #if os(iOS)
    private func sendViewportHint(
        canvasSize: CGSize,
        viewport: ViewportTransform,
        force: Bool = false
    ) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let geometry = canvasGeometry(size: canvasSize, viewport: viewport)
        guard let visibleRect = geometry.visibleRemoteRect() else { return }
        let screenScale = UIScreen.main.scale
        let message = ViewerViewportMessage(
            displayID: session.activeDisplayID == 0 ? nil : session.activeDisplayID,
            zoomScale: Double(max(ViewportTransform.minimumScale, viewport.scale)),
            visibleRect: visibleRect,
            canvasPixelWidth: Int((canvasSize.width * screenScale).rounded()),
            canvasPixelHeight: Int((canvasSize.height * screenScale).rounded()),
            adaptiveEnabled: controlPreferences.streamProfile.adaptive,
            timestamp: Date().timeIntervalSince1970
        )
        session.updateViewerViewport(message, force: force)
    }

    private func zoomHUD(scale: CGFloat) -> some View {
        Text("\(Int((scale * 100).rounded()))%")
            .font(.caption.monospacedDigit().bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
            .allowsHitTesting(false)
    }

    private func dragFeedbackOverlay(_ feedback: IOSDragFeedback) -> some View {
        let color: Color = feedback.kind == .right ? .orange : .accentColor
        return ZStack {
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 44, height: 44)
            Image(systemName: feedback.kind == .right ? "contextualmenu.and.cursorarrow" : "cursorarrow.motionlines")
                .font(.caption.bold())
                .foregroundStyle(color)
        }
        .position(feedback.point)
        .allowsHitTesting(false)
    }
    #endif

    #if os(macOS)
    private var keyboardEntryOverlay: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Type, then press Send", text: $keyboardDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    if !keyboardDraft.isEmpty {
                        session.inputMapper.sendText(keyboardDraft)
                        keyboardDraft = ""
                    }
                }
                .buttonStyle(.bordered)
                Button("Close") { showKeyboardEntry = false }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    #endif
}
