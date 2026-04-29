//
//  HostMacView.swift
//  Screen Q
//

#if os(macOS)
import SwiftUI
import AppKit
import Combine
import Network

struct HostMacView: View {

    @EnvironmentObject private var app: AppState
    @StateObject private var pairing = PairingManager()
    @State private var quality: Double = StreamQualityPreference.defaultQuality
    @State private var showStopConfirm = false
    @State private var hostConnections: [HostSessionBox] = []
    @State private var statsRefreshSink: AnyObject?
    @AppStorage("ScreenQ.AutoStartHosting") private var autoStartHosting: Bool = false
    @AppStorage("ScreenQ.EnableClipboardSync") private var enableClipboard: Bool = true
    @AppStorage("ScreenQ.EnableAudioForwarding") private var enableAudio: Bool = false
    @State private var abrTimer: Timer?
    @StateObject private var hostFileTransfer = FileTransferService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionsCard
                displayCard
                advertiseCard
                if app.hostIsSharing { connectInfoCard }
                permissionsGrantCard
                pairingCard
                sessionsCard
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Host this Mac")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showStopConfirm = true
                } label: {
                    Label("Stop Sharing Now", systemImage: "stop.circle.fill")
                }
                .foregroundColor(.red)
                .disabled(!app.hostIsSharing)
            }
        }
        .alert(isPresented: $showStopConfirm) {
            Alert(
                title: Text("Stop sharing this Mac?"),
                message: Text("All connected viewers will be disconnected. You can re-share at any time."),
                primaryButton: .destructive(Text("Stop")) { stopHosting() },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            app.macPermissions.refresh()
            Task {
                await app.displaySelection.refreshUsingSCShareableContent()
                if autoStartHosting && !app.hostIsSharing && readyToHost {
                    await startHosting()
                }
            }
        }
        .onDisappear {
            if app.selectedRole != .hostMac && app.hostIsSharing {
                stopHosting()
            }
        }
        .onReceive(app.$hostStopRequestID.compactMap { $0 }) { _ in
            stopHosting()
        }
    }

    // MARK: - Cards

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Permissions")
            PermissionsView()
                .environmentObject(app.macPermissions)
        }
        .panel()
    }

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Display")
            if app.displaySelection.displays.isEmpty {
                Text("No displays detected yet. Grant Screen Recording, then click Refresh.")
                    .foregroundColor(.secondary)
            } else {
                Picker("Display", selection: Binding(
                    get: { app.displaySelection.selectedDisplayID ?? app.displaySelection.displays.first?.id ?? 0 },
                    set: { app.displaySelection.selectedDisplayID = $0 }
                )) {
                    ForEach(app.displaySelection.displayOptions()) { d in
                        Text("\(d.name) — \(d.pixelWidth)×\(d.pixelHeight)")
                            .tag(d.id)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Button("Refresh Displays") {
                    Task { await app.displaySelection.refreshUsingSCShareableContent() }
                }
                Spacer()
                qualitySlider
            }
        }
        .panel()
    }

    private var qualitySlider: some View {
        HStack(spacing: 8) {
            Text("Quality")
                .foregroundColor(.secondary)
            Slider(value: $quality, in: 0.2...1.0)
                .frame(width: 200)
                .onChange(of: quality) { newValue in
                    if #available(macOS 12.3, *) {
                        applyStreamQuality(StreamQualityPreference(quality: newValue))
                    }
                }
            Text("\(Int(quality * 100))%")
                .font(.system(.body, design: .monospaced))
        }
    }

    private func applyStreamQuality(_ preference: StreamQualityPreference) {
        quality = preference.quality
        app.adaptiveBitrate.setUserCeiling(
            bitrate: preference.nativeTargetBitrate,
            fps: preference.nativeTargetFPS
        )
        if #available(macOS 12.3, *) {
            app.macCaptureService.applyStreamQuality(preference)
        }
    }

    private var advertiseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Advertise on local network")
            HStack {
                Toggle("View only (block input)", isOn: $app.hostViewOnly)
                Spacer()
            }
            HStack {
                Button(app.hostIsSharing ? "Hosting…" : "Start Hosting") {
                    Task { await startHosting() }
                }
                .disabled(app.hostIsSharing || !readyToHost)
                .buttonStyle(.bordered)

                Spacer()

                Text("Bonjour: _screenq._tcp · port \(ScreenQProtocol.defaultPort)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Toggle("Auto-start hosting on launch", isOn: $autoStartHosting)
                .font(.footnote)
                .foregroundColor(.secondary)
            Toggle("Share clipboard", isOn: $enableClipboard)
                .font(.footnote)
                .foregroundColor(.secondary)
                .onChange(of: enableClipboard) { val in
                    app.clipboardSync.enabled = val
                }
            Toggle("Forward audio", isOn: $enableAudio)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .panel()
    }

    @State private var listeningPort: UInt16 = ScreenQProtocol.defaultPort
    @State private var listeningAddresses: [LocalInterface] = []

    private var connectInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Connect from another device")
            Text("Give your viewer one of these addresses and port \(listeningPort):")
                .font(.footnote)
                .foregroundColor(.secondary)

            if listeningAddresses.isEmpty {
                Text("No connectable addresses detected. Check Wi-Fi or Ethernet.")
                    .foregroundColor(.orange)
                    .font(.footnote)
            } else {
                ForEach(listeningAddresses) { iface in
                    HStack(spacing: 8) {
                        Image(systemName: iface.kind == .tailscale ? "network" : "wifi")
                            .foregroundColor(iface.kind == .tailscale ? .blue : .green)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(iface.address):\(listeningPort)")
                                .font(.system(.body, design: .monospaced))

                            Text(iface.humanLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(iface.address):\(listeningPort)", forType: .string)
                            #endif
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }
                    .padding(.vertical, 4)
                }
            }

            Text("Bonjour (same LAN) discovers automatically. For Tailscale or VPN, viewers use **Manual Connect**.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .panel()
        .onAppear {
            Task {
                let info = await app.bonjourAdvertiser.listeningInfo()
                listeningPort = info.port
                listeningAddresses = info.addresses
            }
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Pairing")
            HStack(alignment: .firstTextBaseline) {
                Text("Code")
                    .font(.headline)
                Text(pairing.currentCode)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))

                Spacer()
                Button("Regenerate") { pairing.regenerateCode() }
            }
            Text("Tell your viewer this code. Codes expire after 5 minutes. Codes are never sent over the network until the viewer types them in.")
                .font(.footnote)
                .foregroundColor(.secondary)
            if !pairing.pendingRequests.isEmpty {
                Divider()
                Text("Incoming requests")
                    .font(.headline)
                ForEach(pairing.pendingRequests) { req in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(req.viewer.displayName)
                            Text("Pairing code: \(req.claimedCode)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Reject") {
                            Task { await reject(req) }
                        }
                        .foregroundColor(.red)
                        Button("Approve") {
                            Task { await approve(req) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .panel()
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Sessions")
            if hostConnections.isEmpty {
                Text(app.hostIsSharing ? "Waiting for viewers to connect…" : "Not hosting.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(hostConnections) { box in
                    HStack {
                        Image(systemName: "rectangle.connected.to.line.below")
                        Text(box.peerName)
                        Spacer()
                        Text(box.state.humanDescription)
                            .foregroundColor(.secondary)
                            .font(.caption)
                        if box.state.isActive && box.encryptionStatusKnown {
                            Text(box.encryptionEnabled ? "Encrypted" : "Unencrypted")
                                .foregroundColor(box.encryptionEnabled ? .green : .orange)
                                .font(.caption.bold())
                        }
                        Button {
                            Task { await disconnect(box) }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .panel()
    }

    // MARK: - State helpers

    private var readyToHost: Bool {
        app.macPermissions.screenRecordingGranted
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.title2).bold()
    }

    // MARK: - Actions

    private func startHosting() async {
        do {
            try await app.bonjourAdvertiser.start(
                deviceName: app.localDeviceName,
                capabilities: hostCapabilities(),
                deviceID: app.localDeviceID,
                metadata: [
                    ScreenQProtocol.TXT.presence: "nativeHost",
                    ScreenQProtocol.TXT.acceptsScreenQ: "true"
                ]
            ) { connection in
                Task { await acceptIncoming(connection) }
            }
            // Begin capture lazily (only after a viewer is approved). Here we
            // just flip the flag so UI reflects "advertising" mode.
            app.hostIsSharing = true
            app.session = .advertising
            app.macPermissions.markLocalNetworkAttempted()
        } catch {
            app.lastError = error.localizedDescription
            Logger.shared.error("startHosting failed: \(error.localizedDescription)")
        }
    }

    private func stopHosting() {
        Task {
            try? await app.bonjourAdvertiser.stop()
            if #available(macOS 12.3, *) { await app.macCaptureService.stop() }
            app.cursorTracker.stop()
            app.clipboardSync.stop()
            if #available(macOS 13.0, *) { app.audioCaptureService.stop() }
            abrTimer?.invalidate()
            abrTimer = nil
            for box in hostConnections {
                await box.connection.stop()
            }
            await MainActor.run {
                hostConnections.removeAll()
                app.hostIsSharing = false
                app.session = .idle
                pairing.pendingRequests.removeAll()
            }
        }
    }

    private func hostCapabilities() -> Capabilities {
        var caps = Capabilities.macHostDefault
        caps.supportsControl = !app.hostViewOnly
        caps.supportsClipboard = enableClipboard
        caps.supportsAudio = enableAudio
        return caps

    }

    private func sendDisplayList(to box: HostSessionBox) async {
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
        let conn = await app.connectionManager.adopt(nw, role: .host)
        let box = HostSessionBox(connection: conn)
        await MainActor.run { hostConnections.append(box) }

        let stream = await conn.inboundMessages()
        for await message in stream {
            await handleHostInbound(message, box: box)
        }
        if #available(macOS 12.3, *) {
            app.macCaptureService.removeSubscriber(box.id)
        }
        app.cursorTracker.removeSubscriber(box.id)
        await MainActor.run {
            hostConnections.removeAll(where: { $0.id == box.id })
        }
        await stopSessionServicesIfIdle()
    }

    private func stopSessionServicesIfIdle() async {
        guard hostConnections.isEmpty else { return }
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

            await MainActor.run {
                box.peerName = hello.displayName
                box.peerID = hello.peerID
                box.peerPlatform = hello.platform
                box.peerAppVersion = hello.appVersion
                box.identityFingerprint = viewerIdentityFingerprint
                box.state = .handshake
            }
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
                pairing.updateLastSeen(peerID: hello.peerID)
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
                await MainActor.run {
                    box.pendingRequest = pr
                    pairing.enqueue(pr)
                    box.state = .awaitingHostApproval
                }
                app.auditLog.log(
                    peerName: hello.displayName,
                    peerID: hello.peerID,
                    event: .pairingRequested,
                    detail: "Trusted reconnect awaiting local approval. Fingerprint: \(viewerIdentityFingerprint.map { String($0.prefix(16)) } ?? "missing")"
                )
            }
        case .pairingRequest(let req):
            await MainActor.run {
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
            }
            app.auditLog.log(
                peerName: req.displayName,
                peerID: req.viewerID,
                event: .pairingRequested,
                detail: "Pairing request received. Identity fingerprint: \(box.identityFingerprint.map { String($0.prefix(16)) } ?? "missing")"
            )
        case .inputEvent(let event):
            // Only inject if the user has approved AND control permission is granted.
            if box.state.allowsInputInjection && !app.hostViewOnly && box.grantedPermissions.contains(.control) {
                app.macInput.handle(event)
            }
        case .clipboardOffer(let offer):
            guard enableClipboard, box.grantedPermissions.contains(.clipboard) else { break }
            // Remote viewer has new clipboard data — request it.
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
            // Viewer requested a different display.
            await MainActor.run {
                app.displaySelection.selectedDisplayID = switchMsg.displayID
            }
            // Restart capture on the new display.
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
            } // end #available
        case .streamQuality(let qualityMessage):
            guard box.encryptionEnabled else { break }
            applyStreamQuality(StreamQualityPreference(quality: qualityMessage.quality))
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

    private func approve(_ request: PairingRequest) async {
        guard request.trustedReconnect || pairing.codeIsValid(request.claimedCode) else {
            await reject(request)
            return
        }
        guard let box = hostConnections.first(where: { $0.pendingRequest?.id == request.id }) else { return }
        let sessionID = UUID()
        let perms = app.hostPermissions
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

        await MainActor.run {
            pairing.remove(request.id)
            box.state = app.hostViewOnly || !perms.contains(.control) ? .viewOnly : .approved
            box.pendingRequest = nil
            app.macInput.enabled = perms.contains(.control)
            app.macInput.viewOnly = app.hostViewOnly || !perms.contains(.control)
        }

        // Start capture for this session (idempotent — start checks isCapturing).
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
            await MainActor.run { box.state = app.hostViewOnly || !perms.contains(.control) ? .viewOnly : .streaming }
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

        // Wire file transfer for the host side.
        hostFileTransfer.sendMessage = { [weak box] type, msg in
            guard let box else { return }
            Task { try? await box.connection.sendJSON(type, msg) }
        }

        // Start cursor tracking.
        let cursorDisplayID = app.displaySelection.selectedDisplayID ?? app.displaySelection.displays.first?.id
        if let cursorDisplayID {
            app.cursorTracker.start(displayID: cursorDisplayID, subscriberID: box.id) { [weak box] msg in
                guard let box else { return }
                Task { try? await box.connection.sendJSON(.cursorUpdate, msg) }
            }
        }

        // Start clipboard sync.
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

        // Send display list so viewer can switch.
        await sendDisplayList(to: box)

        // Start adaptive bitrate evaluation loop.
        let abr = app.adaptiveBitrate
        let stats = app.transportStats
        let xstate: MacCaptureCrossState? = {
            if #available(macOS 12.3, *) { return app.macCaptureService.xstate }
            return nil
        }()
        abrTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                if abr.evaluate(stats: stats) {
                    if let h264 = xstate?.encoder as? H264FrameEncoder {
                        h264.updateBitrate(abr.currentBitrate)
                    }
                }
            }
        }
    }

    private func reject(_ request: PairingRequest) async {
        guard let box = hostConnections.first(where: { $0.pendingRequest?.id == request.id }) else {
            pairing.remove(request.id)
            return
        }
        try? await box.connection.sendJSON(.pairingRejected, PairingRejectedMessage(reason: "Rejected by host"))
        pairing.remove(request.id)
        await box.connection.stop()
    }

    private func disconnect(_ box: HostSessionBox) async {
        try? await box.connection.sendJSON(.endSession, EndSessionMessage(reason: "Host disconnected"))
        await box.connection.stop()
        app.auditLog.log(
            sessionID: box.sessionID,
            peerName: box.peerName,
            event: .sessionEnded,
            detail: "Host disconnected"
        )
    }

    // MARK: - Granular Permissions Card

    private var permissionsGrantCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Viewer Permissions")
            Text("Choose what connected viewers are allowed to do.")
                .font(.footnote)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(PermissionSet.allCases, id: \.label) { item in
                    Toggle(isOn: Binding(
                        get: { app.hostPermissions.contains(item.flag) },
                        set: { enabled in
                            if enabled {
                                app.hostPermissions.insert(item.flag)
                            } else {
                                app.hostPermissions.remove(item.flag)
                            }
                        }
                    )) {
                        Label(item.label, systemImage: item.icon)
                            .font(.footnote)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack(spacing: 12) {
                Button("Full Access") { app.hostPermissions = .fullAccess }
                    .font(.caption)
                Button("Standard") { app.hostPermissions = .standard }
                    .font(.caption)
                Button("View Only") { app.hostPermissions = .viewOnly }
                    .font(.caption)
            }
        }
        .panel()
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

private extension View {
    func panel() -> some View {
        self.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.gray.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }
}
#endif
