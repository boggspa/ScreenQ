//
//  VNCViewerView.swift
//  Screen Q
//
//  SwiftUI view for a native VNC session — displays the remote framebuffer,
//  forwards mouse/keyboard input, and handles VNC password prompts.
//

import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

struct VNCViewerView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: VNCSession
    var onDisconnect: () -> Void
    @StateObject private var controlPreferences: ViewerControlPreferences
    @State private var metalRenderTimer: Timer?
    @State private var showQualityHUD: Bool = false
    #if os(iOS)
    @StateObject private var iosInputState = VNCIOSInputState()
    @State private var isKeyboardActive = false
    @State private var viewportNavigationMode = true
    #endif

    init(session: VNCSession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self.onDisconnect = onDisconnect
        self._controlPreferences = StateObject(wrappedValue: ViewerControlPreferences(scope: session.controlPreferenceScope))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            #if os(iOS)
            if case .connected = session.phase {
                VNCIOSControlStrip(
                    session: session,
                    inputState: iosInputState,
                    securityStatus: session.securityStatus,
                    streamQuality: $controlPreferences.streamQuality,
                    streamProfile: $controlPreferences.streamProfile,
                    isKeyboardActive: $isKeyboardActive,
                    viewportNavigationMode: $viewportNavigationMode,
                    onDisconnect: disconnectAndExit
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

                VNCKeyboardInputView(
                    session: session,
                    inputState: iosInputState,
                    isActive: $isKeyboardActive
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
            #endif
        }
        .navigationTitle(session.serverName.isEmpty ? session.peerLabel : session.serverName)
        #if os(macOS)
        .navigationSubtitle(statusText)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                VNCConnectionSecurityMenu(status: session.securityStatus)
            }
            ToolbarItem(placement: .automatic) {
                StreamQualityButton(
                    quality: $controlPreferences.streamQuality,
                    profile: $controlPreferences.streamProfile,
                    protocolName: session.profile.displayName,
                    detail: "Controls VNC request cadence, viewport size, and local framebuffer rendering. Tight compression-level support can build on this."
                )
            }
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                Button {
                    MacWindowControls.toggleFullScreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Enter fullscreen")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    requestRemoteResizeToWindow()
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .help("Resize remote desktop to match this window")
                .disabled(!session.canRequestRemoteResize)
            }
            #endif
            ToolbarItem(placement: .automatic) {
                Button {
                    showQualityHUD.toggle()
                } label: {
                    Image(systemName: showQualityHUD ? "speedometer" : "gauge.with.dots.needle.33percent")
                }
                .help("Toggle performance HUD")
            }
            ToolbarItem(placement: .automatic) {
                Button("Disconnect", action: disconnectAndExit)
                .foregroundColor(.red)
            }
        }
        .sheet(isPresented: $session.needsPassword) {
            VNCPasswordSheet(
                title: vncPasswordTitle,
                message: vncPasswordMessage,
                password: $session.vncPassword,
                rememberCredentials: $session.rememberCredentials,
                requireLocalAuthenticationForSavedCredentials: $session.requireLocalAuthenticationForSavedCredentials,
                onConnect: { Task { await session.retryWithPassword() } },
                onCancel: disconnectAndExit
            )
        }
        .sheet(isPresented: $session.needsCredentials) {
            VNCCredentialsSheet(
                username: $session.username,
                password: $session.vncPassword,
                rememberCredentials: $session.rememberCredentials,
                requireLocalAuthenticationForSavedCredentials: $session.requireLocalAuthenticationForSavedCredentials,
                onConnect: { Task { await session.retryWithCredentials() } },
                onCancel: disconnectAndExit
            )
        }
        .onAppear {
            session.enableMetalRendering()
            Task { await applyStreamControls() }
        }
        .onReceive(controlPreferences.$streamQuality.removeDuplicates()) { _ in
            Task { await applyStreamControls() }
        }
        .onReceive(controlPreferences.$streamProfile.removeDuplicates()) { _ in
            Task { await applyStreamControls() }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await session.handleMemoryPressure() }
        }
        #endif
        .onReceive(session.$currentImage.compactMap { $0 }.throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)) { image in
            app.savedConnections.updateThumbnail(
                host: session.savedConnectionHost,
                port: session.savedConnectionPort,
                displayName: session.peerLabel,
                connectionProtocol: session.savedConnectionProtocol,
                image: image
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(session.peerLabel)…")
                    .foregroundColor(.secondary)
                VNCConnectionSecurityBadge(status: session.securityStatus)
                Button("Cancel", action: disconnectAndExit)
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
            }

        case .authenticating:
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                Text("Authenticating…")
                    .foregroundColor(.secondary)
                VNCConnectionSecurityBadge(status: session.securityStatus)
                Button("Cancel", action: disconnectAndExit)
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
            }

        case .connected:
            vncCanvas

        case .reconnecting(let attempt):
            VStack(spacing: 12) {
                ProgressView()
                Text("Reconnecting…")
                    .font(.headline)
                Text("Attempt \(attempt) of \(5)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("Cancel", action: disconnectAndExit)
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
            }

        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text("Connection Failed")
                    .font(.headline)
                Text(reason)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Dismiss") { onDisconnect() }
                    .buttonStyle(.bordered)
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

    @ViewBuilder
    private var vncCanvas: some View {
        ZStack(alignment: .topTrailing) {
            vncCanvasInner
            if showQualityHUD {
                qualityHUD
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var vncCanvasInner: some View {
        #if os(macOS)
        if let renderer = session.metalRenderer {
            VNCMetalInputView(session: session, renderer: renderer)
        } else {
            VNCInputView(session: session)
        }
        #else
        if let renderer = session.metalRenderer {
            vncCanvasMetaliOS(renderer: renderer)
        } else if let image = session.currentImage {
            vncCanvasFallbackiOS(image: image)
        } else {
            ProgressView("Waiting for framebuffer…")
        }
        #endif
    }

    private var qualityHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.0f fps", session.measuredFPS))
                .font(.system(.caption, design: .monospaced).weight(.bold))
            Text("\(session.serverWidth)×\(session.serverHeight)")
                .font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .foregroundColor(.white)
        .cornerRadius(6)
    }

    #if os(iOS)
    @ViewBuilder
    private func vncCanvasMetaliOS(renderer: MetalFrameBufferRenderer) -> some View {
        GeometryReader { geo in
            let imgW = CGFloat(session.viewWidth)
            let imgH = CGFloat(session.viewHeight)
            let scale = min(geo.size.width / imgW, geo.size.height / imgH, 1.0)
            let displayW = imgW * scale
            let displayH = imgH * scale
            let offsetX = (geo.size.width - displayW) / 2
            let offsetY = (geo.size.height - displayH) / 2

            ZStack {
                MetalCanvasViewiOS(renderer: renderer) { view in
                    view.renderFrame()
                }
                .frame(width: displayW, height: displayH)
                .position(x: offsetX + displayW / 2, y: offsetY + displayH / 2)

                VNCCursorOverlayView(
                    session: session,
                    serverSize: CGSize(width: imgW, height: imgH),
                    displayScale: scale
                )
                .frame(width: displayW, height: displayH)
                .position(x: offsetX + displayW / 2, y: offsetY + displayH / 2)

                VNCIOSTouchInputOverlay(
                    session: session,
                    inputState: iosInputState,
                    serverSize: CGSize(width: imgW, height: imgH),
                    displayScale: scale,
                    viewportNavigationMode: viewportNavigationMode
                )
                .frame(width: displayW, height: displayH)
                .position(x: offsetX + displayW / 2, y: offsetY + displayH / 2)
            }
            .onAppear {
                Task { await session.updateViewportCanvasSize(geo.size) }
            }
            .onChange(of: geo.size) { _, newSize in
                Task { await session.updateViewportCanvasSize(newSize) }
            }
        }
    }

    @ViewBuilder
    private func vncCanvasFallbackiOS(image: CGImage) -> some View {
        GeometryReader { geo in
            ZStack {
                let imgW = CGFloat(session.viewWidth)
                let imgH = CGFloat(session.viewHeight)
                let scale = min(geo.size.width / imgW, geo.size.height / imgH, 1.0)
                let displayW = imgW * scale
                let displayH = imgH * scale
                let offsetX = (geo.size.width - displayW) / 2
                let offsetY = (geo.size.height - displayH) / 2

                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayW, height: displayH)
                    .position(x: offsetX + displayW / 2, y: offsetY + displayH / 2)

                VNCCursorOverlayView(
                    session: session,
                    serverSize: CGSize(width: imgW, height: imgH),
                    displayScale: scale
                )
                .frame(width: displayW, height: displayH)
                .position(x: offsetX + displayW / 2, y: offsetY + displayH / 2)

                VNCIOSTouchInputOverlay(
                    session: session,
                    inputState: iosInputState,
                    serverSize: CGSize(width: imgW, height: imgH),
                    displayScale: scale,
                    viewportNavigationMode: viewportNavigationMode
                )
                .frame(width: displayW, height: displayH)
                .position(x: offsetX + displayW / 2, y: offsetY + displayH / 2)
            }
            .onAppear {
                Task { await session.updateViewportCanvasSize(geo.size) }
            }
            .onChange(of: geo.size) { _, newSize in
                Task { await session.updateViewportCanvasSize(newSize) }
            }
        }
    }
    #endif

    private var statusText: String {
        switch session.phase {
        case .connecting: return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .reconnecting(let attempt): return "Reconnecting (attempt \(attempt))…"
        case .connected:
            if let summary = session.streamViewportSummary {
                return "Viewport \(summary) — \(session.profile.displayName)"
            }
            if let region = session.selectedDisplayRegion, !region.isFullDesktop {
                return "\(region.name) \(region.detail) — \(session.profile.displayName)"
            }
            return "\(session.serverWidth)×\(session.serverHeight) — \(session.profile.displayName)"
        case .failed: return "Failed"
        case .ended: return "Ended"
        }
    }

    private var vncPasswordTitle: String {
        session.profile == .macScreenSharing ? "Legacy VNC Password Required" : "VNC Password Required"
    }

    private var vncPasswordMessage: String {
        if session.profile == .macScreenSharing {
            return "The Mac did not accept or offer macOS account authentication. Enter the separate VNC password from Screen Sharing settings; do not reuse an admin password."
        }
        return "Enter the VNC password configured on the remote host."
    }

    private func disconnectAndExit() {
        Task {
            await session.disconnect()
            onDisconnect()
        }
    }

    #if os(macOS)
    private func requestRemoteResizeToWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let contentSize = window.contentLayoutRect.size
        let scale = window.backingScaleFactor
        let w = Int((contentSize.width * scale).rounded())
        let h = Int((contentSize.height * scale).rounded())
        session.requestRemoteResize(width: w, height: h)
    }
    #endif

    private func applyStreamControls() async {
        await session.updateStreamQuality(
            controlPreferences.streamQuality,
            profile: controlPreferences.streamProfile
        )
    }
}

private struct VNCConnectionSecurityBadge: View {
    let status: RemoteSecurityStatus

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbolName)
                .foregroundColor(status.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                Text(status.detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                if let action = status.recommendedAction {
                    Text(action)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.orange)
                        .lineLimit(3)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct VNCConnectionSecurityMenu: View {
    let status: RemoteSecurityStatus

    var body: some View {
        Menu {
            Label(status.title, systemImage: status.symbolName)
            Text(status.detail)
            if let action = status.recommendedAction {
                Divider()
                Label(action, systemImage: "exclamationmark.triangle")
            }
        } label: {
            Image(systemName: status.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(status.tint)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection security")
    }
}

extension RemoteSecurityStatus {
    var symbolName: String {
        switch level {
        case .encrypted:
            return "lock.shield"
        case .networkProtected:
            return "network.badge.shield.half.filled"
        case .legacyAuth:
            return "lock.trianglebadge.exclamationmark"
        case .unprotected:
            return "exclamationmark.shield"
        case .unknown:
            return "shield.lefthalf.filled"
        }
    }

    var tint: Color {
        switch level {
        case .encrypted:
            return .green
        case .networkProtected:
            return .blue
        case .legacyAuth:
            return .orange
        case .unprotected:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

#if os(iOS)
private struct VNCIOSTouchInputOverlay: UIViewRepresentable {
    @ObservedObject var session: VNCSession
    @ObservedObject var inputState: VNCIOSInputState
    let serverSize: CGSize
    let displayScale: CGFloat
    let viewportNavigationMode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            inputState: inputState,
            serverSize: serverSize,
            displayScale: displayScale,
            viewportNavigationMode: viewportNavigationMode
        )
    }

    func makeUIView(context: Context) -> TouchInputView {
        let view = TouchInputView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = context.coordinator

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        singleTap.require(toFail: doubleTap)

        let rightTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        rightTap.numberOfTapsRequired = 1
        rightTap.delegate = context.coordinator

        let middleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMiddleTap(_:)))
        middleTap.numberOfTouchesRequired = 3
        middleTap.numberOfTapsRequired = 1
        middleTap.delegate = context.coordinator

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(rightTap)
        view.addGestureRecognizer(middleTap)

        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        drag.delegate = context.coordinator
        view.addGestureRecognizer(drag)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPressDrag(_:)))
        longPress.minimumPressDuration = 0.42
        longPress.allowableMovement = 16
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)

        let scroll = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = context.coordinator
        view.addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        // Apple Pencil hover + indirect pointer (trackpad/mouse) hover.
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleHover(_:)))
        view.addGestureRecognizer(hover)

        context.coordinator.dragRecognizer = drag
        context.coordinator.longPressRecognizer = longPress
        context.coordinator.scrollRecognizer = scroll
        context.coordinator.pinchRecognizer = pinch
        return view
    }

    func updateUIView(_ uiView: TouchInputView, context: Context) {
        context.coordinator.session = session
        context.coordinator.inputState = inputState
        context.coordinator.serverSize = serverSize
        context.coordinator.displayScale = displayScale
        context.coordinator.viewportNavigationMode = viewportNavigationMode
    }

    final class TouchInputView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.contains(point)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var session: VNCSession?
        var inputState: VNCIOSInputState
        var serverSize: CGSize
        var displayScale: CGFloat
        var viewportNavigationMode: Bool
        weak var dragRecognizer: UIPanGestureRecognizer?
        weak var longPressRecognizer: UILongPressGestureRecognizer?
        weak var scrollRecognizer: UIPanGestureRecognizer?
        weak var pinchRecognizer: UIPinchGestureRecognizer?
        private var scrollRemainder: CGFloat = 0
        private var isDragging = false
        private var isPinchingViewport = false
        private var previousPinchScale: CGFloat = 1
        private var pendingViewportPan = CGSize.zero
        private var pendingPinchMagnification: CGFloat = 1
        private var lastViewportPanCommit = Date.distantPast
        private var lastViewportZoomCommit = Date.distantPast
        private let scrollStep: CGFloat = 18
        private let viewportPanStep: CGFloat = 40
        private let viewportGestureInterval: TimeInterval = 0.08
        private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
        private let longPressHaptic = UIImpactFeedbackGenerator(style: .medium)
        private let rightClickHaptic = UINotificationFeedbackGenerator()

        init(
            session: VNCSession,
            inputState: VNCIOSInputState,
            serverSize: CGSize,
            displayScale: CGFloat,
            viewportNavigationMode: Bool
        ) {
            self.session = session
            self.inputState = inputState
            self.serverSize = serverSize
            self.displayScale = displayScale
            self.viewportNavigationMode = viewportNavigationMode
        }

        @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed:
                let point = remotePoint(from: recognizer.location(in: view))
                session?.sendMouseMove(x: point.x, y: point.y)
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))
            tapHaptic.impactOccurred()
            sendClick(at: point, button: 0)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))
            sendClick(at: point, button: 0)
            sendClick(at: point, button: 0)
        }

        @objc func handleRightTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))
            rightClickHaptic.notificationOccurred(.success)
            sendClick(at: point, button: 2)
        }

        @objc func handleMiddleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))
            sendClick(at: point, button: 1)
        }

        @objc func handleDrag(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))

            switch recognizer.state {
            case .began:
                session?.sendMouseMove(x: point.x, y: point.y)
            case .changed:
                session?.sendMouseMove(x: point.x, y: point.y, buttons: isDragging ? 0x01 : 0)
            case .ended, .cancelled, .failed:
                if isDragging {
                    session?.sendMouseClick(x: point.x, y: point.y, button: 0, isDown: false)
                    isDragging = false
                }
            default:
                break
            }
        }

        @objc func handleLongPressDrag(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))

            switch recognizer.state {
            case .began:
                isDragging = true
                longPressHaptic.impactOccurred()
                session?.sendMouseMove(x: point.x, y: point.y)
                session?.sendMouseClick(x: point.x, y: point.y, button: 0, isDown: true)
            case .changed:
                session?.sendMouseMove(x: point.x, y: point.y, buttons: 0x01)
            case .ended, .cancelled, .failed:
                session?.sendMouseClick(x: point.x, y: point.y, button: 0, isDown: false)
                isDragging = false
            default:
                break
            }
        }

        @objc func handleScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))

            switch recognizer.state {
            case .began:
                scrollRemainder = 0
                pendingViewportPan = .zero
                lastViewportPanCommit = .distantPast
            case .changed:
                let translation = recognizer.translation(in: view)
                if viewportNavigationMode || isPinchingViewport {
                    pendingViewportPan.width += translation.x / max(displayScale, 0.001)
                    pendingViewportPan.height += translation.y / max(displayScale, 0.001)
                    recognizer.setTranslation(.zero, in: view)
                    guard shouldFlushViewportPan else {
                        return
                    }
                    flushPendingViewportPan()
                    return
                }

                scrollRemainder += translation.y
                recognizer.setTranslation(.zero, in: view)

                while abs(scrollRemainder) >= scrollStep {
                    session?.sendScroll(x: point.x, y: point.y, deltaY: scrollRemainder > 0 ? 1 : -1)
                    scrollRemainder += scrollRemainder > 0 ? -scrollStep : scrollStep
                }
            case .ended, .cancelled, .failed:
                if viewportNavigationMode || isPinchingViewport {
                    flushPendingViewportPan(force: true)
                }
                scrollRemainder = 0
                pendingViewportPan = .zero
            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let anchor = remotePoint(from: recognizer.location(in: view))
            switch recognizer.state {
            case .began:
                isPinchingViewport = true
                previousPinchScale = recognizer.scale
                pendingPinchMagnification = 1
                lastViewportZoomCommit = .distantPast
            case .changed:
                let delta = recognizer.scale / max(previousPinchScale, 0.001)
                previousPinchScale = recognizer.scale
                guard delta.isFinite, abs(delta - 1) > 0.01 else { return }
                pendingPinchMagnification *= delta
                guard shouldFlushViewportZoom else { return }
                flushPendingViewportZoom(anchor: anchor)
            case .ended, .cancelled, .failed:
                flushPendingViewportZoom(anchor: anchor, force: true)
                isPinchingViewport = false
                previousPinchScale = 1
                pendingPinchMagnification = 1
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            (gestureRecognizer === dragRecognizer && otherGestureRecognizer === longPressRecognizer) ||
            (gestureRecognizer === longPressRecognizer && otherGestureRecognizer === dragRecognizer) ||
            (gestureRecognizer === scrollRecognizer && otherGestureRecognizer === pinchRecognizer) ||
            (gestureRecognizer === pinchRecognizer && otherGestureRecognizer === scrollRecognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        private func sendClick(at point: (x: Int, y: Int), button: Int) {
            inputState.sendMouseClick(session: session, x: point.x, y: point.y, button: button)
        }

        private var shouldFlushViewportPan: Bool {
            guard abs(pendingViewportPan.width) >= viewportPanStep ||
                    abs(pendingViewportPan.height) >= viewportPanStep else {
                return false
            }
            return Date().timeIntervalSince(lastViewportPanCommit) >= viewportGestureInterval
        }

        private var shouldFlushViewportZoom: Bool {
            guard pendingPinchMagnification.isFinite,
                  abs(pendingPinchMagnification - 1) > 0.035 else {
                return false
            }
            return Date().timeIntervalSince(lastViewportZoomCommit) >= viewportGestureInterval
        }

        private func flushPendingViewportPan(force: Bool = false) {
            guard force || shouldFlushViewportPan else { return }
            let dx = Int(pendingViewportPan.width.rounded())
            let dy = Int(pendingViewportPan.height.rounded())
            pendingViewportPan = .zero
            guard dx != 0 || dy != 0 else { return }
            lastViewportPanCommit = Date()
            Task { @MainActor in
                await self.session?.panStreamViewport(deltaViewX: dx, deltaViewY: dy)
            }
        }

        private func flushPendingViewportZoom(anchor: (x: Int, y: Int), force: Bool = false) {
            guard pendingPinchMagnification.isFinite,
                  force || shouldFlushViewportZoom else {
                return
            }
            let magnification = pendingPinchMagnification
            pendingPinchMagnification = 1
            guard abs(magnification - 1) > 0.01 else { return }
            lastViewportZoomCommit = Date()
            Task { @MainActor in
                await self.session?.zoomStreamViewport(
                    magnification: magnification,
                    anchorViewX: anchor.x,
                    anchorViewY: anchor.y
                )
            }
        }

        private func remotePoint(from localPoint: CGPoint) -> (x: Int, y: Int) {
            guard displayScale > 0, serverSize.width > 0, serverSize.height > 0 else {
                return (0, 0)
            }

            let x = Int((localPoint.x / displayScale).rounded(.down))
            let y = Int((localPoint.y / displayScale).rounded(.down))
            return (
                max(0, min(Int(serverSize.width) - 1, x)),
                max(0, min(Int(serverSize.height) - 1, y))
            )
        }
    }
}

private enum VNCKeySym {
    static let backspace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let returnKey: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B
    static let delete: UInt32 = 0xFFFF
    static let home: UInt32 = 0xFF50
    static let left: UInt32 = 0xFF51
    static let up: UInt32 = 0xFF52
    static let right: UInt32 = 0xFF53
    static let down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55
    static let pageDown: UInt32 = 0xFF56
    static let end: UInt32 = 0xFF57
    static let shiftLeft: UInt32 = 0xFFE1
    static let shiftRight: UInt32 = 0xFFE2
    static let controlLeft: UInt32 = 0xFFE3
    static let controlRight: UInt32 = 0xFFE4
    static let altLeft: UInt32 = 0xFFE9
    static let altRight: UInt32 = 0xFFEA
    static let commandLeft: UInt32 = 0xFFE7
    static let superLeft: UInt32 = 0xFFEB
    static let superRight: UInt32 = 0xFFEC

    static func function(_ index: Int) -> UInt32 {
        UInt32(0xFFBD + max(1, min(12, index)))
    }
}

private enum VNCIOSModifier: CaseIterable, Identifiable {
    case shift
    case control
    case alt
    case windows

    var id: String { label }

    var label: String {
        switch self {
        case .shift: return "Shift"
        case .control: return "Control"
        case .alt: return "Alt"
        case .windows: return "Windows"
        }
    }

    func label(profile: RFBConnectionProfile) -> String {
        if self == .windows, profile == .macScreenSharing {
            return "Command"
        }
        return label
    }

    var symbol: String {
        switch self {
        case .shift: return "S"
        case .control: return "C"
        case .alt: return "A"
        case .windows: return "Win"
        }
    }

    func symbol(profile: RFBConnectionProfile) -> String {
        if self == .windows, profile == .macScreenSharing {
            return "Cmd"
        }
        return symbol
    }

    var keysym: UInt32 {
        switch self {
        case .shift: return VNCKeySym.shiftLeft
        case .control: return VNCKeySym.controlLeft
        case .alt: return VNCKeySym.altLeft
        case .windows: return VNCKeySym.superLeft
        }
    }

    func keysym(profile: RFBConnectionProfile) -> UInt32 {
        if self == .windows, profile == .macScreenSharing {
            return VNCKeySym.commandLeft
        }
        return keysym
    }
}

@MainActor
private final class VNCIOSInputState: ObservableObject {
    @Published private var states: [VNCIOSModifier: ModifierLatchState] = Dictionary(
        uniqueKeysWithValues: VNCIOSModifier.allCases.map { ($0, .off) }
    )

    func state(for modifier: VNCIOSModifier) -> ModifierLatchState {
        states[modifier] ?? .off
    }

    func toggleMomentary(_ modifier: VNCIOSModifier) {
        switch state(for: modifier) {
        case .off:
            states[modifier] = .momentary
        case .momentary, .locked:
            states[modifier] = .off
        }
    }

    func toggleLocked(_ modifier: VNCIOSModifier) {
        states[modifier] = state(for: modifier) == .locked ? .off : .locked
    }

    func clearAll() {
        states = Dictionary(uniqueKeysWithValues: VNCIOSModifier.allCases.map { ($0, .off) })
    }

    func sendText(_ text: String, session: VNCSession?) {
        for scalar in text.unicodeScalars {
            sendKey(scalar.value, session: session)
        }
    }

    func sendKey(_ key: UInt32, session: VNCSession?, explicitModifiers: [UInt32] = []) {
        let modifiers = mergedModifiers(explicitModifiers, profile: session?.profile ?? .genericVNC)
        if modifiers.isEmpty {
            session?.sendKeyTap(code: key)
        } else {
            session?.sendKeyCombo(code: key, modifiers: modifiers)
        }
        clearMomentary()
    }

    func sendMouseClick(session: VNCSession?, x: Int, y: Int, button: Int) {
        session?.sendMouseClick(x: x, y: y, button: button, isDown: true)
        session?.sendMouseClick(x: x, y: y, button: button, isDown: false)
        clearMomentary()
    }

    private func mergedModifiers(_ explicit: [UInt32], profile: RFBConnectionProfile) -> [UInt32] {
        var result = explicit
        for modifier in VNCIOSModifier.allCases where state(for: modifier) != .off {
            let keysym = modifier.keysym(profile: profile)
            if !result.contains(keysym) {
                result.append(keysym)
            }
        }
        return result
    }

    private func clearMomentary() {
        var next = states
        for (modifier, state) in states where state == .momentary {
            next[modifier] = .off
        }
        states = next
    }
}

private struct VNCIOSControlStrip: View {
    @ObservedObject var session: VNCSession
    @ObservedObject var inputState: VNCIOSInputState
    let securityStatus: RemoteSecurityStatus
    @Binding var streamQuality: Double
    @Binding var streamProfile: StreamProfile
    @Binding var isKeyboardActive: Bool
    @Binding var viewportNavigationMode: Bool
    var onDisconnect: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Primary controls (always visible)
                iconButton(systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
                           label: isKeyboardActive ? "Hide keyboard" : "Show keyboard") {
                    isKeyboardActive.toggle()
                }
                viewportModeButton

                Divider().frame(height: 28)

                // Modifier keys
                ForEach(VNCIOSModifier.allCases) { modifier in
                    modifierButton(modifier)
                }

                Divider().frame(height: 28)

                // Combined keys menu
                allKeysMenu

                iconButton(systemName: "doc.on.clipboard", label: "Send clipboard to remote") {
                    session.sendLocalPasteboardIfAvailable()
                }

                Divider().frame(height: 28)

                VNCConnectionSecurityMenu(status: securityStatus)
                StreamQualityButton(
                    quality: $streamQuality,
                    profile: $streamProfile,
                    protocolName: session.profile.displayName,
                    detail: "Controls VNC request cadence, viewport size, and local framebuffer rendering."
                )

                // Overflow menu for less-used items
                overflowMenu

                iconButton(systemName: "xmark.circle", label: "Disconnect", tint: .red) {
                    onDisconnect()
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 58)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
    }

    private var allKeysMenu: some View {
        Menu {
            Section("Special") {
                Button("Escape") { inputState.sendKey(VNCKeySym.escape, session: session) }
                Button("Tab") { inputState.sendKey(VNCKeySym.tab, session: session) }
                Button("Return") { inputState.sendKey(VNCKeySym.returnKey, session: session) }
                Button("Backspace") { inputState.sendKey(VNCKeySym.backspace, session: session) }
                Button("Delete") { inputState.sendKey(VNCKeySym.delete, session: session) }
                Button("Home") { inputState.sendKey(VNCKeySym.home, session: session) }
                Button("End") { inputState.sendKey(VNCKeySym.end, session: session) }
                Button("Page Up") { inputState.sendKey(VNCKeySym.pageUp, session: session) }
                Button("Page Down") { inputState.sendKey(VNCKeySym.pageDown, session: session) }
            }
            Section("Arrows") {
                Button("Up") { inputState.sendKey(VNCKeySym.up, session: session) }
                Button("Down") { inputState.sendKey(VNCKeySym.down, session: session) }
                Button("Left") { inputState.sendKey(VNCKeySym.left, session: session) }
                Button("Right") { inputState.sendKey(VNCKeySym.right, session: session) }
            }
            Section("Function") {
                ForEach(1...12, id: \.self) { index in
                    Button("F\(index)") {
                        inputState.sendKey(VNCKeySym.function(index), session: session)
                    }
                }
            }
            Section {
                Button("Clear Modifiers") { inputState.clearAll() }
            }
        } label: {
            Image(systemName: "command.square")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Section("Display") {
                if session.isUsingStreamViewport {
                    Button {
                        Task { await session.resetStreamViewport() }
                    } label: {
                        Label("Reset viewport", systemImage: "minus.magnifyingglass")
                    }
                }
                ForEach(session.displayRegions) { region in
                    Button {
                        Task { await session.selectDisplayRegion(region) }
                    } label: {
                        Label(region.name + " " + region.detail, systemImage: session.selectedDisplayRegion?.id == region.id ? "checkmark" : "")
                    }
                }
            }
            Section("Shortcuts") {
                Button("⌘ Tab") { session.sendKeyCombo(code: VNCKeySym.tab, modifiers: [VNCKeySym.commandLeft]) }
                Button("⌘ Space") { session.sendKeyCombo(code: 0x0020, modifiers: [VNCKeySym.commandLeft]) }
                Button("⌘ Q") { session.sendKeyCombo(code: 0x0071, modifiers: [VNCKeySym.commandLeft]) }
                Button("Force Quit") {
                    session.sendKeyCombo(code: VNCKeySym.escape, modifiers: [VNCKeySym.commandLeft, VNCKeySym.altLeft])
                }
                Button("Ctrl Alt Del") {
                    session.sendKeyCombo(code: VNCKeySym.delete, modifiers: [VNCKeySym.controlLeft, VNCKeySym.altLeft])
                }
                Button("Alt Tab") {
                    session.sendKeyCombo(code: VNCKeySym.tab, modifiers: [VNCKeySym.altLeft])
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
    }

    private func modifierButton(_ modifier: VNCIOSModifier) -> some View {
        let state = inputState.state(for: modifier)
        let symbol = modifier.symbol(profile: session.profile)
        return Text(symbol)
            .font(.system(size: symbol.count > 1 ? 12 : 15, weight: .semibold))
            .frame(width: 38, height: 38)
            .foregroundStyle(state == .off ? Color.primary : Color.white)
            .background(modifierBackground(for: state))
            .clipShape(Circle())
            .onTapGesture(count: 2) {
                inputState.toggleLocked(modifier)
            }
            .onTapGesture {
                inputState.toggleMomentary(modifier)
            }
            .accessibilityLabel("\(modifier.label(profile: session.profile)) modifier")
    }

    private func modifierBackground(for state: ModifierLatchState) -> Color {
        switch state {
        case .off: return Color.primary.opacity(0.08)
        case .momentary: return Color.accentColor.opacity(0.72)
        case .locked: return Color.accentColor
        }
    }

    private var specialKeysMenu: some View {
        Menu {
            Button("Escape") { inputState.sendKey(VNCKeySym.escape, session: session) }
            Button("Tab") { inputState.sendKey(VNCKeySym.tab, session: session) }
            Button("Return") { inputState.sendKey(VNCKeySym.returnKey, session: session) }
            Button("Backspace") { inputState.sendKey(VNCKeySym.backspace, session: session) }
            Button("Delete") { inputState.sendKey(VNCKeySym.delete, session: session) }
            Button("Home") { inputState.sendKey(VNCKeySym.home, session: session) }
            Button("End") { inputState.sendKey(VNCKeySym.end, session: session) }
            Button("Page Up") { inputState.sendKey(VNCKeySym.pageUp, session: session) }
            Button("Page Down") { inputState.sendKey(VNCKeySym.pageDown, session: session) }
            Button("Clear Modifiers") { inputState.clearAll() }
        } label: {
            Image(systemName: "command.square")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Special keys")
    }

    private var arrowsMenu: some View {
        Menu {
            Button("Up") { inputState.sendKey(VNCKeySym.up, session: session) }
            Button("Down") { inputState.sendKey(VNCKeySym.down, session: session) }
            Button("Left") { inputState.sendKey(VNCKeySym.left, session: session) }
            Button("Right") { inputState.sendKey(VNCKeySym.right, session: session) }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arrow keys")
    }

    private var functionKeysMenu: some View {
        Menu {
            ForEach(1...12, id: \.self) { index in
                Button("F\(index)") {
                    inputState.sendKey(VNCKeySym.function(index), session: session)
                }
            }
        } label: {
            Text("F")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Function keys")
    }

    private var displayMenu: some View {
        Menu {
            if session.displayRegions.isEmpty {
                Text("No display regions available")
            } else {
                ForEach(session.displayRegions) { region in
                    Button {
                        Task { await session.selectDisplayRegion(region) }
                    } label: {
                        if region == session.selectedDisplayRegion {
                            Label("\(region.name) — \(region.detail)", systemImage: "checkmark")
                        } else {
                            Text("\(region.name) — \(region.detail)")
                        }
                    }
                }
                if session.profile == .macScreenSharing {
                    Divider()
                    Text("Apple RFB exposes one combined framebuffer. Screen Q may use a memory-safe viewport when the selected region is too large.")
                }
            }
        } label: {
            Image(systemName: session.displayRegions.count > 1 ? "display.2" : "display")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Display region")
    }

    private var viewportModeButton: some View {
        iconButton(
            systemName: viewportNavigationMode ? "hand.draw.fill" : "scroll",
            label: viewportNavigationMode ? "Two-finger pan moves the viewport" : "Two-finger pan scrolls the remote screen",
            tint: viewportNavigationMode ? .accentColor : .primary
        ) {
            viewportNavigationMode.toggle()
        }
    }

    private var platformShortcutsMenu: some View {
        if session.profile == .macScreenSharing {
            return AnyView(macShortcutsMenu)
        }
        return AnyView(windowsMenu)
    }

    private var macShortcutsMenu: some View {
        Menu {
            Button("Command Tab") {
                session.sendKeyCombo(code: VNCKeySym.tab, modifiers: [VNCKeySym.commandLeft])
            }
            Button("Command Space") {
                session.sendKeyCombo(code: 0x0020, modifiers: [VNCKeySym.commandLeft])
            }
            Button("Command W") {
                session.sendKeyCombo(code: 0x0077, modifiers: [VNCKeySym.commandLeft])
            }
            Button("Command Q") {
                session.sendKeyCombo(code: 0x0071, modifiers: [VNCKeySym.commandLeft])
            }
            Button("Force Quit") {
                session.sendKeyCombo(code: VNCKeySym.escape, modifiers: [VNCKeySym.commandLeft, VNCKeySym.altLeft])
            }
        } label: {
            Image(systemName: "command")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mac shortcuts")
    }

    private var windowsMenu: some View {
        Menu {
            Button("Ctrl Alt Del") {
                session.sendKeyCombo(code: VNCKeySym.delete, modifiers: [VNCKeySym.controlLeft, VNCKeySym.altLeft])
            }
            Button("Alt Tab") {
                session.sendKeyCombo(code: VNCKeySym.tab, modifiers: [VNCKeySym.altLeft])
            }
            Button("Windows") {
                inputState.sendKey(VNCKeySym.superLeft, session: session)
            }
            Button("Windows D") {
                session.sendKeyCombo(code: 0x0064, modifiers: [VNCKeySym.superLeft])
            }
            Button("Windows L") {
                session.sendKeyCombo(code: 0x006C, modifiers: [VNCKeySym.superLeft])
            }
        } label: {
            Image(systemName: "pc")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Windows shortcuts")
    }

    private func iconButton(
        systemName: String,
        label: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct VNCKeyboardInputView: UIViewRepresentable {
    @ObservedObject var session: VNCSession
    @ObservedObject var inputState: VNCIOSInputState
    @Binding var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, inputState: inputState, isActive: $isActive)
    }

    func makeUIView(context: Context) -> VNCKeyboardTextField {
        let field = VNCKeyboardTextField()
        field.coordinator = context.coordinator
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .default
        field.returnKeyType = .default
        return field
    }

    func updateUIView(_ uiView: VNCKeyboardTextField, context: Context) {
        context.coordinator.session = session
        context.coordinator.inputState = inputState
        context.coordinator.isActive = $isActive
        if isActive && !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !isActive && uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        weak var session: VNCSession?
        var inputState: VNCIOSInputState
        var isActive: Binding<Bool>

        init(session: VNCSession, inputState: VNCIOSInputState, isActive: Binding<Bool>) {
            self.session = session
            self.inputState = inputState
            self.isActive = isActive
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.isActive.wrappedValue = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.isActive.wrappedValue = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            inputState.sendKey(VNCKeySym.returnKey, session: session)
            return false
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                inputState.sendKey(VNCKeySym.backspace, session: session)
            } else {
                inputState.sendText(string, session: session)
            }
            return false
        }
    }
}

private final class VNCKeyboardTextField: UITextField {
    weak var coordinator: VNCKeyboardInputView.Coordinator?

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let modSets: [UIKeyModifierFlags] = [[], [.shift], [.control], [.alternate], [.command],
                                             [.shift, .control], [.control, .alternate],
                                             [.command, .shift], [.command, .alternate]]
        var cmds: [UIKeyCommand] = []
        let specialInputs = [
            UIKeyCommand.inputEscape,
            "\t",
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
            UIKeyCommand.inputPageUp,
            UIKeyCommand.inputPageDown,
            UIKeyCommand.inputHome,
            UIKeyCommand.inputEnd,
        ]
        for input in specialInputs {
            for mods in modSets {
                cmds.append(UIKeyCommand(input: input, modifierFlags: mods, action: #selector(handleSpecialKey(_:))))
            }
        }
        // F-keys (F1-F12) — use the system-defined input strings.
        let fKeyInputs: [String] = [
            UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4,
            UIKeyCommand.f5, UIKeyCommand.f6, UIKeyCommand.f7, UIKeyCommand.f8,
            UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12,
        ]
        for input in fKeyInputs {
            cmds.append(UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleSpecialKey(_:))))
        }
        return cmds
    }

    override func deleteBackward() {
        coordinator?.inputState.sendKey(VNCKeySym.backspace, session: coordinator?.session)
    }

    @objc private func handleSpecialKey(_ command: UIKeyCommand) {
        guard let coordinator else { return }
        let modifiers = vncModifiers(from: command.modifierFlags)
        let keysym: UInt32?
        switch command.input {
        case UIKeyCommand.inputEscape:   keysym = VNCKeySym.escape
        case "\t":                       keysym = VNCKeySym.tab
        case UIKeyCommand.inputUpArrow:  keysym = VNCKeySym.up
        case UIKeyCommand.inputDownArrow: keysym = VNCKeySym.down
        case UIKeyCommand.inputLeftArrow: keysym = VNCKeySym.left
        case UIKeyCommand.inputRightArrow: keysym = VNCKeySym.right
        case UIKeyCommand.inputPageUp:   keysym = VNCKeySym.pageUp
        case UIKeyCommand.inputPageDown: keysym = VNCKeySym.pageDown
        case UIKeyCommand.inputHome:     keysym = VNCKeySym.home
        case UIKeyCommand.inputEnd:      keysym = VNCKeySym.end
        default:
            keysym = fKeyKeysym(for: command.input)
        }
        if let keysym {
            coordinator.inputState.sendKey(keysym, session: coordinator.session, explicitModifiers: modifiers)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let keysym = uiKeyToKeysym(key) {
                coordinator?.session?.sendKey(code: keysym, isDown: true)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let keysym = uiKeyToKeysym(key) {
                coordinator?.session?.sendKey(code: keysym, isDown: false)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    private func uiKeyToKeysym(_ key: UIKey) -> UInt32? {
        switch key.keyCode {
        case .keyboardCapsLock:     return 0xFFE5
        case .keyboardLeftShift:    return VNCKeySym.shiftLeft
        case .keyboardRightShift:   return VNCKeySym.shiftRight
        case .keyboardLeftControl:  return VNCKeySym.controlLeft
        case .keyboardRightControl: return VNCKeySym.controlRight
        case .keyboardLeftAlt:      return VNCKeySym.altLeft
        case .keyboardRightAlt:     return VNCKeySym.altRight
        case .keyboardLeftGUI:      return VNCKeySym.superLeft
        case .keyboardRightGUI:     return VNCKeySym.superRight
        default: return nil
        }
    }

    private static let fKeyMap: [String: UInt32] = {
        let inputs = [
            UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4,
            UIKeyCommand.f5, UIKeyCommand.f6, UIKeyCommand.f7, UIKeyCommand.f8,
            UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12,
        ]
        var map: [String: UInt32] = [:]
        for (i, input) in inputs.enumerated() {
            map[input] = VNCKeySym.function(i + 1)
        }
        return map
    }()

    private func fKeyKeysym(for input: String?) -> UInt32? {
        guard let input else { return nil }
        return Self.fKeyMap[input]
    }

    private func vncModifiers(from flags: UIKeyModifierFlags) -> [UInt32] {
        var modifiers: [UInt32] = []
        if flags.contains(.shift) { modifiers.append(VNCKeySym.shiftLeft) }
        if flags.contains(.control) { modifiers.append(VNCKeySym.controlLeft) }
        if flags.contains(.alternate) { modifiers.append(VNCKeySym.altLeft) }
        if flags.contains(.command) { modifiers.append(VNCKeySym.superLeft) }
        return modifiers
    }
}
#endif

// MARK: - Password / Credentials Sheets (macOS 11.5+)

private struct VNCPasswordSheet: View {
    let title: String
    let message: String
    @Binding var password: String
    @Binding var rememberCredentials: Bool
    @Binding var requireLocalAuthenticationForSavedCredentials: Bool
    var onConnect: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Toggle("Remember in Keychain", isOn: $rememberCredentials)
                .frame(maxWidth: 260)
            if rememberCredentials {
                Toggle("Require Touch ID / Face ID / passcode before reuse", isOn: $requireLocalAuthenticationForSavedCredentials)
                    .frame(maxWidth: 260)
            }
            Text("Saved Mac Screen Sharing credentials stay in this device's Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { onConnect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}

private struct VNCCredentialsSheet: View {
    @Binding var username: String
    @Binding var password: String
    @Binding var rememberCredentials: Bool
    @Binding var requireLocalAuthenticationForSavedCredentials: Bool
    var onConnect: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("macOS Login Required").font(.headline)
            Text("Enter the macOS username and password for the remote Mac.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Toggle("Remember in Keychain", isOn: $rememberCredentials)
                .frame(maxWidth: 260)
            if rememberCredentials {
                Toggle("Require Touch ID / Face ID / passcode before reuse", isOn: $requireLocalAuthenticationForSavedCredentials)
                    .frame(maxWidth: 260)
            }
            Text("Saved VNC credentials stay in this device's Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { onConnect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
