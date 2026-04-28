//
//  RDPViewerView.swift
//  Screen Q
//
//  Preview surface for the Windows RDP route. It makes the current boundary
//  explicit instead of leaving users at a generic spinner.
//

import SwiftUI
import Combine

#if os(iOS)
import UIKit
#endif

struct RDPViewerView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: RDPSession
    @ObservedObject private var stats: TransportStats
    var onDisconnect: () -> Void

    @State private var credentialDomain = ""
    @State private var credentialUsername = ""
    @State private var credentialPassword = ""
    @State private var rememberCredentials = true
    @State private var requireLocalAuthenticationForSavedCredentials = true
    @State private var dragHadMovement = false
    @State private var showStats = true
    @State private var showKeyboardEntry = false
    @State private var keyboardDraft = ""
    @State private var viewport: ViewportTransform = .identity
    @State private var lastCanvasSize: CGSize = .zero

    #if os(iOS)
    @StateObject private var controlPreferences: ViewerControlPreferences
    @StateObject private var modifierLatch = ModifierLatchController()
    @State private var touchMode: TouchMode = .directTouch
    @State private var isKeyboardActive = false
    @State private var controlsVisible = true
    @State private var zoomHUDScale: CGFloat?
    @State private var dragFeedback: IOSDragFeedback?
    #endif

    init(session: RDPSession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self._stats = ObservedObject(wrappedValue: session.stats)
        self.onDisconnect = onDisconnect
        #if os(iOS)
        self._controlPreferences = StateObject(wrappedValue: ViewerControlPreferences(scope: ViewerControlPreferenceScope(
            connectionProtocol: .rdp,
            host: session.profile.host,
            port: session.profile.port
        )))
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            contentContainer
        }
        .navigationTitle(session.profile.displayName)
        #if os(macOS)
        .navigationSubtitle("RDP - \(session.profile.address)")
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    showStats.toggle()
                } label: {
                    Image(systemName: showStats ? "info.circle.fill" : "info.circle")
                }
                .help(showStats ? "Hide stats" : "Show stats")

                Button {
                    session.fitMode.toggle()
                    clampViewport(for: lastCanvasSize)
                } label: {
                    Image(systemName: session.fitMode ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward")
                }
                .help(session.fitMode ? "Fill viewer" : "Fit to viewer")

                Button {
                    showKeyboardEntry.toggle()
                } label: {
                    Image(systemName: "keyboard")
                }
                .help("Send text")

                RDPCertificateMenu(session: session)

                Button {
                    app.viewerFocusMode.toggle()
                } label: {
                    Image(systemName: app.viewerFocusMode ? "sidebar.left" : "rectangle.inset.filled")
                }
                .help(app.viewerFocusMode ? "Show sidebar" : "Focus viewer")

                Button("Disconnect") {
                    disconnect()
                }
                .foregroundColor(.red)
            }
            #else
            ToolbarItem(placement: .automatic) {
                Button("Disconnect") {
                    disconnect()
                }
                .foregroundColor(.red)
            }
            #endif
        }
        .sheet(isPresented: credentialsSheetBinding) {
            RDPCredentialsSheet(
                domain: $credentialDomain,
                username: $credentialUsername,
                password: $credentialPassword,
                rememberCredentials: $rememberCredentials,
                requireLocalAuthenticationForSavedCredentials: $requireLocalAuthenticationForSavedCredentials,
                message: credentialPromptMessage,
                hasSavedCredentials: session.hasSavedCredentials,
                onConnect: {
                    Task {
                        await session.submitCredentials(
                            domain: credentialDomain,
                            username: credentialUsername,
                            password: credentialPassword,
                            remember: rememberCredentials,
                            requireLocalAuthentication: requireLocalAuthenticationForSavedCredentials
                        )
                    }
                },
                onForgetSavedCredentials: {
                    credentialPassword = ""
                    credentialDomain = session.profile.domain ?? ""
                    credentialUsername = session.profile.username ?? ""
                    session.forgetSavedCredentials()
                },
                onCancel: onDisconnect
            )
        }
        .sheet(isPresented: certificateSheetBinding) {
            if case .certificateTrustRequired(let certificate) = session.phase {
                RDPCertificateTrustSheet(
                    certificate: certificate,
                    onTrustOnce: { Task { await session.trustCertificate(.trustOnce) } },
                    onTrustAlways: { Task { await session.trustCertificate(.trustAlways) } },
                    onReject: { Task { await session.trustCertificate(.reject) } }
                )
            }
        }
        .onAppear {
            configureRDPControls()
            syncCredentialFields(from: session.phase)
        }
        .onChange(of: session.phase) { newPhase in
            syncCredentialFields(from: newPhase)
        }
        .onReceive(session.$currentImage.compactMap { $0 }.throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)) { image in
            app.savedConnections.updateThumbnail(
                host: session.profile.host,
                port: session.profile.port,
                displayName: session.profile.displayName,
                connectionProtocol: .rdp,
                image: image
            )
        }
    }

    @ViewBuilder
    private var contentContainer: some View {
        if case .connected = session.phase {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .frame(maxWidth: 520)
                .padding(24)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .preflighting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking RDP endpoint...")
                    .font(.headline)
                Text(session.profile.address)
                    .font(.caption)
                    .foregroundColor(.secondary)
                securityBadge
            }

        case .credentialsRequired:
            VStack(spacing: 14) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 42))
                    .foregroundColor(.accentColor)
                Text("Windows Credentials Required")
                    .font(.headline)
                Text(credentialPromptMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                profileSummary
                Button("Enter Credentials") {
                    syncCredentialFields(from: session.phase)
                }
                .buttonStyle(.bordered)
            }

        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting RDP session...")
                    .font(.headline)
                Text(session.profile.address)
                    .font(.caption)
                    .foregroundColor(.secondary)
                securityBadge
            }

        case .certificateTrustRequired:
            VStack(spacing: 14) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundColor(.orange)
                Text("Review Windows Certificate")
                    .font(.headline)
                Text("The RDP engine needs a certificate trust decision before sending credentials.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                securityBadge
            }

        case .connected:
            rdpCanvas

        case .engineUnavailable(let detail):
            VStack(spacing: 14) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundColor(.orange)
                Text("Native RDP Engine Not Linked")
                    .font(.headline)
                Text(detail)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                profileSummary
                securityBadge
                Button("Done") { onDisconnect() }
                    .buttonStyle(.bordered)
            }

        case .failed(let reason):
            VStack(spacing: 14) {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 42))
                    .foregroundColor(.red)
                Text("RDP Connection Failed")
                    .font(.headline)
                Text(reason)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    if session.hasSavedCredentials {
                        Button("Forget Saved Login") {
                            credentialPassword = ""
                            session.forgetSavedCredentials(message: "Enter a different Windows account allowed to sign in through Remote Desktop on this PC.")
                        }
                        .buttonStyle(.bordered)
                    }
                    if session.hasTrustedCertificate {
                        Button("Forget Trusted Certificate") {
                            session.forgetTrustedCertificate()
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Done") { onDisconnect() }
                        .buttonStyle(.bordered)
                }
            }

        case .ended(let reason):
            VStack(spacing: 12) {
                Image(systemName: "rectangle.badge.xmark")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Session Ended")
                    .font(.headline)
                Text(reason)
                    .foregroundColor(.secondary)
                Button("Done") { onDisconnect() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var rdpCanvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color.black
                if let image = session.currentImage {
                    remoteImage(image, canvasSize: proxy.size)
                    #if os(iOS)
                    TrackpadInputView(
                        inputMapper: session.inputMapper,
                        touchMode: touchMode,
                        canvasSize: proxy.size,
                        remotePixelSize: remotePixelSize,
                        fit: session.fitMode,
                        viewport: viewport,
                        onViewportChange: { newViewport in
                            setViewport(newViewport, canvasSize: proxy.size)
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
                    PredictedCursorOverlayView(
                        inputMapper: session.inputMapper,
                        canvasGeometry: canvasGeometry(size: proxy.size)
                    )
                    #else
                    rdpInputOverlay(canvasSize: proxy.size)
                    #endif
                } else {
                    ProgressView("Waiting for first RDP frame...")
                        .foregroundColor(.white)
                }
                if showStats {
                    rdpStatsBadge
                        .padding(12)
                }
                #if os(iOS)
                if let zoomHUDScale {
                    zoomHUD(scale: zoomHUDScale)
                }
                if let dragFeedback {
                    dragFeedbackOverlay(dragFeedback)
                }
                RDPIOSControlSurface(
                    inputMapper: session.inputMapper,
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
                            clampViewport(for: proxy.size)
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
                    onDisconnect: disconnect
                )
                RemoteKeyboardView(
                    inputMapper: session.inputMapper,
                    isActive: $isKeyboardActive
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                #endif
                #if os(macOS)
                if showKeyboardEntry {
                    keyboardEntryOverlay
                        .padding()
                }
                #endif
            }
            .onAppear { updateCanvas(size: proxy.size) }
            .onChange(of: proxy.size) { updateCanvas(size: $0) }
            .onChange(of: session.fitMode) { _ in clampViewport(for: proxy.size) }
            .onChange(of: viewport) { updateCanvas(size: proxy.size, viewport: $0) }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remoteImage(_ image: CGImage, canvasSize: CGSize) -> some View {
        Image(decorative: image, scale: 1.0)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: session.fitMode ? .fit : .fill)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(viewport.scale, anchor: .center)
            .offset(viewport.offset)
            .clipped()
    }

    private func rdpInputOverlay(canvasSize: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateCanvas(size: canvasSize)
                        let moved = abs(value.translation.width) > 4 || abs(value.translation.height) > 4
                        dragHadMovement = dragHadMovement || moved
                        session.inputMapper.sendPointerMove(localPoint: value.location)
                    }
                    .onEnded { value in
                        updateCanvas(size: canvasSize)
                        if dragHadMovement {
                            session.inputMapper.sendPointerMove(localPoint: value.location)
                        } else {
                            session.inputMapper.sendTap(localPoint: value.location)
                        }
                        dragHadMovement = false
                    }
            )
    }

    private var rdpStatsBadge: some View {
        HStack(spacing: 8) {
            Label(String(format: "%.0f fps", stats.fps), systemImage: "speedometer")
            Label("\(ByteFormatting.bytesPerSecond(stats.bytesPerSecond)) decoded", systemImage: "rectangle.compress.vertical")
            Label("RDP", systemImage: "pc")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.68))
        .clipShape(Capsule())
    }

    private var remotePixelSize: CGSize {
        CGSize(
            width: session.remoteWidth > 0 ? session.remoteWidth : 1920,
            height: session.remoteHeight > 0 ? session.remoteHeight : 1080
        )
    }

    private func updateCanvas(size: CGSize) {
        updateCanvas(size: size, viewport: viewport)
    }

    private func updateCanvas(size: CGSize, viewport: ViewportTransform) {
        lastCanvasSize = size
        session.updateCanvas(size: size, fit: session.fitMode, viewport: viewport)
        session.inputMapper.ensurePredictedPointerVisible()
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

    private func clampViewport(for canvasSize: CGSize) {
        let clamped = viewport.clamped(in: canvasGeometry(size: canvasSize))
        setViewport(clamped, canvasSize: canvasSize)
    }

    private func resetViewport() {
        setViewport(.identity, canvasSize: lastCanvasSize)
    }

    private func configureRDPControls() {
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
        session.inputMapper.keepsPredictedPointerVisible = true
        #endif
    }

    private func disconnect() {
        Task { await session.disconnect() }
        #if os(macOS)
        app.viewerFocusMode = false
        #endif
        onDisconnect()
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
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    #endif

    private var profileSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(session.profile.address, systemImage: "network")
            if let username = session.profile.normalizedUsername {
                Label(username, systemImage: "person.crop.circle")
            }
            if session.profile.administrativeSession || session.profile.connectToConsole {
                Label("Administrative / console session requested", systemImage: "wrench.and.screwdriver")
            }
            if session.profile.dynamicResolution {
                Label("Dynamic resolution requested", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if session.profile.redirectClipboard {
                Label("Clipboard redirection requested", systemImage: "doc.on.clipboard")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var credentialsSheetBinding: Binding<Bool> {
        Binding(
            get: {
                if case .credentialsRequired = session.phase { return true }
                return false
            },
            set: { newValue in
                if !newValue {
                    credentialPassword = ""
                }
            }
        )
    }

    private var certificateSheetBinding: Binding<Bool> {
        Binding(
            get: {
                if case .certificateTrustRequired = session.phase { return true }
                return false
            },
            set: { _ in }
        )
    }

    private var credentialPromptMessage: String {
        if case .credentialsRequired(let prompt) = session.phase {
            return prompt.message
        }
        return "Enter the Windows account allowed to use Remote Desktop on \(session.profile.host)."
    }

    private func syncCredentialFields(from phase: RDPSession.Phase) {
        guard case .credentialsRequired(let prompt) = phase else { return }
        if credentialDomain.isEmpty, let domain = prompt.suggestedDomain {
            credentialDomain = domain
        }
        if credentialUsername.isEmpty {
            credentialUsername = prompt.suggestedUsername ?? session.profile.username ?? ""
        }
    }

    private var securityBadge: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.securityStatus.symbolName)
                .foregroundColor(session.securityStatus.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.securityStatus.title)
                    .font(.caption.weight(.semibold))
                Text(session.securityStatus.detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let action = session.securityStatus.recommendedAction {
                    Text(action)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct RDPCredentialsSheet: View {
    @Binding var domain: String
    @Binding var username: String
    @Binding var password: String
    @Binding var rememberCredentials: Bool
    @Binding var requireLocalAuthenticationForSavedCredentials: Bool
    let message: String
    let hasSavedCredentials: Bool
    let onConnect: () -> Void
    let onForgetSavedCredentials: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Windows Credentials", systemImage: "person.badge.key")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("For local accounts use PC-NAME\\username or .\\username. For Microsoft or Entra accounts use MicrosoftAccount\\email@example.com or AzureAD\\email@example.com.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Domain (optional)", text: $domain)
                .textFieldStyle(.roundedBorder)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textContentType(.username)
                .autocapitalization(.none)
                #endif
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textContentType(.password)
                #endif
            Toggle("Remember in Keychain", isOn: $rememberCredentials)
            if rememberCredentials {
                Toggle("Require Touch ID / Face ID / passcode before reuse", isOn: $requireLocalAuthenticationForSavedCredentials)
                Text("Recommended for Windows accounts with administrative or remote-login rights.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel", action: onCancel)
                if hasSavedCredentials {
                    Button("Forget Saved Login", action: onForgetSavedCredentials)
                }
                Spacer()
                Button("Connect", action: onConnect)
                    .buttonStyle(.bordered)
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 420)
    }
}

private struct RDPCertificateTrustSheet: View {
    let certificate: RDPCertificateInfo
    let onTrustOnce: () -> Void
    let onTrustAlways: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Review RDP Certificate", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.headline)
            Text("Only trust this certificate if it matches the Windows PC you intended to control.")
                .font(.footnote)
                .foregroundColor(.secondary)
            certificateRows
            HStack {
                Button("Reject", action: onReject)
                    .foregroundColor(.red)
                Spacer()
                Button("Trust Once", action: onTrustOnce)
                    .buttonStyle(.bordered)
                Button("Trust Always", action: onTrustAlways)
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(minWidth: 340, idealWidth: 480)
    }

    private var certificateRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Host", certificate.host)
            row("Subject", certificate.subject)
            row("Issuer", certificate.issuer)
            row("SHA-256", certificate.fingerprintSHA256)
            if let validUntil = certificate.validUntil {
                row("Valid Until", Self.dateFormatter.string(from: validUntil))
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

#if os(macOS)
private struct RDPCertificateMenu: View {
    @ObservedObject var session: RDPSession

    var body: some View {
        Menu {
            if session.hasTrustedCertificate {
                Button("Forget Trusted Certificate") {
                    session.forgetTrustedCertificate()
                }
            } else {
                Text("No pinned RDP certificate")
            }
        } label: {
            Image(systemName: session.hasTrustedCertificate ? "lock.shield.fill" : "lock.shield")
        }
        .help("RDP certificate trust")
    }
}
#endif

#if os(iOS)
private struct RDPIOSControlSurface: View {
    @ObservedObject var inputMapper: InputMappingService
    @ObservedObject var preferences: ViewerControlPreferences
    @ObservedObject var modifiers: ModifierLatchController

    @Binding var touchMode: TouchMode
    @Binding var fitMode: Bool
    @Binding var showStats: Bool
    @Binding var isKeyboardActive: Bool
    @Binding var controlsVisible: Bool

    let viewport: ViewportTransform
    let resetViewport: () -> Void
    let onDisconnect: () -> Void

    @State private var dragStartOffset: CGSize?
    @State private var isCollapsed = false
    @State private var showGestureHelp = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if controlsVisible {
                    if isPad {
                        floatingToolbar(in: proxy.size)
                    } else if proxy.size.width > proxy.size.height {
                        toolbarBody(vertical: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                            .padding(.vertical, 10)
                    } else {
                        toolbarBody(vertical: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                } else {
                    revealButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(12)
                }
            }
        }
        .allowsHitTesting(true)
        .sheet(isPresented: $showGestureHelp) {
            gestureHelp
        }
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var revealButton: some View {
        Button {
            controlsVisible = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show controls")
    }

    private func floatingToolbar(in size: CGSize) -> some View {
        toolbarBody(vertical: isCollapsed)
            .position(x: size.width / 2, y: size.height - 68)
            .offset(preferences.toolbarOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartOffset == nil {
                            dragStartOffset = preferences.toolbarOffset
                        }
                        let start = dragStartOffset ?? .zero
                        preferences.toolbarOffset = clampedOffset(
                            CGSize(width: start.width + value.translation.width,
                                   height: start.height + value.translation.height),
                            in: size
                        )
                    }
                    .onEnded { _ in
                        dragStartOffset = nil
                    }
            )
    }

    private func toolbarBody(vertical: Bool) -> some View {
        let axis: Axis.Set = vertical ? .vertical : .horizontal
        return ScrollView(axis, showsIndicators: false) {
            Group {
                if isCollapsed && isPad {
                    stack(vertical: vertical) {
                        toolbarSection(vertical: vertical) {
                            statusPill
                            iconButton(systemName: "chevron.up.chevron.down", label: "Expand controls") {
                                isCollapsed = false
                            }
                        }
                        toolbarSection(vertical: vertical) {
                            keyboardButton
                            touchModeMenu
                        }
                        toolbarSection(vertical: vertical) {
                            actionMenu
                        }
                    }
                } else {
                    stack(vertical: vertical) {
                        toolbarSection(vertical: vertical) {
                            statusPill
                            iconButton(systemName: "minus", label: isPad ? "Collapse controls" : "Hide controls") {
                                if isPad {
                                    isCollapsed = true
                                } else {
                                    controlsVisible = false
                                }
                            }
                        }
                        toolbarSection(vertical: vertical) {
                            touchModeMenu
                        }
                        toolbarSection(vertical: vertical) {
                            iconButton(
                                systemName: fitMode ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward",
                                label: fitMode ? "Fill screen" : "Fit to screen"
                            ) {
                                fitMode.toggle()
                                preferences.fitMode = fitMode
                            }
                            if !viewport.isIdentity {
                                iconButton(systemName: "minus.magnifyingglass", label: "Reset zoom") {
                                    resetViewport()
                                }
                            }
                        }
                        toolbarSection(vertical: vertical) {
                            keyboardButton
                            modifierButtons(vertical: vertical)
                            arrowsMenu
                            specialKeysMenu
                            functionKeysMenu
                            shortcutsMenu
                            actionMenu
                        }
                        toolbarSection(vertical: vertical, prominent: true) {
                            iconButton(systemName: "xmark.circle", label: "Disconnect", tint: .red) {
                                onDisconnect()
                            }
                        }
                    }
                }
            }
            .padding(7)
        }
        .frame(
            maxWidth: vertical ? 68 : min(UIScreen.main.bounds.width - 20, isPad ? 900 : 760),
            maxHeight: vertical ? min(UIScreen.main.bounds.height - 20, 660) : 66
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .contain)
    }

    private var statusPill: some View {
        Image(systemName: inputMapper.isControlEnabled ? "cursorarrow.click" : "eye")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(inputMapper.isControlEnabled ? .green : .orange)
            .frame(width: 38, height: 38)
            .background(Color.primary.opacity(0.08))
            .clipShape(Circle())
            .accessibilityLabel(inputMapper.isControlEnabled ? "Control enabled" : "Observe only")
    }

    private var keyboardButton: some View {
        iconButton(
            systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
            label: isKeyboardActive ? "Hide keyboard" : "Show keyboard",
            disabled: !inputMapper.isControlEnabled
        ) {
            isKeyboardActive.toggle()
        }
    }

    private var touchModeMenu: some View {
        Menu {
            ForEach(TouchMode.allCases) { mode in
                Button {
                    touchMode = mode
                    preferences.touchMode = mode
                } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
            }
        } label: {
            Image(systemName: touchMode.icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Touch mode")
    }

    private func modifierButtons(vertical: Bool) -> some View {
        stack(vertical: vertical) {
            ForEach(RemoteModifier.allCases) { modifier in
                modifierButton(modifier)
            }
        }
    }

    private func modifierButton(_ modifier: RemoteModifier) -> some View {
        let state = modifiers.state(for: modifier)
        return Text(modifier.textSymbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 38, height: 38)
            .foregroundStyle(state == .off ? Color.primary : Color.white)
            .background(modifierBackground(for: state))
            .clipShape(Circle())
            .opacity(inputMapper.isControlEnabled ? 1 : 0.35)
            .onTapGesture(count: 2) {
                guard inputMapper.isControlEnabled else { return }
                modifiers.toggleLocked(modifier)
            }
            .onTapGesture {
                guard inputMapper.isControlEnabled else { return }
                modifiers.toggleMomentary(modifier)
            }
            .accessibilityLabel("\(modifier.label) modifier")
    }

    private func modifierBackground(for state: ModifierLatchState) -> Color {
        switch state {
        case .off: return Color.primary.opacity(0.08)
        case .momentary: return Color.accentColor.opacity(0.72)
        case .locked: return Color.accentColor
        }
    }

    private var arrowsMenu: some View {
        Menu {
            Button("Up") { send(.arrowUp) }
            Button("Down") { send(.arrowDown) }
            Button("Left") { send(.arrowLeft) }
            Button("Right") { send(.arrowRight) }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .disabled(!inputMapper.isControlEnabled)
        .buttonStyle(.plain)
        .accessibilityLabel("Arrow keys")
    }

    private var specialKeysMenu: some View {
        Menu {
            ForEach(KeyboardMapping.specialKeys, id: \.label) { entry in
                Button(entry.label) { send(entry.code) }
            }
        } label: {
            Image(systemName: "command.square")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .disabled(!inputMapper.isControlEnabled)
        .buttonStyle(.plain)
        .accessibilityLabel("Special keys")
    }

    private var functionKeysMenu: some View {
        Menu {
            ForEach(KeyboardMapping.functionKeys, id: \.label) { entry in
                Button(entry.label) { send(entry.code) }
            }
        } label: {
            Text("F")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(width: 38, height: 38)
        }
        .disabled(!inputMapper.isControlEnabled)
        .buttonStyle(.plain)
        .accessibilityLabel("Function keys")
    }

    private var shortcutsMenu: some View {
        Menu {
            ForEach(Self.windowsShortcuts, id: \.label) { entry in
                Button(entry.label) { send(entry.code, modifiers: entry.modifiers) }
            }
        } label: {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .disabled(!inputMapper.isControlEnabled)
        .buttonStyle(.plain)
        .accessibilityLabel("Windows shortcuts")
    }

    private var actionMenu: some View {
        Menu {
            Button(showStats ? "Hide Stats" : "Show Stats") {
                showStats.toggle()
                preferences.showStats = showStats
            }
            Button("Clear Modifiers") {
                modifiers.clearAll()
            }
            Button("Gesture Help") {
                showGestureHelp = true
            }
            Button("Hide Controls") {
                controlsVisible = false
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
    }

    private func iconButton(
        systemName: String,
        label: String,
        tint: Color = .primary,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func stack<Content: View>(vertical: Bool, @ViewBuilder content: () -> Content) -> some View {
        if vertical {
            VStack(spacing: 7, content: content)
        } else {
            HStack(spacing: 7, content: content)
        }
    }

    private func toolbarSection<Content: View>(
        vertical: Bool,
        prominent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        stack(vertical: vertical, content: content)
            .padding(3)
            .background(
                prominent ? Color.red.opacity(0.14) : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: vertical ? 22 : 24, style: .continuous)
            )
    }

    private func send(_ key: KeyCode, modifiers explicitModifiers: KeyModifiers = []) {
        guard inputMapper.isControlEnabled else { return }
        inputMapper.sendKey(key, modifiers: explicitModifiers)
    }

    private func clampedOffset(_ offset: CGSize, in size: CGSize) -> CGSize {
        let maxX = max(0, size.width / 2 - 80)
        let maxY = max(0, size.height / 2 - 50)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private static let windowsShortcuts: [(label: String, code: KeyCode, modifiers: KeyModifiers)] = [
        ("Copy", .c, [.control]),
        ("Paste", .v, [.control]),
        ("Cut", .x, [.control]),
        ("Select All", .a, [.control]),
        ("Undo", .z, [.control]),
        ("Find", .f, [.control]),
        ("Alt Tab", .tab, [.option]),
        ("Close Window", .f4, [.option]),
        ("Control Alt Delete", .delete, [.control, .option]),
        ("Show Desktop", .d, [.command]),
        ("Lock PC", .l, [.command])
    ]

    private var gestureHelp: some View {
        NavigationStack {
            List {
                Section("Touch") {
                    Label("Tap clicks where you touch.", systemImage: "hand.tap")
                    Label("Double tap sends a double click.", systemImage: "hand.tap.fill")
                    Label("Long press starts a drag.", systemImage: "cursorarrow.motionlines")
                    Label("Two-finger tap right-clicks.", systemImage: "contextualmenu.and.cursorarrow")
                    Label("Three-finger tap middle-clicks.", systemImage: "circle.grid.cross")
                }
                Section("Viewport") {
                    Label("Pinch zooms the local RDP view.", systemImage: "plus.magnifyingglass")
                    Label("Two-finger drag scrolls Windows.", systemImage: "scroll")
                    Label("Two-finger double tap hides or shows controls.", systemImage: "slider.horizontal.3")
                }
                Section("Windows") {
                    Label("Use Control shortcuts for copy, paste, cut, select all, undo, and find.", systemImage: "control")
                    Label("Option maps to Alt, and Command maps to the Windows key.", systemImage: "command")
                }
            }
            .navigationTitle("RDP Gestures")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showGestureHelp = false }
                }
            }
        }
    }
}
#endif
