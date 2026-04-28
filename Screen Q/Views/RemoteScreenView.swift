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
    @Published var encryptionEnabled: Bool = false
    @Published var encryptionStatusKnown: Bool = false

    private weak var app: AppState?
    private var secureSessionFactory: SecureSessionFactory?
    private var localEphemeralPublicKey: String?
    private var localPeerID: UUID?
    private var localIdentityFingerprint: String?

    init(
        connection: ScreenQConnection,
        peerLabel: String,
        app: AppState,
        controlPreferenceScope: ViewerControlPreferenceScope? = nil
    ) {
        self.connection = connection
        self.peerLabel = peerLabel
        self.app = app
        self.controlPreferenceScope = controlPreferenceScope ?? ViewerControlPreferenceScope(
            connectionProtocol: .screenQ,
            host: peerLabel,
            port: ScreenQProtocol.defaultPort
        )

        inputMapper.sendEvent = { [weak self] event in
            guard let self else { return }
            Task { try? await self.connection.sendJSON(.inputEvent, event) }
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
        let inbound = await connection.inboundMessages()
        Task {
            for await message in inbound {
                await handle(message)
            }
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

    func tearDown(reason: String) async {
        try? await connection.sendJSON(.endSession, EndSessionMessage(reason: reason))
        await connection.stop()
        phase = .ended(reason: reason)
    }

    private func handle(_ message: InboundMessage) async {
        switch message {
        case .helloAck(let ack):
            hostCapabilities = ack.capabilities
            encryptionEnabled = ack.encryptionEnabled
            encryptionStatusKnown = true
            guard ack.encryptionEnabled,
                  let hostPublicKey = ack.ephemeralPublicKey,
                  let viewerPublicKey = localEphemeralPublicKey,
                  let secureSessionFactory else {
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
            hostCapabilities = approved.hostCapabilities
            grantedPermissions = approved.permissions ?? (approved.controlEnabled ? .standard : .viewOnly)
            inputMapper.isControlEnabled = grantedPermissions.contains(.control) && approved.hostCapabilities.supportsControl
            phase = grantedPermissions.contains(.control) ? .approved : .viewOnly
        case .pairingRejected(let r):
            phase = .failed(reason: r.reason)
        case .videoFormat(let format):
            renderer.updateFormat(format)
            phase = inputMapper.isControlEnabled ? .streaming : .viewOnly
        case .videoFrame(let meta, let payload):
            renderer.ingest(meta: meta, payload: payload, stats: stats)
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
            stats.recordRoundTrip(millis: (now - p.clientTimestamp) * 1000)
        case .endSession(let e):
            audioPlayer.stop()
            phase = .ended(reason: e.reason)
        case .error(let e):
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

struct RemoteScreenView: View {

    @EnvironmentObject private var app: AppState
    @ObservedObject var session: ViewerSession
    @ObservedObject private var renderer: RemoteScreenRenderer
    @ObservedObject private var stats: TransportStats
    var onDisconnect: () -> Void

    #if os(iOS)
    @StateObject private var controlPreferences: ViewerControlPreferences
    @StateObject private var modifierLatch = ModifierLatchController()
    #endif

    init(session: ViewerSession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self.renderer = session.renderer
        self.stats = session.stats
        self.onDisconnect = onDisconnect
        #if os(iOS)
        self._controlPreferences = StateObject(wrappedValue: ViewerControlPreferences(scope: session.controlPreferenceScope))
        #endif
    }

    @State private var showStats = true
    @State private var showKeyboardEntry = false
    @State private var keyboardDraft = ""
    @State private var lastDragLocation: CGPoint = .zero
    @State private var touchMode: TouchMode = .directTouch
    @State private var isKeyboardActive = false
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
        HStack {
            Image(systemName: statusSymbol)
                .foregroundColor(statusColor)
            Text(session.phase.humanDescription)
                .font(.subheadline)
            if session.phase.isActive && session.encryptionStatusKnown {
                Text(session.encryptionEnabled ? "Encrypted" : "Unencrypted")
                    .font(.caption.bold())
                    .foregroundColor(session.encryptionEnabled ? .green : .orange)
            }
            Spacer()
            if showStats { statsView }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
    }

    private var statsView: some View {
        HStack(spacing: 10) {
            Label(String(format: "%.0f fps", stats.fps), systemImage: "speedometer")
            Label(ByteFormatting.bitsPerSecond(stats.bytesPerSecond), systemImage: "arrow.down.circle")
            Label(String(format: "%.0f ms", stats.roundTripMillis), systemImage: "timer")
            Label(session.inputMapper.isControlEnabled ? "Control" : "View only",
                  systemImage: session.inputMapper.isControlEnabled ? "cursorarrow.click" : "eye")
        }
        .font(.caption.monospacedDigit())
        .foregroundColor(.secondary)
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
                showStats.toggle()
            } label: {
                Image(systemName: showStats ? "info.circle.fill" : "info.circle")
            }
            Button {
                session.fitMode.toggle()
            } label: {
                Image(systemName: session.fitMode ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward")
            }
            #if os(iOS)
            if !viewport.isIdentity {
                Button {
                    resetViewport()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
            }
            #endif

            // Display picker (only shown when host reports multiple displays)
            if session.remoteDisplays.count > 1 {
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
            #endif

            Button { onDisconnect() } label: {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.red)
            }
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
                if let img = renderer.currentImage {
                    #if os(iOS)
                    iOSCanvasContent(img: img, canvasSize: proxy.size)
                    #else
                    Image(decorative: img, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: session.fitMode ? .fit : .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .gesture(dragGesture(in: proxy.size))
                    #endif
                } else {
                    ProgressView("Waiting for first frame…")
                        .foregroundColor(.white)
                }
                CursorOverlayView(
                    state: session.cursorState,
                    inputMapper: session.inputMapper,
                    canvasGeometry: canvasGeometry(size: proxy.size)
                )
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
    private func iOSCanvasContent(img: CGImage, canvasSize: CGSize) -> some View {
        ZStack {
            remoteImage(img, canvasSize: canvasSize)
            TrackpadInputView(
                inputMapper: session.inputMapper,
                touchMode: touchMode,
                canvasSize: canvasSize,
                remotePixelSize: remotePixelSize,
                fit: session.fitMode,
                viewport: viewport,
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

    private func remoteImage(_ img: CGImage, canvasSize: CGSize) -> some View {
        Image(decorative: img, scale: 1.0)
            .resizable()
            .aspectRatio(contentMode: session.fitMode ? .fit : .fill)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(viewport.scale, anchor: .center)
            .offset(viewport.offset)
            .clipped()
    }

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
            viewport: viewport ?? self.viewport
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

    #if os(iOS)
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
