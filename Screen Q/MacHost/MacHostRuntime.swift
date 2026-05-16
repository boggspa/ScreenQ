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
    private var shareTargetRefreshTimer: Timer?
    private var lastShareTargetListMessage: ShareTargetListMessage?
    private var pendingShareTargetRefreshTask: Task<Void, Never>?
    private var didBindPairing = false
    private var didBindShareTargetNotifications = false
    private var adaptiveStreamingEnabled = true
    private var hostHandshakeTimeouts: [UUID: Task<Void, Never>] = [:]
    private var controlChannelBoxesBySession: [UUID: [HostSessionBox]] = [:]

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
        bindShareTargetRefreshNotificationsIfNeeded()
    }

    var readyToHost: Bool {
        app?.macPermissions.screenRecordingGranted == true
    }

    func refreshForHostSurface() async {
        guard let app else { return }
        app.macPermissions.refresh()
        await app.displaySelection.refreshUsingSCShareableContent()
        if #available(macOS 12.3, *) {
            await app.captureTargetService.refresh()
        }
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

            // Auto-activate Curtain Mode when the user has opted in via
            // Settings → Hosting → Privacy → "Curtain Mode default".
            if UserDefaults.standard.bool(forKey: "ScreenQ.Hosting.CurtainModeDefault") {
                app.curtainMode.activate()
            }
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
        app.macInput.resetTransientState()
        // Safe even when not active — CurtainMode no-ops if currently inactive.
        app.curtainMode.deactivate()
        abrTimer?.invalidate()
        abrTimer = nil
        shareTargetRefreshTimer?.invalidate()
        shareTargetRefreshTimer = nil
        pendingShareTargetRefreshTask?.cancel()
        pendingShareTargetRefreshTask = nil
        lastShareTargetListMessage = nil

        let connections = hostConnections
        for box in connections {
            await box.connection.stop()
        }
        let controlBoxes = controlChannelBoxesBySession.values.flatMap { $0 }
        controlChannelBoxesBySession.removeAll()
        for box in controlBoxes {
            await box.connection.stop()
        }
        hostHandshakeTimeouts.values.forEach { $0.cancel() }
        hostHandshakeTimeouts.removeAll()
        hostConnections.removeAll()
        app.macInput.enabled = false
        app.macInput.viewOnly = true
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
        guard box.encryptionEnabled, box.peerID == request.viewer.id else {
            await reject(request, reason: "Secure handshake incomplete")
            return
        }

        let sessionID = UUID()
        let perms = permissions
        let approved = PairingApprovedMessage(
            sessionID: sessionID,
            hostCapabilities: hostCapabilities(),
            controlEnabled: perms.contains(.control),
            permissions: perms
        )
        cancelHostHandshakeTimeout(for: box)
        box.grantedPermissions = perms
        box.sessionID = sessionID
        box.state = viewOnly || !perms.contains(.control) ? .viewOnly : .approved
        box.pendingRequest = nil
        refreshInputGate()
        try? await box.connection.sendJSON(.pairingApproved, approved, waitForCompletion: false)

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

        guard #available(macOS 12.3, *) else { return }
        app.macCaptureService.settings.captureAudio = enableAudio && perms.contains(.audioForward)
        await app.captureTargetService.refresh()
        box.captureTargetID = app.captureTargetService.activeTargetID()
        do {
            try await app.macCaptureService.start(
                subscriberID: box.id,
                targetID: box.captureTargetID,
                onFormat: { [weak box] format in
                    guard let box else { return }
                    try? await box.connection.sendJSON(.videoFormat, format, waitForCompletion: false)
                },
                onFrame: { [weak box] meta, payload in
                    guard let box else { return }
                    box.videoSender.submit(meta: meta, payload: payload)
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
            await failHostSession(
                box,
                code: "captureStartFailed",
                message: "Screen capture failed: \(error.localizedDescription)"
            )
            return
        }

        hostFileTransfer.sendMessage = { [weak box] type, msg in
            guard let box else { return }
            Task { try? await box.connection.sendJSON(type, msg) }
        }

        let cursorDisplayID = app.macCaptureService.activeDisplayID(for: box.id) ?? app.displaySelection.displays.first?.id
        if let cursorDisplayID {
            app.cursorTracker.start(
                displayID: cursorDisplayID,
                subscriberID: box.id,
                frame: app.macCaptureService.activeInputConstraint(for: box.id)?.mappingFrame
            ) { [weak box] msg in
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
        await sendShareTargetList(to: box)
        startAdaptiveBitrateLoop()
        startShareTargetRefreshLoop()
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
            cancelHostHandshakeTimeout(for: box)
            try? await box.connection.sendJSON(.pairingRejected, PairingRejectedMessage(reason: reason))
            await box.connection.stop()
        }
        pairing.remove(request.id)
        MacPairingPromptController.shared.dismiss(request.id)
    }

    func disconnect(_ box: HostSessionBox) async {
        guard let app else { return }
        cancelHostHandshakeTimeout(for: box)
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

    private func bindShareTargetRefreshNotificationsIfNeeded() {
        guard !didBindShareTargetNotifications else { return }
        guard #available(macOS 12.3, *) else { return }
        didBindShareTargetNotifications = true

        let workspaceNotifications = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        for notification in workspaceNotifications {
            NSWorkspace.shared.notificationCenter.publisher(for: notification)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleShareTargetRefresh()
                    }
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleShareTargetRefresh(force: true)
                }
            }
            .store(in: &cancellables)
    }

    @available(macOS 12.3, *)
    private func scheduleShareTargetRefresh(force: Bool = false, delay: TimeInterval = 0.4) {
        guard isSharing else { return }
        pendingShareTargetRefreshTask?.cancel()
        pendingShareTargetRefreshTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.broadcastShareTargetList(force: force)
        }
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

    private func applyStreamQuality(_ message: StreamQualityMessage, for box: HostSessionBox) {
        guard let app else { return }
        let profile = message.profile
        quality = StreamQualityPreference(quality: message.quality).quality
        adaptiveStreamingEnabled = profile.adaptive
        box.adaptiveBitrate.setUserCeiling(
            bitrate: message.targetBitrate,
            fps: message.targetFPS
        )
        if #available(macOS 12.3, *) {
            app.macCaptureService.applyStreamQuality(for: box.id, message)
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
        let targetDisplayID: UInt32? = {
            guard #available(macOS 12.3, *) else { return nil }
            return box.captureTargetID.flatMap { app.captureTargetService.displayID(forTargetID: $0) }
        }()
        let active = targetDisplayID
            ?? app.displaySelection.selectedDisplayID
            ?? infos.first?.id
            ?? 0
        let msg = DisplayListMessage(displays: infos, activeDisplayID: active)
        try? await box.connection.sendJSON(.displayList, msg)
    }

    private func sendShareTargetList(to box: HostSessionBox) async {
        guard let app else { return }
        guard #available(macOS 12.3, *) else { return }
        await app.captureTargetService.refresh()
        if box.captureTargetID == nil {
            box.captureTargetID = app.captureTargetService.activeTargetID()
        }
        let message = app.captureTargetService.targetListMessage(activeTargetID: box.captureTargetID)
        lastShareTargetListMessage = message
        try? await box.connection.sendJSON(
            .shareTargetList,
            message,
            waitForCompletion: false
        )
    }

    @available(macOS 12.3, *)
    private func broadcastShareTargetList(force: Bool = false) async {
        guard let app else { return }
        await app.captureTargetService.refresh()
        let message = app.captureTargetService.targetListMessage()
        guard force || message != lastShareTargetListMessage else { return }
        lastShareTargetListMessage = message

        let activeBoxes = hostConnections.filter { box in
            hostSession(box, allows: .observe)
        }
        for box in activeBoxes {
            let perViewerMessage = app.captureTargetService.targetListMessage(activeTargetID: box.captureTargetID)
            try? await box.connection.sendJSON(.shareTargetList, perViewerMessage, waitForCompletion: false)
        }
    }

    @available(macOS 12.3, *)
    private func restartCapture(for box: HostSessionBox, failureCode: String, failurePrefix: String) async {
        guard let app else { return }
        do {
            try await app.macCaptureService.restartSubscriber(
                box.id,
                targetID: box.captureTargetID,
                onFormat: { [weak box] format in
                    guard let box else { return }
                    try? await box.connection.sendJSON(.videoFormat, format, waitForCompletion: false)
                },
                onFrame: { [weak box] meta, payload in
                    guard let box else { return }
                    box.videoSender.submit(meta: meta, payload: payload)
                }
            )
            let cursorDisplayID = app.macCaptureService.activeDisplayID(for: box.id) ?? app.displaySelection.displays.first?.id
            if let cursorDisplayID {
                app.cursorTracker.start(
                    displayID: cursorDisplayID,
                    subscriberID: box.id,
                    frame: app.macCaptureService.activeInputConstraint(for: box.id)?.mappingFrame
                ) { [weak box] msg in
                    guard let box else { return }
                    Task { try? await box.connection.sendJSON(.cursorUpdate, msg) }
                }
            }
        } catch {
            await failHostSession(
                box,
                code: failureCode,
                message: "\(failurePrefix): \(error.localizedDescription)"
            )
        }
    }

    private func acceptIncoming(_ nw: NWConnection) async {
        guard let app else { return }
        let conn = await app.connectionManager.adopt(nw, role: .host)
        let box = HostSessionBox(connection: conn)
        hostConnections.append(box)
        scheduleHostHandshakeTimeout(for: box)

        let stream = await conn.inboundMessages()
        for await message in stream {
            await handleHostInbound(message, box: box)
        }
        await cleanupDisconnectedHostSession(box, reason: "Remote disconnected")
        await stopSessionServicesIfIdle()
    }

    private func cleanupDisconnectedHostSession(_ box: HostSessionBox, reason: String) async {
        guard let app else { return }
        cancelHostHandshakeTimeout(for: box)
        if box.isAuxiliaryControlChannel {
            removeAuxiliaryControlChannel(box)
            box.state = .ended(reason: reason)
            return
        }
        if let pendingRequest = box.pendingRequest {
            pairing.remove(pendingRequest.id)
            MacPairingPromptController.shared.dismiss(pendingRequest.id)
            box.pendingRequest = nil
        }
        if let sessionID = box.sessionID {
            await closeAuxiliaryControlChannels(for: sessionID)
        }
        if #available(macOS 12.3, *) {
            await app.macCaptureService.removeSubscriber(box.id)
        }
        app.cursorTracker.removeSubscriber(box.id)
        if box.grantedPermissions.contains(.control) || box.state.allowsInputInjection {
            app.macInput.resetTransientState()
        }
        if let sessionID = box.sessionID {
            app.auditLog.log(
                sessionID: sessionID,
                peerName: box.peerName,
                peerID: box.peerID,
                event: .sessionEnded,
                detail: reason
            )
        }
        box.state = .ended(reason: reason)
        hostConnections.removeAll(where: { $0.id == box.id })
        refreshInputGate()
    }

    private func registerAuxiliaryControlChannel(_ box: HostSessionBox, for sessionID: UUID) {
        box.isAuxiliaryControlChannel = true
        controlChannelBoxesBySession[sessionID, default: []].append(box)
        hostConnections.removeAll(where: { $0.id == box.id })
    }

    private func removeAuxiliaryControlChannel(_ box: HostSessionBox) {
        guard let sessionID = box.sessionID else { return }
        controlChannelBoxesBySession[sessionID]?.removeAll(where: { $0.id == box.id })
        if controlChannelBoxesBySession[sessionID]?.isEmpty == true {
            controlChannelBoxesBySession.removeValue(forKey: sessionID)
        }
    }

    private func closeAuxiliaryControlChannels(for sessionID: UUID) async {
        let boxes = controlChannelBoxesBySession.removeValue(forKey: sessionID) ?? []
        for box in boxes {
            box.state = .ended(reason: "Primary session ended")
            await box.connection.stop()
        }
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
        app.macInput.resetTransientState()
        abrTimer?.invalidate()
        abrTimer = nil
        shareTargetRefreshTimer?.invalidate()
        shareTargetRefreshTimer = nil
        pendingShareTargetRefreshTask?.cancel()
        pendingShareTargetRefreshTask = nil
        lastShareTargetListMessage = nil
    }

    private func failHostSession(
        _ box: HostSessionBox,
        code: String,
        message: String
    ) async {
        guard let app else { return }
        app.lastError = message
        box.state = .failed(reason: message)
        refreshInputGate()
        Logger.shared.error(message)
        app.auditLog.log(
            sessionID: box.sessionID,
            peerName: box.peerName,
            peerID: box.peerID,
            event: .error,
            detail: message
        )
        cancelHostHandshakeTimeout(for: box)
        try? await box.connection.sendJSON(.error, ErrorMessage(code: code, message: message), waitForCompletion: false)
        await box.connection.stop()
    }

    private func scheduleHostHandshakeTimeout(for box: HostSessionBox) {
        hostHandshakeTimeouts[box.id]?.cancel()
        hostHandshakeTimeouts[box.id] = Task { [weak self, weak box] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, let box else { return }
            switch box.state {
            case .handshake, .awaitingHostApproval:
                await self.failHostSession(
                    box,
                    code: "handshakeTimeout",
                    message: "Screen Q handshake timed out before the viewer completed pairing."
                )
            default:
                break
            }
        }
    }

    private func cancelHostHandshakeTimeout(for box: HostSessionBox) {
        hostHandshakeTimeouts.removeValue(forKey: box.id)?.cancel()
    }

    private func refreshInputGate() {
        guard let app else { return }
        let hasControlSession = hostConnections.contains { box in
            box.state.allowsInputInjection && !viewOnly && hostSession(box, allows: .control)
        }
        app.macInput.enabled = hasControlSession
        app.macInput.viewOnly = viewOnly || !hasControlSession
    }

    private func hostSession(_ box: HostSessionBox, allows permission: PermissionSet) -> Bool {
        box.encryptionEnabled &&
            box.sessionID != nil &&
            box.state.allowsPrivilegedHostMessages &&
            box.grantedPermissions.contains(permission)
    }

    private func handleControlChannelHello(_ hello: HelloMessage, box: HostSessionBox) async {
        guard let app else { return }
        guard let sessionID = hello.sessionID,
              let viewerPublicKey = hello.ephemeralPublicKey else {
            try? await box.connection.sendJSON(.error, ErrorMessage(
                code: "controlChannelRejected",
                message: "Control channel attach request was incomplete."
            ), waitForCompletion: false)
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

        guard let primary = hostConnections.first(where: { candidate in
            !candidate.isAuxiliaryControlChannel &&
            candidate.sessionID == sessionID &&
            candidate.peerID == hello.peerID &&
            candidate.identityFingerprint == viewerIdentityFingerprint &&
            candidate.state.allowsInputInjection &&
            hostSession(candidate, allows: .control)
        }), !viewOnly else {
            try? await box.connection.sendJSON(.error, ErrorMessage(
                code: "controlChannelRejected",
                message: "No approved controllable session matched this control channel."
            ), waitForCompletion: false)
            await box.connection.stop()
            return
        }

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
                code: "controlChannelEncryptionFailed",
                message: "Unable to negotiate Screen Q control channel encryption."
            ), waitForCompletion: false)
            await box.connection.stop()
            return
        }

        box.peerName = "\(primary.peerName) control"
        box.peerID = hello.peerID
        box.peerPlatform = hello.platform
        box.peerAppVersion = hello.appVersion
        box.identityFingerprint = viewerIdentityFingerprint
        box.grantedPermissions = primary.grantedPermissions
        box.sessionID = sessionID
        box.primaryHostSessionBoxID = primary.id
        box.captureTargetID = primary.captureTargetID
        box.state = primary.state
        box.encryptionEnabled = true
        box.encryptionStatusKnown = true

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
            trustedByHost: true
        )
        try? await box.connection.sendJSON(.helloAck, ack, waitForCompletion: false)
        await box.connection.enableEncryption(keyMaterial)
        cancelHostHandshakeTimeout(for: box)
        registerAuxiliaryControlChannel(box, for: sessionID)
        Logger.shared.info("Attached Screen Q control channel for \(primary.peerName)")
    }

    private func primarySessionBox(for box: HostSessionBox) -> HostSessionBox {
        guard box.isAuxiliaryControlChannel else { return box }
        if let primaryID = box.primaryHostSessionBoxID,
           let primary = hostConnections.first(where: { $0.id == primaryID }) {
            return primary
        }
        guard let sessionID = box.sessionID, let peerID = box.peerID else { return box }
        return hostConnections.first { candidate in
            !candidate.isAuxiliaryControlChannel &&
            candidate.sessionID == sessionID &&
            candidate.peerID == peerID
        } ?? box
    }

    private func handleHostInbound(_ message: InboundMessage, box: HostSessionBox) async {
        guard let app else { return }
        switch message {
        case .hello(let hello):
            if hello.channel == .control {
                await handleControlChannelHello(hello, box: box)
                return
            }
            guard box.peerID == nil else {
                Logger.shared.warn("Ignoring duplicate Screen Q hello from \(hello.displayName) on session \(box.id)")
                return
            }
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
            try? await box.connection.sendJSON(.helloAck, ack, waitForCompletion: false)
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
            guard box.encryptionEnabled, box.peerID == req.viewerID else {
                await failHostSession(
                    box,
                    code: "encryptionRequired",
                    message: "Pairing requires an encrypted Screen Q handshake."
                )
                return
            }
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
        case .inputEvent(let input):
            if box.state.allowsInputInjection && !viewOnly && hostSession(box, allows: .control) {
                guard !input.isExpired() else {
                    Logger.shared.debug("Dropped stale input \(input.event.kind.rawValue) from \(box.peerName)")
                    break
                }
                if #available(macOS 12.3, *) {
                    let routingBox = primarySessionBox(for: box)
                    app.macInput.handle(
                        input.event,
                        displayID: app.macCaptureService.activeDisplayID(for: routingBox.id),
                        inputConstraint: app.macCaptureService.activeInputConstraint(for: routingBox.id)
                    )
                } else {
                    app.macInput.handle(input.event)
                }
            }
        case .clipboardOffer(let offer):
            guard enableClipboard, hostSession(box, allows: .clipboard) else { break }
            app.clipboardSync.handleRemoteOffer(offer) { request in
                Task { try? await box.connection.sendJSON(.clipboardRequest, request) }
            }
        case .clipboardRequest(let request):
            guard enableClipboard, hostSession(box, allows: .clipboard) else { break }
            app.clipboardSync.handleRequest(request)
        case .clipboardData(let data):
            guard enableClipboard, hostSession(box, allows: .clipboard) else { break }
            app.clipboardSync.applyRemoteClipboard(data)
        case .displaySwitch(let switchMsg):
            guard hostSession(box, allows: .observe) else { break }
            if #available(macOS 12.3, *) {
                box.captureTargetID = switchMsg.displayID == DisplaySelectionService.allDisplaysID
                    ? CaptureTargetSelectionService.allDisplaysTargetID
                    : CaptureTargetSelectionService.displayTargetID(switchMsg.displayID)
                await restartCapture(for: box, failureCode: "captureDisplaySwitchFailed", failurePrefix: "Display switch failed")
                await sendDisplayList(to: box)
                await sendShareTargetList(to: box)
            }
        case .shareTargetSwitch(let switchMsg):
            guard hostSession(box, allows: .observe) else { break }
            guard #available(macOS 12.3, *) else { break }
            box.captureTargetID = switchMsg.targetID
            await restartCapture(for: box, failureCode: "captureTargetSwitchFailed", failurePrefix: "Share target switch failed")
            await sendDisplayList(to: box)
            await sendShareTargetList(to: box)
        case .streamQuality(let qualityMessage):
            guard hostSession(box, allows: .observe) else { break }
            applyStreamQuality(sanitizedStreamQualityMessage(qualityMessage, for: box.peerPlatform), for: box)
        case .viewerViewport(let viewport):
            guard hostSession(box, allows: .observe) else { break }
            if #available(macOS 12.3, *) {
                app.macCaptureService.applyViewerViewport(
                    for: box.id,
                    viewport,
                    adaptiveEnabled: viewport.adaptiveEnabled
                )
            }
        case .fileOffer(let offer):
            guard hostSession(box, allows: .fileTransfer) else { break }
            hostFileTransfer.handleOffer(offer)
        case .fileAccept(let accept):
            guard hostSession(box, allows: .fileTransfer) else { break }
            hostFileTransfer.handleAccept(accept)
        case .fileReject(let reject):
            guard hostSession(box, allows: .fileTransfer) else { break }
            hostFileTransfer.handleReject(reject)
        case .fileChunk(let chunk):
            guard hostSession(box, allows: .fileTransfer) else { break }
            hostFileTransfer.handleChunk(chunk)
        case .fileComplete(let complete):
            guard hostSession(box, allows: .fileTransfer) else { break }
            hostFileTransfer.handleComplete(complete)
        case .remoteCommand(let cmd):
            guard hostSession(box, allows: .remoteCommand) else { break }
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
            guard hostSession(box, allows: .systemActions) else { break }
            let result = app.systemActionService.perform(action)
            try? await box.connection.sendJSON(.systemActionResult, result)
            app.auditLog.log(
                sessionID: box.sessionID,
                peerName: box.peerName,
                event: .systemAction,
                detail: "\(action.action.rawValue): \(result.success ? "OK" : result.message ?? "failed")"
            )
        case .systemReportRequest(let req):
            guard hostSession(box, allows: .reportInfo) else { break }
            let report = app.systemReportCollector.collect(requestID: req.requestID)
            try? await box.connection.sendJSON(.systemReport, report)
        case .packageInstallReq(let req):
            guard hostSession(box, allows: .packageInstall) else { break }
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
        case .stats(let stats):
            guard hostSession(box, allows: .observe) else { break }
            box.transportStats.applyRemoteStats(stats)
            app.transportStats.applyRemoteStats(stats)
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
        abrTimer?.invalidate()
        abrTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard #available(macOS 12.3, *) else { return }
                for box in self.hostConnections where box.state == .streaming || box.state == .viewOnly {
                    if box.adaptiveBitrate.evaluate(stats: box.transportStats) {
                        app.macCaptureService.updateAdaptiveBitrate(
                            for: box.id,
                            bitrate: box.adaptiveBitrate.currentBitrate,
                            fps: box.adaptiveBitrate.currentFPS
                        )
                    }
                }
            }
        }
    }

    private func startShareTargetRefreshLoop() {
        guard #available(macOS 12.3, *) else { return }
        shareTargetRefreshTimer?.invalidate()
        shareTargetRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.broadcastShareTargetList()
            }
        }
    }

    private struct PreferenceKeys {
        let autoStartHosting = "ScreenQ.AutoStartHosting"
        let enableClipboard = "ScreenQ.EnableClipboardSync"
        let enableAudio = "ScreenQ.EnableAudioForwarding"
    }
}

nonisolated private final class HostRealtimeVideoSender: @unchecked Sendable {
    private struct PendingFrame: Sendable {
        let meta: VideoFrameMeta
        let payload: Data
    }

    private let connection: ScreenQConnection
    private let lock = NSLock()
    private var latestFrame: PendingFrame?
    private var isDraining = false
    private var droppedFrames = 0
    private let staleFrameAgeSeconds: TimeInterval = 1.5

    init(connection: ScreenQConnection) {
        self.connection = connection
    }

    func submit(meta: VideoFrameMeta, payload: Data) {
        guard !isStale(meta: meta) else {
            recordDrop()
            return
        }

        let shouldStartDrain: Bool
        lock.lock()
        if latestFrame != nil {
            droppedFrames &+= 1
        }
        latestFrame = PendingFrame(meta: meta, payload: payload)
        shouldStartDrain = !isDraining
        if shouldStartDrain {
            isDraining = true
        }
        lock.unlock()

        if shouldStartDrain {
            Task { await drain() }
        }
    }

    private func drain() async {
        while true {
            guard let frame = takeLatestFrame() else { return }
            guard !isStale(meta: frame.meta) else {
                recordDrop()
                continue
            }
            do {
                try await connection.sendVideoFrame(
                    meta: frame.meta,
                    payload: frame.payload,
                    waitForCompletion: true
                )
            } catch {
                return
            }
        }
    }

    private func takeLatestFrame() -> PendingFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame = latestFrame else {
            isDraining = false
            return nil
        }
        latestFrame = nil
        return frame
    }

    private func isStale(meta: VideoFrameMeta) -> Bool {
        guard let captureWallClockTimestamp = meta.captureWallClockTimestamp else { return false }
        return Date().timeIntervalSince1970 - captureWallClockTimestamp > staleFrameAgeSeconds
    }

    private func recordDrop() {
        lock.lock()
        droppedFrames &+= 1
        let count = droppedFrames
        lock.unlock()
        if count > 0 && count % 30 == 0 {
            Logger.shared.debug("Dropped \(count) host video frames before send to keep live latency bounded")
        }
    }
}

@MainActor
final class HostSessionBox: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    nonisolated let connection: ScreenQConnection
    fileprivate nonisolated let videoSender: HostRealtimeVideoSender
    @Published var peerName: String = "Pending peer"
    @Published var state: SessionState = .handshake
    @Published var pendingRequest: PairingRequest?
    @Published var encryptionEnabled: Bool = false
    @Published var encryptionStatusKnown: Bool = false
    var peerID: UUID?
    var peerPlatform: PeerPlatform = .unknown
    var peerAppVersion: String = "?"
    var identityFingerprint: String?
    var grantedPermissions: PermissionSet = []
    var sessionID: UUID?
    var isAuxiliaryControlChannel: Bool = false
    var primaryHostSessionBoxID: UUID?
    var captureTargetID: String?
    let transportStats = TransportStats()
    let adaptiveBitrate = AdaptiveBitrateController()

    init(connection: ScreenQConnection) {
        self.connection = connection
        self.videoSender = HostRealtimeVideoSender(connection: connection)
    }
}
#endif
