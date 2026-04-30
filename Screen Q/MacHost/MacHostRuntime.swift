//
//  MacHostRuntime.swift
//  Screen Q
//

#if os(macOS)
import AppKit
import Combine
import Foundation
import Network

@MainActor
final class MacHostRuntime: ObservableObject {
    @Published private(set) var isSharing: Bool = false
    @Published var viewOnly: Bool = false
    @Published var permissions: PermissionSet = .standard
    @Published var quality: Double = StreamQualityPreference.defaultQuality
    @Published private(set) var pairingCode: String = ""
    @Published private(set) var pendingRequests: [PairingRequest] = []
    @Published private(set) var hostConnections: [HostSessionBox] = []
    @Published private(set) var listeningPort: UInt16 = ScreenQProtocol.defaultPort
    @Published private(set) var listeningAddresses: [LocalInterface] = []

    @Published var autoStartHosting: Bool {
        didSet { defaults.set(autoStartHosting, forKey: keys.autoStartHosting) }
    }
    @Published var enableClipboard: Bool {
        didSet {
            defaults.set(enableClipboard, forKey: keys.enableClipboard)
            app?.clipboardSync.enabled = enableClipboard
        }
    }
    @Published var enableAudio: Bool {
        didSet { defaults.set(enableAudio, forKey: keys.enableAudio) }
    }

    let pairing = PairingManager()

    private weak var app: AppState?
    private let defaults: UserDefaults
    private let keys = PreferenceKeys()
    private let hostFileTransfer = FileTransferService()
    private var cancellables: Set<AnyCancellable> = []
    private var abrTimer: Timer?
    private var didBindPairing = false
    private var adaptiveStreamingEnabled = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoStartHosting = defaults.bool(forKey: keys.autoStartHosting)
        self.enableClipboard = defaults.object(forKey: keys.enableClipboard) as? Bool ?? true
        self.enableAudio = defaults.bool(forKey: keys.enableAudio)
        self.pairingCode = pairing.currentCode
        self.pendingRequests = pairing.pendingRequests
    }

    func configure(app: AppState) {
        self.app = app
        bindPairingIfNeeded()
    }

    var readyToHost: Bool {
        app?.macPermissions.screenRecordingGranted == true
    }

    func refreshForHostSurface() async {
        guard let app else { return }
        app.macPermissions.refresh()
        await app.displaySelection.refreshUsingSCShareableContent()
        if autoStartHosting && !isSharing && readyToHost {
            await startHosting()
        }
        if isSharing {
            await refreshListeningInfo()
        }
    }

    func refreshListeningInfo() async {
        guard let app else { return }
        let info = await app.bonjourAdvertiser.listeningInfo()
        listeningPort = info.port
        listeningAddresses = info.addresses
    }

    func regeneratePairingCode() {
        pairing.regenerateCode()
    }

    func pairingCodeMatches(_ request: PairingRequest) -> Bool {
        request.trustedReconnect || pairing.codeIsValid(request.claimedCode)
    }

    func applyStreamQuality(_ preference: StreamQualityPreference) {
        applyStreamQuality(preference.nativeMessage)
    }

    func startHosting() async {
        guard let app else { return }
        do {
            try await app.bonjourAdvertiser.start(
                deviceName: app.localDeviceName,
                capabilities: hostCapabilities(),
                deviceID: app.localDeviceID,
                metadata: [
                    ScreenQProtocol.TXT.presence: "nativeHost",
                    ScreenQProtocol.TXT.acceptsScreenQ: "true"
                ]
            ) { [weak self] connection in
                Task { @MainActor in
                    await self?.acceptIncoming(connection)
                }
            }
            isSharing = true
            app.session = .advertising
            app.macPermissions.markLocalNetworkAttempted()
            await refreshListeningInfo()
        } catch {
            app.lastError = error.localizedDescription
            Logger.shared.error("startHosting failed: \(error.localizedDescription)")
        }
    }

    func stopHosting() {
        Task { await stopHostingNow() }
    }

    func stopHostingNow() async {
        guard let app else { return }
        try? await app.bonjourAdvertiser.stop()
        if #available(macOS 12.3, *) { await app.macCaptureService.stop() }
        app.cursorTracker.stop()
        app.clipboardSync.stop()
        if #available(macOS 13.0, *) { app.audioCaptureService.stop() }
        abrTimer?.invalidate()
        abrTimer = nil

        let connections = hostConnections
        for box in connections {
            await box.connection.stop()
        }
        hostConnections.removeAll()
        isSharing = false
        app.session = .idle
        for request in pairing.pendingRequests {
            MacPairingPromptController.shared.dismiss(request.id)
        }
        pairing.pendingRequests.removeAll()
    }

    func accessPolicy(for request: PairingRequest) -> TrustedPeerAccessPolicy {
        pairing.accessPolicy(peerID: request.viewer.id, fingerprint: request.identityFingerprint)
    }

    func approve(_ request: PairingRequest, setting accessPolicy: TrustedPeerAccessPolicy? = nil) async {
        guard pairingCodeMatches(request) else {
            await reject(request, reason: "Invalid or expired pairing code")
            return
        }
        guard let app else { return }
        guard let box = hostConnections.first(where: { $0.pendingRequest?.id == request.id }) else { return }

        let sessionID = UUID()
        let perms = permissions
        let approved = PairingApprovedMessage(
            sessionID: sessionID,
            hostCapabilities: hostCapabilities(),
            controlEnabled: perms.contains(.control),
            permissions: perms
        )
        try? await box.connection.sendJSON(.pairingApproved, approved)
        box.grantedPermissions = perms
        box.sessionID = sessionID

        if let fingerprint = request.identityFingerprint {
            pairing.trust(viewer: request.viewer, fingerprint: fingerprint)
            if let accessPolicy {
                _ = pairing.updateAccessPolicy(
                    peerID: request.viewer.id,
                    fingerprint: fingerprint,
                    accessPolicy: accessPolicy
                )
            }
            app.auditLog.log(
                sessionID: sessionID,
                peerName: request.viewer.displayName,
                peerID: request.viewer.id,
                event: .trustChanged,
                detail: "Trusted Screen Q device identity \(fingerprint.prefix(16))..."
            )
        }

        app.auditLog.log(
            sessionID: sessionID,
            peerName: box.peerName,
            peerID: request.viewer.id,
            event: .pairingApproved,
            detail: "Permissions: \(perms.rawValue)"
        )

        pairing.remove(request.id)
        MacPairingPromptController.shared.dismiss(request.id)
        box.state = viewOnly || !perms.contains(.control) ? .viewOnly : .approved
        box.pendingRequest = nil
        app.macInput.enabled = perms.contains(.control)
        app.macInput.viewOnly = viewOnly || !perms.contains(.control)

        guard #available(macOS 12.3, *) else { return }
        app.macCaptureService.settings.captureAudio = enableAudio && perms.contains(.audioForward)
        do {
            try await app.macCaptureService.start(
                subscriberID: box.id,
                onFormat: { [weak box] format in
                    guard let box else { return }
                    try? await box.connection.sendJSON(.videoFormat, format)
                },
                onFrame: { [weak box] meta, payload in
                    guard let box else { return }
                    Task { try? await box.connection.sendVideoFrame(meta: meta, payload: payload) }
                }
            )
            box.state = viewOnly || !perms.contains(.control) ? .viewOnly : .streaming
            app.auditLog.log(
                sessionID: sessionID,
                peerName: box.peerName,
                peerID: request.viewer.id,
                event: .sessionStarted,
                detail: "Encrypted=\(box.encryptionEnabled). Permissions: \(perms.rawValue)"
            )
        } catch {
            app.lastError = error.localizedDescription
        }

        hostFileTransfer.sendMessage = { [weak box] type, msg in
            guard let box else { return }
            Task { try? await box.connection.sendJSON(type, msg) }
        }

        let cursorDisplayID = app.displaySelection.selectedDisplayID ?? app.displaySelection.displays.first?.id
        if let cursorDisplayID {
            app.cursorTracker.start(displayID: cursorDisplayID, subscriberID: box.id) { [weak box] msg in
                guard let box else { return }
                Task { try? await box.connection.sendJSON(.cursorUpdate, msg) }
            }
        }

        if enableClipboard && perms.contains(.clipboard) {
            app.clipboardSync.enabled = true
            app.clipboardSync.start(
                onOffer: { [weak box] offer in
                    guard let box else { return }
                    Task { try? await box.connection.sendJSON(.clipboardOffer, offer) }
                },
                onSendData: { [weak box] data in
                    guard let box else { return }
                    Task { try? await box.connection.sendJSON(.clipboardData, data) }
                }
            )
        }

        await sendDisplayList(to: box)
        startAdaptiveBitrateLoop()
    }

    func reject(
        _ request: PairingRequest,
        reason: String = "Rejected by host",
        setting accessPolicy: TrustedPeerAccessPolicy? = nil
    ) async {
        if let accessPolicy, let fingerprint = request.identityFingerprint {
            _ = pairing.updateAccessPolicy(
                peerID: request.viewer.id,
                fingerprint: fingerprint,
                accessPolicy: accessPolicy
            )
        }
        if let box = hostConnections.first(where: { $0.pendingRequest?.id == request.id }) {
            try? await box.connection.sendJSON(.pairingRejected, PairingRejectedMessage(reason: reason))
            await box.connection.stop()
        }
        pairing.remove(request.id)
        MacPairingPromptController.shared.dismiss(request.id)
    }

    func disconnect(_ box: HostSessionBox) async {
        guard let app else { return }
        try? await box.connection.sendJSON(.endSession, EndSessionMessage(reason: "Host disconnected"))
        await box.connection.stop()
        app.auditLog.log(
            sessionID: box.sessionID,
            peerName: box.peerName,
            event: .sessionEnded,
            detail: "Host disconnected"
        )
    }

    // MARK: - Internals

    private func bindPairingIfNeeded() {
        guard !didBindPairing else { return }
        didBindPairing = true
        pairing.$currentCode
            .sink { [weak self] code in self?.pairingCode = code }
            .store(in: &cancellables)
        pairing.$pendingRequests
            .sink { [weak self] requests in self?.pendingRequests = requests }
            .store(in: &cancellables)
    }

    private func applyStreamQuality(_ message: StreamQualityMessage) {
        guard let app else { return }
        let profile = message.profile
        quality = StreamQualityPreference(quality: message.quality).quality
        adaptiveStreamingEnabled = profile.adaptive
        app.adaptiveBitrate.setUserCeiling(
            bitrate: message.targetBitrate,
            fps: message.targetFPS
        )
        if #available(macOS 12.3, *) {
            app.macCaptureService.applyStreamQuality(message)
        }
    }

    private func sanitizedStreamQualityMessage(_ message: StreamQualityMessage, for platform: PeerPlatform) -> StreamQualityMessage {
        switch platform {
        case .iOS, .iPadOS:
            return message.cappedForMobileViewer()
        default:
            return message
        }
    }

    private func hostCapabilities() -> Capabilities {
        var caps = Capabilities.macHostDefault
        caps.supportsControl = !viewOnly
        caps.supportsClipboard = enableClipboard
        caps.supportsAudio = enableAudio
        return caps
    }

    private func sendDisplayList(to box: HostSessionBox) async {
        guard let app else { return }
        let firstID = app.displaySelection.displays.first?.id
        let infos: [Screen_Q.DisplayInfo] = app.displaySelection.displayOptions().map { d in
            Screen_Q.DisplayInfo(
                id: d.id,
                name: d.name,
                pixelWidth: d.pixelWidth,
                pixelHeight: d.pixelHeight,
                isMain: d.id == firstID
            )
        }
        let active = app.displaySelection.selectedDisplayID ?? infos.first?.id ?? 0
        let msg = DisplayListMessage(displays: infos, activeDisplayID: active)
        try? await box.connection.sendJSON(.displayList, msg)
    }

    private func acceptIncoming(_ nw: NWConnection) async {
        guard let app else { return }
        let conn = await app.connectionManager.adopt(nw, role: .host)
        let box = HostSessionBox(connection: conn)
        hostConnections.append(box)

        let stream = await conn.inboundMessages()
        for await message in stream {
            await handleHostInbound(message, box: box)
        }
        if #available(macOS 12.3, *) {
            app.macCaptureService.removeSubscriber(box.id)
        }
        app.cursorTracker.removeSubscriber(box.id)
        hostConnections.removeAll(where: { $0.id == box.id })
        await stopSessionServicesIfIdle()
    }

    private func stopSessionServicesIfIdle() async {
        guard hostConnections.isEmpty, let app else { return }
        if #available(macOS 12.3, *) {
            await app.macCaptureService.stop()
        }
        app.cursorTracker.stop()
        app.clipboardSync.stop()
        if #available(macOS 13.0, *) {
            app.audioCaptureService.stop()
        }
        abrTimer?.invalidate()
        abrTimer = nil
    }

    private func handleHostInbound(_ message: InboundMessage, box: HostSessionBox) async {
        guard let app else { return }
        switch message {
        case .hello(let hello):
            guard let viewerPublicKey = hello.ephemeralPublicKey else {
                try? await box.connection.sendJSON(.error, ErrorMessage(
                    code: "encryptionRequired",
                    message: "Screen Q requires encrypted native sessions."
                ))
                await box.connection.stop()
                return
            }

            let viewerIdentityFingerprint = DeviceIdentityStore.verify(
                publicKeyBase64: hello.identityPublicKey,
                signatureBase64: hello.identitySignature,
                peerID: hello.peerID,
                displayName: hello.displayName,
                ephemeralPublicKey: hello.ephemeralPublicKey
            )
            let viewerIsTrusted = pairing.isTrusted(peerID: hello.peerID, fingerprint: viewerIdentityFingerprint)
            let secureFactory = SecureSessionFactory()
            let hostPublicKey = secureFactory.publicKeyBase64
            let hostProof = DeviceIdentityStore.proof(
                peerID: app.localDeviceID,
                displayName: app.localDeviceName,
                ephemeralPublicKey: hostPublicKey
            )
            let keyMaterial: SecureSessionKeyMaterial
            do {
                keyMaterial = try secureFactory.deriveKey(
                    peerPublicKeyBase64: viewerPublicKey,
                    salt: ScreenQSecureSessionTranscript.salt(viewerID: hello.peerID, hostID: app.localDeviceID),
                    info: ScreenQSecureSessionTranscript.info(viewerPublicKey: viewerPublicKey, hostPublicKey: hostPublicKey),
                    role: .host
                )
            } catch {
                try? await box.connection.sendJSON(.error, ErrorMessage(
                    code: "encryptionFailed",
                    message: "Unable to negotiate Screen Q encryption."
                ))
                await box.connection.stop()
                return
            }

            box.peerName = hello.displayName
            box.peerID = hello.peerID
            box.peerPlatform = hello.platform
            box.peerAppVersion = hello.appVersion
            box.identityFingerprint = viewerIdentityFingerprint
            box.state = .handshake

            let ack = HelloAckMessage(
                peerID: app.localDeviceID,
                displayName: app.localDeviceName,
                platform: .macOS,
                appVersion: "1.0",
                capabilities: hostCapabilities(),
                ephemeralPublicKey: hostPublicKey,
                identityPublicKey: hostProof?.publicKeyBase64,
                identitySignature: hostProof?.signatureBase64,
                encryptionEnabled: true,
                trustedByHost: viewerIsTrusted
            )
            box.encryptionEnabled = ack.encryptionEnabled
            box.encryptionStatusKnown = true
            try? await box.connection.sendJSON(.helloAck, ack)
            await box.connection.enableEncryption(keyMaterial)

            if viewerIsTrusted {
                Logger.shared.info("Trusted peer reconnected: \(hello.displayName) [\(hello.peerID)]")
                pairing.updateLastSeen(peerID: hello.peerID, fingerprint: viewerIdentityFingerprint)
                let pr = PairingRequest(
                    id: UUID(),
                    viewer: PeerDevice(
                        id: hello.peerID,
                        displayName: hello.displayName,
                        platform: hello.platform,
                        appVersion: hello.appVersion,
                        capabilities: hello.capabilities
                    ),
                    receivedAt: Date(),
                    claimedCode: pairing.currentCode,
                    identityFingerprint: viewerIdentityFingerprint,
                    trustedReconnect: true
                )
                await routeTrustedReconnect(pr, box: box)
            }
        case .pairingRequest(let req):
            let pr = PairingRequest(
                id: UUID(),
                viewer: PeerDevice(
                    id: req.viewerID,
                    displayName: req.displayName,
                    platform: box.peerPlatform,
                    appVersion: box.peerAppVersion,
                    capabilities: .viewerOnly
                ),
                receivedAt: Date(),
                claimedCode: req.claimedCode,
                identityFingerprint: box.identityFingerprint,
                trustedReconnect: false
            )
            box.pendingRequest = pr
            pairing.enqueue(pr)
            box.state = .awaitingHostApproval
            MacPairingPromptController.shared.present(request: pr, runtime: self)
            app.auditLog.log(
                peerName: req.displayName,
                peerID: req.viewerID,
                event: .pairingRequested,
                detail: "Pairing request received. Identity fingerprint: \(box.identityFingerprint.map { String($0.prefix(16)) } ?? "missing")"
            )
        case .inputEvent(let event):
            if box.state.allowsInputInjection && !viewOnly && box.grantedPermissions.contains(.control) {
                app.macInput.handle(event)
            }
        case .clipboardOffer(let offer):
            guard enableClipboard, box.grantedPermissions.contains(.clipboard) else { break }
            app.clipboardSync.handleRemoteOffer(offer) { request in
                Task { try? await box.connection.sendJSON(.clipboardRequest, request) }
            }
        case .clipboardRequest(let request):
            guard enableClipboard, box.grantedPermissions.contains(.clipboard) else { break }
            app.clipboardSync.handleRequest(request)
        case .clipboardData(let data):
            guard enableClipboard, box.grantedPermissions.contains(.clipboard) else { break }
            app.clipboardSync.applyRemoteClipboard(data)
        case .displaySwitch(let switchMsg):
            guard box.grantedPermissions.contains(.observe) else { break }
            app.displaySelection.selectedDisplayID = switchMsg.displayID
            if #available(macOS 12.3, *) {
                await app.macCaptureService.stop()
                do {
                    try await app.macCaptureService.start(
                        subscriberID: box.id,
                        onFormat: { [weak box] format in
                            guard let box else { return }
                            try? await box.connection.sendJSON(.videoFormat, format)
                        },
                        onFrame: { [weak box] meta, payload in
                            guard let box else { return }
                            Task { try? await box.connection.sendVideoFrame(meta: meta, payload: payload) }
                        }
                    )
                    app.cursorTracker.start(displayID: switchMsg.displayID, subscriberID: box.id) { [weak box] msg in
                        guard let box else { return }
                        Task { try? await box.connection.sendJSON(.cursorUpdate, msg) }
                    }
                } catch {
                    app.lastError = error.localizedDescription
                }
            }
        case .streamQuality(let qualityMessage):
            guard box.encryptionEnabled else { break }
            applyStreamQuality(sanitizedStreamQualityMessage(qualityMessage, for: box.peerPlatform))
        case .viewerViewport(let viewport):
            guard box.encryptionEnabled else { break }
            guard box.state == .streaming || box.state == .approved || box.state == .viewOnly else { break }
            if #available(macOS 12.3, *) {
                app.macCaptureService.applyViewerViewport(
                    viewport,
                    adaptiveEnabled: adaptiveStreamingEnabled && viewport.adaptiveEnabled
                )
            }
        case .fileOffer(let offer):
            guard box.grantedPermissions.contains(.fileTransfer) else { break }
            hostFileTransfer.handleOffer(offer)
        case .fileAccept(let accept):
            guard box.grantedPermissions.contains(.fileTransfer) else { break }
            hostFileTransfer.handleAccept(accept)
        case .fileReject(let reject):
            guard box.grantedPermissions.contains(.fileTransfer) else { break }
            hostFileTransfer.handleReject(reject)
        case .fileChunk(let chunk):
            guard box.grantedPermissions.contains(.fileTransfer) else { break }
            hostFileTransfer.handleChunk(chunk)
        case .fileComplete(let complete):
            guard box.grantedPermissions.contains(.fileTransfer) else { break }
            hostFileTransfer.handleComplete(complete)
        case .remoteCommand(let cmd):
            guard box.grantedPermissions.contains(.remoteCommand) else { break }
            app.remoteCommandService.sendOutput = { [weak box] output in
                guard let box else { return }
                Task { try? await box.connection.sendJSON(.commandOutput, output) }
            }
            app.remoteCommandService.execute(cmd)
            app.auditLog.log(
                sessionID: box.sessionID,
                peerName: box.peerName,
                event: .remoteCommandExecuted,
                detail: "\(cmd.command) \(cmd.arguments.joined(separator: " "))"
            )
        case .systemAction(let action):
            guard box.grantedPermissions.contains(.systemActions) else { break }
            let result = app.systemActionService.perform(action)
            try? await box.connection.sendJSON(.systemActionResult, result)
            app.auditLog.log(
                sessionID: box.sessionID,
                peerName: box.peerName,
                event: .systemAction,
                detail: "\(action.action.rawValue): \(result.success ? "OK" : result.message ?? "failed")"
            )
        case .systemReportRequest(let req):
            guard box.grantedPermissions.contains(.reportInfo) else { break }
            let report = app.systemReportCollector.collect(requestID: req.requestID)
            try? await box.connection.sendJSON(.systemReport, report)
        case .packageInstallReq(let req):
            guard box.grantedPermissions.contains(.packageInstall) else { break }
            let result = await app.packageInstallService.install(req)
            try? await box.connection.sendJSON(.packageInstallResult, result)
            app.auditLog.log(
                sessionID: box.sessionID,
                peerName: box.peerName,
                event: .packageInstalled,
                detail: "\(req.fileName): \(result.success ? "OK" : result.output)"
            )
        case .ping(let p):
            try? await box.connection.sendJSON(.pong, PongMessage(
                clientTimestamp: p.clientTimestamp,
                serverTimestamp: Date().timeIntervalSince1970
            ))
        case .endSession:
            await box.connection.stop()
        default:
            break
        }
    }

    private func routeTrustedReconnect(_ request: PairingRequest, box: HostSessionBox) async {
        guard let app else { return }
        box.pendingRequest = request
        box.state = .awaitingHostApproval
        let policy = accessPolicy(for: request)
        switch policy {
        case .askEveryTime:
            pairing.enqueue(request)
            MacPairingPromptController.shared.present(request: request, runtime: self)
            app.auditLog.log(
                peerName: request.viewer.displayName,
                peerID: request.viewer.id,
                event: .pairingRequested,
                detail: "Trusted reconnect awaiting local approval. Fingerprint: \(request.identityFingerprint.map { String($0.prefix(16)) } ?? "missing")"
            )
        case .alwaysAllow:
            app.auditLog.log(
                peerName: request.viewer.displayName,
                peerID: request.viewer.id,
                event: .pairingApproved,
                detail: "Trusted reconnect auto-approved by saved access policy."
            )
            await approve(request)
        case .alwaysDeny:
            app.auditLog.log(
                peerName: request.viewer.displayName,
                peerID: request.viewer.id,
                event: .pairingRejected,
                detail: "Trusted reconnect auto-denied by saved access policy."
            )
            await reject(request, reason: "Denied by host access policy")
        }
    }

    private func startAdaptiveBitrateLoop() {
        guard let app else { return }
        let abr = app.adaptiveBitrate
        let stats = app.transportStats
        let xstate: MacCaptureCrossState? = {
            if #available(macOS 12.3, *) { return app.macCaptureService.xstate }
            return nil
        }()
        abrTimer?.invalidate()
        abrTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.adaptiveStreamingEnabled == true else { return }
                if abr.evaluate(stats: stats) {
                    if let h264 = xstate?.encoder as? H264FrameEncoder {
                        h264.updateBitrate(abr.currentBitrate)
                        h264.updateFrameRate(abr.currentFPS)
                    }
                }
            }
        }
    }

    private struct PreferenceKeys {
        let autoStartHosting = "ScreenQ.AutoStartHosting"
        let enableClipboard = "ScreenQ.EnableClipboardSync"
        let enableAudio = "ScreenQ.EnableAudioForwarding"
    }
}

@MainActor
final class HostSessionBox: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    nonisolated let connection: ScreenQConnection
    @Published var peerName: String = "Pending peer"
    @Published var state: SessionState = .handshake
    @Published var pendingRequest: PairingRequest?
    @Published var encryptionEnabled: Bool = false
    @Published var encryptionStatusKnown: Bool = false
    var peerID: UUID?
    var peerPlatform: PeerPlatform = .unknown
    var peerAppVersion: String = "?"
    var identityFingerprint: String?
    var grantedPermissions: PermissionSet = .fullAccess
    var sessionID: UUID?

    init(connection: ScreenQConnection) {
        self.connection = connection
    }
}
#endif
