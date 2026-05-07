//
//  VNCSession.swift
//  Screen Q
//
//  High-level ObservableObject that drives a VNC viewer session.
//  Connects to an RFB server, maintains a framebuffer, publishes
//  the current image for SwiftUI, and forwards input events.
//

import Foundation
import Network
import Combine
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated struct VNCDisplayRegion: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var isFullDesktop: Bool { x == 0 && y == 0 && id == "all" }
    var pixelCount: Int { width * height }

    static func options(serverWidth: Int, serverHeight: Int) -> [VNCDisplayRegion] {
        guard serverWidth > 0, serverHeight > 0 else { return [] }

        var regions: [VNCDisplayRegion] = [
            VNCDisplayRegion(
                id: "all",
                name: "All Displays",
                detail: "\(serverWidth)x\(serverHeight)",
                x: 0,
                y: 0,
                width: serverWidth,
                height: serverHeight
            )
        ]

        let aspect = CGFloat(serverWidth) / CGFloat(serverHeight)
        if serverWidth >= 3_000, aspect >= 1.6 {
            let leftWidth = serverWidth / 2
            regions.append(VNCDisplayRegion(
                id: "left",
                name: "Left Region",
                detail: "\(leftWidth)x\(serverHeight)",
                x: 0,
                y: 0,
                width: leftWidth,
                height: serverHeight
            ))
            regions.append(VNCDisplayRegion(
                id: "right",
                name: "Right Region",
                detail: "\(serverWidth - leftWidth)x\(serverHeight)",
                x: leftWidth,
                y: 0,
                width: serverWidth - leftWidth,
                height: serverHeight
            ))
        }

        let verticalAspect = CGFloat(serverHeight) / CGFloat(serverWidth)
        if serverHeight >= 2_200, verticalAspect >= 1.2 {
            let topHeight = serverHeight / 2
            regions.append(VNCDisplayRegion(
                id: "top",
                name: "Top Region",
                detail: "\(serverWidth)x\(topHeight)",
                x: 0,
                y: 0,
                width: serverWidth,
                height: topHeight
            ))
            regions.append(VNCDisplayRegion(
                id: "bottom",
                name: "Bottom Region",
                detail: "\(serverWidth)x\(serverHeight - topHeight)",
                x: 0,
                y: topHeight,
                width: serverWidth,
                height: serverHeight - topHeight
            ))
        }

        if serverWidth >= 5_000, serverHeight >= 2_500 {
            let halfWidth = serverWidth / 2
            let halfHeight = serverHeight / 2
            regions.append(VNCDisplayRegion(
                id: "top-left",
                name: "Top Left Region",
                detail: "\(halfWidth)x\(halfHeight)",
                x: 0,
                y: 0,
                width: halfWidth,
                height: halfHeight
            ))
            regions.append(VNCDisplayRegion(
                id: "top-right",
                name: "Top Right Region",
                detail: "\(serverWidth - halfWidth)x\(halfHeight)",
                x: halfWidth,
                y: 0,
                width: serverWidth - halfWidth,
                height: halfHeight
            ))
            regions.append(VNCDisplayRegion(
                id: "bottom-left",
                name: "Bottom Left Region",
                detail: "\(halfWidth)x\(serverHeight - halfHeight)",
                x: 0,
                y: halfHeight,
                width: halfWidth,
                height: serverHeight - halfHeight
            ))
            regions.append(VNCDisplayRegion(
                id: "bottom-right",
                name: "Bottom Right Region",
                detail: "\(serverWidth - halfWidth)x\(serverHeight - halfHeight)",
                x: halfWidth,
                y: halfHeight,
                width: serverWidth - halfWidth,
                height: serverHeight - halfHeight
            ))
        }

        return regions
    }
}

private struct VNCConnectionRouteAttempt: Identifiable, Sendable {
    let id = UUID()
    let connection: RFBConnection
    let logicalHost: String
    let logicalPort: UInt16
    let routedHost: String?
    let routedPort: UInt16?
    let routeLabel: VNCRouteLabel?
    let isCached: Bool
}

private struct VNCConnectedRoute: Sendable {
    let attempt: VNCConnectionRouteAttempt
    let serverInit: RFBServerInit
}

private struct VNCRouteFailure: @unchecked Sendable {
    let attempt: VNCConnectionRouteAttempt
    let error: Error
}

private enum VNCRouteAttemptOutcome: @unchecked Sendable {
    case connected(VNCConnectedRoute)
    case failed(VNCRouteFailure)
}

nonisolated struct VNCFirstFrameTelemetry: Equatable, Sendable {
    var connectionStartedAt: Date?
    var authenticatedAt: Date?
    var connectedAt: Date?
    var firstFramebufferRequestAt: Date?
    var firstFramebufferAt: Date?
    var recoveryFullFrameRequests: Int = 0
    var reconnects: Int = 0
    var lastFailure: String?
    var lastRequestReason: String?
    var offeredSecurityModes: [RFBSecurityMode] = []
    var negotiatedSecurityMode: RFBSecurityMode = .unknown

    var firstFrameDuration: TimeInterval? {
        guard let connectionStartedAt, let firstFramebufferAt else { return nil }
        return firstFramebufferAt.timeIntervalSince(connectionStartedAt)
    }

    var statusText: String {
        if let firstFrameDuration {
            return "First frame \(Self.formatSeconds(firstFrameDuration))"
        }
        if let lastFailure, !lastFailure.isEmpty {
            return "First frame stalled: \(lastFailure)"
        }
        if let firstFramebufferRequestAt {
            let elapsed = Date().timeIntervalSince(firstFramebufferRequestAt)
            let reason = lastRequestReason.map { " \($0)" } ?? ""
            return "Waiting for\(reason) framebuffer \(Self.formatSeconds(elapsed))"
        }
        if let connectedAt {
            return "Connected \(Self.formatSeconds(Date().timeIntervalSince(connectedAt)))"
        }
        if authenticatedAt != nil {
            return "Authenticated; waiting for server init"
        }
        if connectionStartedAt != nil {
            return "Dialing RFB"
        }
        return "Waiting for framebuffer"
    }

    var securitySummary: String? {
        guard negotiatedSecurityMode != .unknown else { return nil }
        return "Auth \(negotiatedSecurityMode.displayName)"
    }

    static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", max(0, seconds))
    }
}

private func connectVNCConnectionRouteAttempt(
    _ attempt: VNCConnectionRouteAttempt,
    username: String?,
    password: String?,
    securityPreference: RFBSecurityPreference,
    timeouts: RFBConnectionTimeouts
) async -> VNCRouteAttemptOutcome {
    do {
        let serverInit = try await attempt.connection.connect(
            username: username,
            password: password,
            securityPreference: securityPreference,
            timeouts: timeouts
        )
        return .connected(VNCConnectedRoute(attempt: attempt, serverInit: serverInit))
    } catch {
        await attempt.connection.disconnect()
        return .failed(VNCRouteFailure(attempt: attempt, error: error))
    }
}

@MainActor
final class VNCSession: ObservableObject {

    enum Phase: Equatable {
        case connecting
        case authenticating
        case connected
        case reconnecting(attempt: Int)
        case failed(reason: String)
        case ended(reason: String)
    }

    @Published private(set) var phase: Phase = .connecting
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private let maxReconnectAttempts = 5
    @Published private(set) var currentImage: CGImage?
    @Published private(set) var renderRevision: UInt64 = 0
    @Published private(set) var serverName: String = ""
    @Published private(set) var serverWidth: Int = 0
    @Published private(set) var serverHeight: Int = 0
    @Published private(set) var displayRegions: [VNCDisplayRegion] = []
    @Published private(set) var selectedDisplayRegion: VNCDisplayRegion?
    @Published private(set) var streamRegion: VNCDisplayRegion?
    @Published var vncPassword: String = ""
    @Published var username: String = ""
    @Published var needsPassword = false       // VNC Auth (type 2)
    @Published var needsCredentials = false     // Apple DH (type 30)
    @Published var rememberCredentials = true
    @Published var requireLocalAuthenticationForSavedCredentials = true
    @Published private(set) var securityStatus: RemoteSecurityStatus = .unknown
    @Published private(set) var streamQualityPreference = StreamQualityPreference()
    @Published private(set) var streamProfile = StreamQualityPreference().nativeProfile
    @Published private(set) var firstFrameTelemetry = VNCFirstFrameTelemetry()
    let inputMapper = InputMappingService()
    let recorder = SessionRecorder()

    // Cursor tracking for iOS overlay.
    @Published private(set) var cursorViewX: Int = 0
    @Published private(set) var cursorViewY: Int = 0
    @Published private(set) var cursorVisible: Bool = false
    @Published private(set) var cursorImage: CGImage?
    @Published private(set) var cursorHotspot: CGPoint = .zero
    private var cursorHideTimer: Timer?

    // Quality / performance metrics (sampled once per second).
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var lastEncoding: String = ""
    private var fpsAccumulator: Int = 0
    private var fpsWindowStart: Date = Date()

    // Clipboard sync (macOS pasteboard polling).
    private var clipboardSyncTimer: Timer?
    #if os(macOS)
    private var lastPasteboardChangeCount: Int = 0
    #endif

    let remoteSessionID = UUID()
    let peerLabel: String
    let profile: RFBConnectionProfile

    private var connection: RFBConnection?
    private var connectTask: Task<Void, Never>?
    private var frameBuffer: RFBFrameBuffer?
    private var messageTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var streamRegionRequestTask: Task<Void, Never>?
    private(set) var metalRenderer: MetalFrameBufferRenderer?
    private var useMetalRendering: Bool = false
    private let host: String
    private let port: UInt16
    private let endpoint: NWEndpoint?
    private var forceLegacyVNCPasswordAuth = false
    private var isDisconnecting = false
    private var lastImagePublish = Date.distantPast
    private var viewportAspect: CGFloat = 4.0 / 3.0
    private var isViewportRefreshPending = false
    private var lastStreamRegionRequest = Date.distantPast
    private let minimumStreamRegionRequestInterval: TimeInterval = 0.10
    private var framebufferWaitStartedAt = Date.distantPast
    private var lastFramebufferUpdateAt = Date.distantPast
    private var lastFramebufferRequestAt = Date.distantPast
    private var lastFullFramebufferRequestAt = Date.distantPast
    private let firstFramebufferTimeout: TimeInterval = 18.0
    private let emptyFramebufferRetryInterval: TimeInterval = 3.0
    private let steadyStateFullRefreshInterval: TimeInterval = 15.0

    // MARK: - Init

    init(host: String, port: UInt16 = 5900, label: String, profile: RFBConnectionProfile = .genericVNC) {
        self.host = host
        self.port = port
        self.endpoint = nil
        self.peerLabel = label
        self.profile = profile
        self.securityStatus = .vncConnecting(scope: NetworkTrustScope.classify(host: host), profile: profile)
        configureInputMapper()
    }

    init(endpoint: NWEndpoint, label: String, profile: RFBConnectionProfile = .macScreenSharing) {
        self.host = ""
        self.port = 5900
        self.endpoint = endpoint
        self.peerLabel = label
        self.profile = profile
        self.securityStatus = .vncConnecting(scope: NetworkTrustScope.classify(host: label), profile: profile)
        configureInputMapper()
    }

    deinit {
        connectTask?.cancel()
        messageTask?.cancel()
        refreshTask?.cancel()
        streamRegionRequestTask?.cancel()
    }

    // MARK: - Connect

    func startConnecting() {
        connectTask?.cancel()
        streamRegionRequestTask?.cancel()
        streamRegionRequestTask = nil
        isViewportRefreshPending = false
        isDisconnecting = false
        framebufferWaitStartedAt = .distantPast
        lastFramebufferUpdateAt = .distantPast
        lastFramebufferRequestAt = .distantPast
        lastFullFramebufferRequestAt = .distantPast
        resetFirstFrameTelemetry()
        connectTask = Task { [weak self] in
            await self?.connect()
        }
    }

    private func connect() async {
        phase = .connecting
        securityStatus = .vncConnecting(scope: networkTrustScope, profile: profile)
        guard prepareCredentialPreflightForDial() else { return }

        do {
            let connectedRoute = try await connectUsingPreferredRoute(
                username: username.isEmpty ? nil : username,
                password: vncPassword.isEmpty ? nil : vncPassword,
                securityPreference: currentSecurityPreference,
                timeouts: connectionTimeouts
            )
            let conn = connectedRoute.attempt.connection
            self.connection = conn
            let serverInit = connectedRoute.serverInit
            guard shouldContinueConnecting else {
                await conn.disconnect()
                return
            }
            serverName = serverInit.name
            serverWidth = Int(serverInit.width)
            serverHeight = Int(serverInit.height)
            displayRegions = VNCDisplayRegion.options(serverWidth: serverWidth, serverHeight: serverHeight)
            selectedDisplayRegion = displayRegions.first
            streamRegion = initialStreamRegion(in: selectedDisplayRegion)
            frameBuffer = makeFrameBuffer(for: streamRegion)
            if let renderer = metalRenderer, let frameBuffer {
                renderer.ensureTextureSize(width: frameBuffer.width, height: frameBuffer.height)
            }
            let securityReport = await conn.securityReport()
            recordSecurityReport(securityReport, authenticated: true)
            securityStatus = .vnc(report: securityReport, scope: networkTrustScope, profile: profile)
            guard shouldContinueConnecting else {
                await conn.disconnect()
                return
            }
            phase = .connected
            reconnectAttempt = 0
            markServerConnectedForFirstFrame()
            framebufferWaitStartedAt = Date()
            lastFramebufferUpdateAt = .distantPast
            lastFramebufferRequestAt = .distantPast
            lastFullFramebufferRequestAt = .distantPast
            Logger.shared.info("VNC connected to \(serverInit.name) (\(serverInit.width)×\(serverInit.height))")
            recordSuccessfulRoute(connectedRoute.attempt)
            saveCredentialIfAllowed()
            startMessageLoop(conn)
            startRefreshLoop(conn)
            startClipboardSync()
        } catch RFBError.authRequired {
            guard shouldContinueConnecting else { return }
            let report = await currentSecurityReport()
            recordSecurityReport(report, authenticated: false)
            securityStatus = .vnc(report: report, scope: networkTrustScope, profile: profile)
            needsPassword = true
            phase = .authenticating
            await disconnectCurrentConnection()
        } catch RFBError.credentialsRequired {
            guard shouldContinueConnecting else { return }
            let report = await currentSecurityReport()
            recordSecurityReport(report, authenticated: false)
            securityStatus = .vnc(report: report, scope: networkTrustScope, profile: profile)
            needsCredentials = true
            phase = .authenticating
            await disconnectCurrentConnection()
        } catch RFBError.unsupportedSecurity(let type) {
            guard shouldContinueConnecting else { return }
            await failUnsupportedSecurity(type)
        } catch RFBError.timeout(let stage) {
            guard shouldContinueConnecting else { return }
            let report = await currentSecurityReport()
            recordSecurityReport(report, authenticated: false)
            if promptForLegacyVNCPasswordIfAvailable(afterTimeoutAt: stage, report: report) {
                await disconnectCurrentConnection()
                return
            }
            await failConnection(with: RFBError.timeout(stage: stage))
        } catch RFBError.authFailed(let reason) {
            guard shouldContinueConnecting else { return }
            let report = await currentSecurityReport()
            recordSecurityReport(report, authenticated: false)
            let isMacAccountFailure = profile == .macScreenSharing && report.mode == .appleDH
            securityStatus = RemoteSecurityStatus(
                level: .legacyAuth,
                title: isMacAccountFailure ? "Mac account credentials rejected" : "\(profile.displayName) authentication failed",
                detail: reason,
                isTransportEncrypted: false,
                isAuthenticated: false,
                recommendedAction: isMacAccountFailure ? "Check that the target Mac allows this user in Screen Sharing or Remote Management, then try again." : networkTrustScope.publicNetworkWarning,
                protocolName: profile.displayName,
                authMethod: report.mode == .appleDH ? "Apple Screen Sharing account credentials" : "Legacy VNC password",
                credentialStorage: "Keychain",
                identityVerification: profile == .macScreenSharing ? "macOS sharing permissions" : nil,
                warnings: ["RFB traffic is not encrypted by Screen Q; use a private network, VPN, or Tailscale."]
            )
            needsCredentials = report.mode == .appleDH
            needsPassword = report.mode == .vncAuth
            phase = (needsCredentials || needsPassword) ? .authenticating : .failed(reason: reason)
            await disconnectCurrentConnection()
        } catch is CancellationError {
            phase = .ended(reason: "Disconnected")
        } catch RFBError.disconnected where isDisconnecting {
            phase = .ended(reason: "Disconnected")
        } catch {
            guard shouldContinueConnecting else { return }
            await failConnection(with: error)
        }
    }

    /// Retry connection after VNC password is entered.
    func retryWithPassword() async {
        needsPassword = false
        startConnecting()
    }

    /// Retry connection after macOS credentials are entered.
    func retryWithCredentials() async {
        forceLegacyVNCPasswordAuth = false
        needsCredentials = false
        startConnecting()
    }

    func disconnect() async {
        guard !isDisconnecting else {
            phase = .ended(reason: "Disconnected")
            return
        }
        isDisconnecting = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        messageTask?.cancel()
        messageTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        streamRegionRequestTask?.cancel()
        streamRegionRequestTask = nil
        stopClipboardSync()
        cursorHideTimer?.invalidate()
        cursorHideTimer = nil
        await connection?.disconnect()
        connection = nil
        needsPassword = false
        needsCredentials = false
        forceLegacyVNCPasswordAuth = false
        currentImage = nil
        frameBuffer = nil
        framebufferWaitStartedAt = .distantPast
        lastFramebufferUpdateAt = .distantPast
        lastFramebufferRequestAt = .distantPast
        lastFullFramebufferRequestAt = .distantPast
        phase = .ended(reason: "Disconnected")
    }

    var viewWidth: Int {
        streamRegion?.width ?? selectedDisplayRegion?.width ?? serverWidth
    }

    var viewHeight: Int {
        streamRegion?.height ?? selectedDisplayRegion?.height ?? serverHeight
    }

    var viewportOriginX: Int {
        streamRegion?.x ?? selectedDisplayRegion?.x ?? 0
    }

    var viewportOriginY: Int {
        streamRegion?.y ?? selectedDisplayRegion?.y ?? 0
    }

    var isUsingStreamViewport: Bool {
        guard let selectedDisplayRegion, let streamRegion else { return false }
        return selectedDisplayRegion.x != streamRegion.x ||
            selectedDisplayRegion.y != streamRegion.y ||
            selectedDisplayRegion.width != streamRegion.width ||
            selectedDisplayRegion.height != streamRegion.height
    }

    var streamViewportSummary: String? {
        guard isUsingStreamViewport, let streamRegion else { return nil }
        return "\(streamRegion.width)x\(streamRegion.height) at \(streamRegion.x),\(streamRegion.y)"
    }

    var savedConnectionHost: String {
        credentialHost
    }

    var savedConnectionPort: UInt16 {
        credentialPort
    }

    var savedConnectionProtocol: RemoteConnectionProtocol {
        profile == .macScreenSharing ? .macScreenSharing : .vnc
    }

    var controlPreferenceScope: ViewerControlPreferenceScope {
        ViewerControlPreferenceScope(
            connectionProtocol: savedConnectionProtocol,
            host: savedConnectionHost,
            port: savedConnectionPort
        )
    }

    func updateStreamQuality(_ quality: Double, profile: StreamProfile? = nil) async {
        let preference = StreamQualityPreference(quality: quality)
        let nextProfile = profile ?? preference.nativeProfile
        guard preference != streamQualityPreference || nextProfile != streamProfile else { return }
        streamQualityPreference = preference
        streamProfile = nextProfile
        lastImagePublish = .distantPast
        guard case .connected = phase,
              let bounds = selectedDisplayRegion,
              let current = streamRegion else {
            return
        }
        let targetPixels = preference.vncMaxStreamPixels(
            isFullDesktop: bounds.isFullDesktop,
            isIOS: Self.isRunningOnIOS
        )
        await setStreamRegion(boundedStreamRegion(
            in: bounds,
            centerX: current.x + current.width / 2,
            centerY: current.y + current.height / 2,
            targetPixels: targetPixels
        ))
    }

    func updateViewportCanvasSize(_ size: CGSize) async {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = max(0.2, min(6.0, size.width / size.height))
        guard abs(aspect - viewportAspect) > 0.05 else { return }
        viewportAspect = aspect
        guard case .connected = phase, let bounds = selectedDisplayRegion, let current = streamRegion else { return }
        let centerX = current.x + current.width / 2
        let centerY = current.y + current.height / 2
        await setStreamRegion(boundedStreamRegion(
            in: bounds,
            centerX: centerX,
            centerY: centerY,
            targetPixels: isUsingStreamViewport ? current.pixelCount : nil
        ))
    }

    func selectDisplayRegion(_ region: VNCDisplayRegion) async {
        guard case .connected = phase else { return }
        guard selectedDisplayRegion != region else { return }
        selectedDisplayRegion = region
        guard let stream = initialStreamRegion(in: region) else { return }
        await setStreamRegion(stream)
    }

    func resetStreamViewport() async {
        guard case .connected = phase else { return }
        guard let stream = initialStreamRegion(in: selectedDisplayRegion) else { return }
        await setStreamRegion(stream)
    }

    func handleMemoryPressure() async {
        #if os(iOS)
        guard case .connected = phase,
              let bounds = selectedDisplayRegion,
              let current = streamRegion else {
            return
        }
        let centerX = current.x + current.width / 2
        let centerY = current.y + current.height / 2
        await setStreamRegion(boundedStreamRegion(
            in: bounds,
            centerX: centerX,
            centerY: centerY,
            targetPixels: emergencyStreamPixels
        ))
        #endif
    }

    func zoomStreamViewport(magnification: CGFloat, anchorViewX: Int, anchorViewY: Int) async {
        guard case .connected = phase,
              let bounds = selectedDisplayRegion,
              let current = streamRegion,
              magnification.isFinite,
              magnification > 0 else {
            return
        }

        let clampedMagnification = max(0.5, min(2.0, magnification))
        let minWidth = min(bounds.width, 640)
        let minHeight = min(bounds.height, 360)
        var nextWidth = Int((CGFloat(current.width) / clampedMagnification).rounded())
        var nextHeight = Int((CGFloat(current.height) / clampedMagnification).rounded())
        nextWidth = max(minWidth, min(bounds.width, nextWidth))
        nextHeight = max(minHeight, min(bounds.height, nextHeight))

        let anchorRemoteX = current.x + max(0, min(current.width, anchorViewX))
        let anchorRemoteY = current.y + max(0, min(current.height, anchorViewY))
        let anchorRatioX = CGFloat(max(0, min(current.width, anchorViewX))) / CGFloat(max(1, current.width))
        let anchorRatioY = CGFloat(max(0, min(current.height, anchorViewY))) / CGFloat(max(1, current.height))
        let nextX = anchorRemoteX - Int((CGFloat(nextWidth) * anchorRatioX).rounded())
        let nextY = anchorRemoteY - Int((CGFloat(nextHeight) * anchorRatioY).rounded())
        await setStreamRegion(clampedStreamRegion(
            in: bounds,
            x: nextX,
            y: nextY,
            width: nextWidth,
            height: nextHeight
        ))
    }

    func panStreamViewport(deltaViewX: Int, deltaViewY: Int) async {
        guard case .connected = phase,
              let bounds = selectedDisplayRegion,
              let current = streamRegion,
              isUsingStreamViewport else {
            return
        }
        await setStreamRegion(clampedStreamRegion(
            in: bounds,
            x: current.x - deltaViewX,
            y: current.y - deltaViewY,
            width: current.width,
            height: current.height
        ))
    }

    private var shouldContinueConnecting: Bool {
        !isDisconnecting && !Task.isCancelled
    }

    private var credentialHost: String {
        host.isEmpty ? peerLabel : host
    }

    private var credentialPort: UInt16 {
        port
    }

    private var networkTrustScope: NetworkTrustScope {
        NetworkTrustScope.classify(host: credentialHost)
    }

    private var connectionTimeouts: RFBConnectionTimeouts {
        let scope = networkTrustScope
        let tcpTimeout: TimeInterval
        if endpoint != nil || scope.isTrustedPrivateScope {
            tcpTimeout = 3.0
        } else {
            tcpTimeout = 7.0
        }

        return RFBConnectionTimeouts(
            tcpConnect: tcpTimeout,
            versionHandshake: scope.isTrustedPrivateScope ? 6.0 : 8.0,
            securityNegotiation: profile == .macScreenSharing ? 12.0 : 8.0,
            serverInitialization: 8.0
        )
    }

    private var currentSecurityPreference: RFBSecurityPreference {
        if forceLegacyVNCPasswordAuth {
            return .vncPasswordOnly
        }
        return profile == .macScreenSharing ? .macAccountFirst : .vncPasswordFirst
    }

    private func resetFirstFrameTelemetry() {
        firstFrameTelemetry = VNCFirstFrameTelemetry(
            connectionStartedAt: Date(),
            reconnects: reconnectAttempt
        )
    }

    private func recordSecurityReport(_ report: RFBSecurityReport, authenticated: Bool) {
        var telemetry = firstFrameTelemetry
        if authenticated {
            telemetry.authenticatedAt = Date()
        }
        telemetry.offeredSecurityModes = report.offeredModes
        telemetry.negotiatedSecurityMode = report.mode
        telemetry.lastFailure = nil
        firstFrameTelemetry = telemetry
    }

    private func markServerConnectedForFirstFrame() {
        var telemetry = firstFrameTelemetry
        telemetry.connectedAt = Date()
        telemetry.lastFailure = nil
        firstFrameTelemetry = telemetry
    }

    private func markFirstFramebufferRequest(at date: Date, reason: String, incremental: Bool) {
        guard firstFrameTelemetry.firstFramebufferAt == nil else { return }

        var telemetry = firstFrameTelemetry
        if telemetry.firstFramebufferRequestAt == nil || !incremental {
            telemetry.firstFramebufferRequestAt = date
            telemetry.lastRequestReason = reason
        }
        if reason == "recovery", !incremental {
            telemetry.recoveryFullFrameRequests += 1
        }
        firstFrameTelemetry = telemetry
    }

    private func markFirstFramebufferReceived(rects: [RFBRect]) {
        guard firstFrameTelemetry.firstFramebufferAt == nil else { return }

        var telemetry = firstFrameTelemetry
        let now = Date()
        telemetry.firstFramebufferAt = now
        telemetry.lastFailure = nil
        firstFrameTelemetry = telemetry

        let duration = telemetry.firstFrameDuration.map(VNCFirstFrameTelemetry.formatSeconds) ?? "unknown"
        Logger.shared.info("VNC first framebuffer received in \(duration) with \(rects.count) rect(s)")
    }

    private func markFirstFrameFailure(_ reason: String) {
        var telemetry = firstFrameTelemetry
        telemetry.lastFailure = reason
        firstFrameTelemetry = telemetry
    }

    private func connectUsingPreferredRoute(
        username: String?,
        password: String?,
        securityPreference: RFBSecurityPreference,
        timeouts: RFBConnectionTimeouts
    ) async throws -> VNCConnectedRoute {
        let attempts = makeRouteAttempts()
        guard !attempts.isEmpty else {
            throw RFBError.connectionFailed("Missing VNC host")
        }

        if attempts.count == 1 {
            let attempt = attempts[0]
            self.connection = attempt.connection
            let outcome = await connectVNCConnectionRouteAttempt(
                attempt,
                username: username,
                password: password,
                securityPreference: securityPreference,
                timeouts: timeouts
            )
            switch outcome {
            case .connected(let route):
                return route
            case .failed(let failure):
                self.connection = failure.attempt.connection
                logRouteFailure(failure)
                removeCachedRouteIfUnusable(failure)
                throw failure.error
            }
        }

        return try await raceRouteAttempts(
            attempts,
            username: username,
            password: password,
            securityPreference: securityPreference,
            timeouts: timeouts
        )
    }

    private func raceRouteAttempts(
        _ attempts: [VNCConnectionRouteAttempt],
        username: String?,
        password: String?,
        securityPreference: RFBSecurityPreference,
        timeouts: RFBConnectionTimeouts
    ) async throws -> VNCConnectedRoute {
        var failures: [VNCRouteFailure] = []

        return try await withThrowingTaskGroup(of: VNCRouteAttemptOutcome.self, returning: VNCConnectedRoute.self) { group in
            for attempt in attempts {
                group.addTask {
                    await connectVNCConnectionRouteAttempt(
                        attempt,
                        username: username,
                        password: password,
                        securityPreference: securityPreference,
                        timeouts: timeouts
                    )
                }
            }

            while let outcome = try await group.next() {
                switch outcome {
                case .connected(let route):
                    self.connection = route.attempt.connection
                    for attempt in attempts where attempt.id != route.attempt.id {
                        await attempt.connection.disconnect()
                    }
                    group.cancelAll()
                    return route

                case .failed(let failure):
                    failures.append(failure)
                    logRouteFailure(failure)
                    removeCachedRouteIfUnusable(failure)
                    if !shouldContinueRouteSearch(after: failure, totalAttempts: attempts.count) {
                        self.connection = failure.attempt.connection
                        for attempt in attempts where attempt.id != failure.attempt.id {
                            await attempt.connection.disconnect()
                        }
                        group.cancelAll()
                        throw failure.error
                    }
                }
            }

            if let failure = prioritizedRouteFailure(failures, totalAttempts: attempts.count) {
                self.connection = failure.attempt.connection
                throw failure.error
            }
            throw RFBError.connectionFailed("No VNC route candidates were available")
        }
    }

    private func makeRouteAttempts() -> [VNCConnectionRouteAttempt] {
        if let endpoint {
            return [
                VNCConnectionRouteAttempt(
                    connection: RFBConnection(endpoint: endpoint),
                    logicalHost: credentialHost,
                    logicalPort: credentialPort,
                    routedHost: nil,
                    routedPort: nil,
                    routeLabel: .lan,
                    isCached: false
                )
            ]
        }

        let logicalHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !logicalHost.isEmpty else { return [] }

        var attempts: [VNCConnectionRouteAttempt] = []
        var seen: Set<String> = []
        func appendCandidate(host candidateHost: String, port candidatePort: UInt16, label: VNCRouteLabel?, isCached: Bool) {
            let normalized = "\(VNCLastGoodRouteKey.normalizedHost(candidateHost)):\(candidatePort)"
            guard !seen.contains(normalized) else { return }
            seen.insert(normalized)
            attempts.append(VNCConnectionRouteAttempt(
                connection: RFBConnection(host: candidateHost, port: candidatePort),
                logicalHost: logicalHost,
                logicalPort: port,
                routedHost: candidateHost,
                routedPort: candidatePort,
                routeLabel: label,
                isCached: isCached
            ))
        }

        if let cached = VNCLastGoodRouteStore.shared.preferredCandidate(
            forHost: logicalHost,
            port: port,
            profile: profile
        ) {
            appendCandidate(host: cached.host, port: cached.port, label: cached.label, isCached: true)
        }

        appendCandidate(
            host: logicalHost,
            port: port,
            label: VNCRouteLabel.classify(host: logicalHost),
            isCached: false
        )

        return attempts
    }

    private func shouldContinueRouteSearch(after failure: VNCRouteFailure, totalAttempts: Int) -> Bool {
        if failure.error is CancellationError { return true }
        guard let rfbError = failure.error as? RFBError else { return true }
        switch rfbError {
        case .connectionFailed, .timeout, .disconnected:
            return true
        case .protocolError, .unsupportedSecurity, .unsupportedEncoding:
            return failure.attempt.isCached && totalAttempts > 1
        case .authFailed, .authRequired, .credentialsRequired:
            return false
        }
    }

    private func prioritizedRouteFailure(_ failures: [VNCRouteFailure], totalAttempts: Int) -> VNCRouteFailure? {
        failures.first { !($0.error is CancellationError) && !shouldContinueRouteSearch(after: $0, totalAttempts: totalAttempts) } ??
            failures.first { !($0.error is CancellationError) } ??
            failures.first
    }

    private func logRouteFailure(_ failure: VNCRouteFailure) {
        let routedHost = failure.attempt.routedHost ?? failure.attempt.logicalHost
        let routedPort = failure.attempt.routedPort ?? failure.attempt.logicalPort
        let cacheLabel = failure.attempt.isCached ? " cached" : ""
        Logger.shared.warn("VNC\(cacheLabel) route \(routedHost):\(routedPort) failed: \(failure.error.localizedDescription)")
    }

    private func removeCachedRouteIfUnusable(_ failure: VNCRouteFailure) {
        guard failure.attempt.isCached, shouldEvictCachedRoute(after: failure.error) else { return }
        VNCLastGoodRouteStore.shared.remove(
            host: failure.attempt.logicalHost,
            port: failure.attempt.logicalPort,
            profile: profile
        )
    }

    private func shouldEvictCachedRoute(after error: Error) -> Bool {
        guard let rfbError = error as? RFBError else { return false }
        switch rfbError {
        case .connectionFailed, .timeout, .disconnected, .protocolError, .unsupportedSecurity, .unsupportedEncoding:
            return true
        case .authFailed, .authRequired, .credentialsRequired:
            return false
        }
    }

    private func recordSuccessfulRoute(_ attempt: VNCConnectionRouteAttempt) {
        guard endpoint == nil, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        VNCLastGoodRouteStore.shared.recordSuccess(
            logicalHost: attempt.logicalHost,
            logicalPort: attempt.logicalPort,
            profile: profile,
            routedHost: attempt.routedHost ?? attempt.logicalHost,
            routedPort: attempt.routedPort ?? attempt.logicalPort,
            label: attempt.routeLabel
        )
        if attempt.isCached {
            Logger.shared.info("VNC connected using cached \(attempt.routeLabel?.displayName ?? "last-good") route \(attempt.routedHost ?? attempt.logicalHost):\(attempt.routedPort ?? attempt.logicalPort)")
        }
    }

    private func currentSecurityReport() async -> RFBSecurityReport {
        guard let connection else {
            return RFBSecurityReport(mode: .unknown, offeredModes: [])
        }
        return await connection.securityReport()
    }

    private func disconnectCurrentConnection() async {
        await connection?.disconnect()
        connection = nil
    }

    private func failConnection(with error: Error) async {
        await disconnectCurrentConnection()
        markFirstFrameFailure(error.localizedDescription)
        securityStatus = RemoteSecurityStatus(
            level: .unknown,
            title: profile == .macScreenSharing ? "Mac Screen Sharing failed" : "VNC connection failed",
            detail: error.localizedDescription,
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: networkTrustScope.publicNetworkWarning,
            protocolName: profile.displayName,
            credentialStorage: "Keychain"
        )
        phase = .failed(reason: error.localizedDescription)
        Logger.shared.error("VNC connect failed: \(error.localizedDescription)")
    }

    private func failUnsupportedSecurity(_ type: UInt8) async {
        let report = await currentSecurityReport()
        recordSecurityReport(report, authenticated: false)
        await disconnectCurrentConnection()

        let mode = RFBSecurityMode(type: type)
        guard mode.isModernAppleAccountAuth || report.requiresUnsupportedModernAppleAuth else {
            await failConnection(with: RFBError.unsupportedSecurity(type))
            return
        }

        let offered = report.offeredModesDescription.map { " Server offered: \($0)." } ?? ""
        let detail = "This Mac selected \(mode.displayName), Apple's newer private Screen Sharing account-auth path. Screen Q supports Apple DH (30) and standard VNC password auth on port 5900, but does not yet send credentials through Apple's private 35/36 wire format.\(offered)"
        markFirstFrameFailure(detail)
        securityStatus = RemoteSecurityStatus(
            level: .unknown,
            title: "Modern Apple Screen Sharing auth required",
            detail: detail,
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: "Use Screen Q Native for this Mac, or enable legacy VNC viewers with a separate VNC password in macOS Screen Sharing settings for the port 5900 path.",
            protocolName: profile.displayName,
            authMethod: mode.displayName,
            credentialStorage: "Keychain",
            identityVerification: "Apple private Screen Sharing authentication",
            warnings: ["Screen Q did not send saved credentials through unsupported Apple 35/36 authentication."]
        )
        phase = .failed(reason: detail)
        Logger.shared.error("VNC unsupported Apple Screen Sharing auth \(type).\(offered)")
    }

    private func promptForLegacyVNCPasswordIfAvailable(afterTimeoutAt stage: String, report: RFBSecurityReport) -> Bool {
        guard profile == .macScreenSharing,
              !forceLegacyVNCPasswordAuth,
              report.mode == .appleDH,
              report.offeredModes.contains(.vncAuth) else {
            return false
        }

        forceLegacyVNCPasswordAuth = true
        needsCredentials = false
        needsPassword = true
        vncPassword = ""
        securityStatus = RemoteSecurityStatus(
            level: networkTrustScope.isTrustedPrivateScope ? .networkProtected : .legacyAuth,
            title: "Legacy VNC password available",
            detail: "The Mac advertised Apple Screen Sharing account authentication, but did not finish \(stage). Enter the separate VNC password configured for legacy VNC viewers.",
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: networkTrustScope.publicNetworkWarning ?? "Only use this over a private LAN, VPN, or Tailscale.",
            protocolName: profile.displayName,
            authMethod: "Legacy VNC password",
            credentialStorage: "Keychain",
            identityVerification: "VNC password only",
            warnings: ["This fallback is not your Mac admin/user login, and RFB traffic is not encrypted by Screen Q."]
        )
        phase = .authenticating
        Logger.shared.warn("Mac Screen Sharing Apple DH timed out during \(stage); prompting for legacy VNC password fallback")
        return true
    }

    private func prepareCredentialPreflightForDial() -> Bool {
        loadStoredCredentialIfNeeded()
        guard shouldContinueConnecting else { return false }
        if profile == .macScreenSharing, forceLegacyVNCPasswordAuth, vncPassword.isEmpty {
            needsCredentials = false
            needsPassword = true
            securityStatus = RemoteSecurityStatus(
                level: networkTrustScope.isTrustedPrivateScope ? .networkProtected : .legacyAuth,
                title: "Legacy VNC password required",
                detail: "Enter the separate VNC password configured in Screen Sharing settings for \(credentialHost). This is not the Mac account password.",
                isTransportEncrypted: false,
                isAuthenticated: false,
                recommendedAction: networkTrustScope.publicNetworkWarning,
                protocolName: profile.displayName,
                authMethod: "Legacy VNC password",
                credentialStorage: "Keychain",
                identityVerification: "VNC password only"
            )
            phase = .authenticating
            return false
        }
        guard profile == .macScreenSharing,
              username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              vncPassword.isEmpty else {
            return true
        }

        needsPassword = false
        needsCredentials = true
        securityStatus = RemoteSecurityStatus(
            level: networkTrustScope.isTrustedPrivateScope ? .networkProtected : .unknown,
            title: "Mac account credentials required",
            detail: "Enter the macOS username and password for \(credentialHost) before Screen Q opens the Screen Sharing connection. \(networkTrustScope.connectionHint)",
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: networkTrustScope.publicNetworkWarning,
            protocolName: profile.displayName,
            authMethod: "Apple Screen Sharing account credentials",
            credentialStorage: "Keychain",
            identityVerification: "macOS sharing permissions"
        )
        phase = .authenticating
        return false
    }

    private func loadStoredCredentialIfNeeded() {
        guard vncPassword.isEmpty || username.isEmpty else { return }
        guard let stored = VNCKeychainCredentialStore.load(
            host: credentialHost,
            port: credentialPort,
            operationPrompt: CredentialKeychainAccess.operationPrompt(protocolName: profile.displayName, host: credentialHost)
        ) else { return }
        if forceLegacyVNCPasswordAuth {
            guard stored.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if vncPassword.isEmpty {
                vncPassword = stored.password
            }
            return
        }
        if username.isEmpty {
            username = stored.username
        }
        if vncPassword.isEmpty {
            vncPassword = stored.password
        }
    }

    private func saveCredentialIfAllowed() {
        guard rememberCredentials, !vncPassword.isEmpty else { return }
        VNCKeychainCredentialStore.save(
            VNCStoredCredential(username: forceLegacyVNCPasswordAuth ? "" : username, password: vncPassword),
            host: credentialHost,
            port: credentialPort,
            requireLocalAuthentication: requireLocalAuthenticationForSavedCredentials
        )
    }

    // MARK: - Input forwarding

    private func configureInputMapper() {
        inputMapper.isControlEnabled = true
        inputMapper.keepsPredictedPointerVisible = true
        inputMapper.sendEvent = { [weak self] event in
            self?.sendInputEvent(event)
        }
    }

    private func sendInputEvent(_ event: RemoteInputEvent) {
        guard case .connected = phase else { return }
        switch event {
        case .pointerMove(let point, _):
            sendNormalisedPointer(point, buttons: 0)
        case .pointerDown(let point, let button, _):
            sendNormalisedPointer(point, buttons: buttonMask(for: button))
        case .pointerUp(let point, _, _):
            sendNormalisedPointer(point, buttons: 0)
        case .scroll(let deltaX, let deltaY, let point, _):
            sendNormalisedScroll(deltaX: deltaX, deltaY: deltaY, at: point)
        case .keyDown(let key, let modifiers):
            sendMappedKey(key, modifiers: modifiers, isDown: true)
        case .keyUp(let key, let modifiers):
            sendMappedKey(key, modifiers: modifiers, isDown: false)
        case .textInput(let text):
            for scalar in text.unicodeScalars {
                sendKeyTap(code: scalar.value)
            }
        }
    }

    private func sendNormalisedPointer(_ point: NormalisedPoint, buttons: UInt8) {
        let mapped = remotePoint(normalised: point)
        updateCursorPosition(viewX: mapped.viewX, viewY: mapped.viewY)
        Task {
            try? await connection?.sendPointerEvent(
                buttons: buttons,
                x: UInt16(clamping: mapped.remoteX),
                y: UInt16(clamping: mapped.remoteY)
            )
        }
    }

    private func sendNormalisedScroll(deltaX: Double, deltaY: Double, at point: NormalisedPoint) {
        let dominantDelta = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
        guard dominantDelta.isFinite, abs(dominantDelta) > 0.5 else { return }
        let mapped = remotePoint(normalised: point)
        updateCursorPosition(viewX: mapped.viewX, viewY: mapped.viewY)

        let steps = max(1, min(8, Int((abs(dominantDelta) / 24.0).rounded(.up))))
        let button: UInt8 = dominantDelta < 0 ? (1 << 3) : (1 << 4)
        Task {
            for _ in 0..<steps {
                try? await connection?.sendPointerEvent(buttons: button, x: UInt16(clamping: mapped.remoteX), y: UInt16(clamping: mapped.remoteY))
                try? await connection?.sendPointerEvent(buttons: 0, x: UInt16(clamping: mapped.remoteX), y: UInt16(clamping: mapped.remoteY))
            }
        }
    }

    private func sendMappedKey(_ key: KeyCode, modifiers: KeyModifiers, isDown: Bool) {
        let modifierKeysyms = vncModifierKeysyms(for: modifiers)
        if isDown {
            for modifier in modifierKeysyms {
                sendKey(code: modifier, isDown: true)
            }
        }
        if let code = vncKeysym(for: key) {
            sendKey(code: code, isDown: isDown)
        }
        if !isDown {
            for modifier in modifierKeysyms.reversed() {
                sendKey(code: modifier, isDown: false)
            }
        }
    }

    private func buttonMask(for button: PointerButton) -> UInt8 {
        switch button {
        case .left: return 1 << 0
        case .middle: return 1 << 1
        case .right: return 1 << 2
        }
    }

    func sendMouseMove(x: Int, y: Int, buttons: UInt8 = 0) {
        guard case .connected = phase else { return }
        let point = remotePoint(viewX: x, viewY: y)
        updateCursorPosition(viewX: x, viewY: y)
        Task {
            try? await connection?.sendPointerEvent(
                buttons: buttons,
                x: UInt16(clamping: point.x),
                y: UInt16(clamping: point.y)
            )
        }
    }

    func sendMouseClick(x: Int, y: Int, button: Int, isDown: Bool) {
        guard case .connected = phase else { return }
        let mask: UInt8 = UInt8(1 << button)
        let point = remotePoint(viewX: x, viewY: y)
        updateCursorPosition(viewX: x, viewY: y)
        Task {
            try? await connection?.sendPointerEvent(
                buttons: isDown ? mask : 0,
                x: UInt16(clamping: point.x),
                y: UInt16(clamping: point.y)
            )
        }
    }

    private func updateCursorPosition(viewX: Int, viewY: Int) {
        cursorViewX = viewX
        cursorViewY = viewY
        cursorVisible = true
        cursorHideTimer?.invalidate()
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cursorVisible = false
            }
        }
    }

    func sendScroll(x: Int, y: Int, deltaY: Int) {
        guard case .connected = phase else { return }
        // RFB scroll: button 4 = scroll up, button 5 = scroll down
        let button: UInt8 = deltaY < 0 ? (1 << 3) : (1 << 4) // button 4 or 5
        let point = remotePoint(viewX: x, viewY: y)
        Task {
            try? await connection?.sendPointerEvent(buttons: button, x: UInt16(clamping: point.x), y: UInt16(clamping: point.y))
            try? await connection?.sendPointerEvent(buttons: 0, x: UInt16(clamping: point.x), y: UInt16(clamping: point.y))
        }
    }

    func sendKey(code: UInt32, isDown: Bool) {
        guard case .connected = phase else { return }
        Task {
            guard let conn = connection else { return }
            // Always send legacy KeyEvent for compatibility.
            try? await conn.sendKeyEvent(down: isDown, key: code)
            // If the server supports QEMU extended events and we know the
            // XT scan code, also send that so games and modifier-sensitive
            // applications get hardware-accurate keystrokes.
            if await conn.serverSupportsQemuExtendedKey,
               let xt = XTScanCodeMap.scanCode(forKeysym: code) {
                try? await conn.sendQemuExtendedKeyEvent(down: isDown, keysym: code, keycode: xt)
            }
        }
    }

    /// Ask the remote host to switch to a new framebuffer size.
    /// No-op if the server didn't advertise ExtendedDesktopSize support.
    @discardableResult
    func requestRemoteResize(width: Int, height: Int) -> Bool {
        guard case .connected = phase else { return false }
        let w = UInt16(clamping: max(320, min(width, 7680)))
        let h = UInt16(clamping: max(240, min(height, 4320)))
        Task {
            guard let conn = connection else { return }
            guard await conn.serverSupportsExtendedDesktopSize else { return }
            try? await conn.sendSetDesktopSize(width: w, height: h)
        }
        return true
    }

    var canRequestRemoteResize: Bool {
        // Best-effort UI hint; actual support is verified async in requestRemoteResize.
        if case .connected = phase { return true }
        return false
    }

    /// Send the local pasteboard contents to the remote host as
    /// ClientCutText. On macOS, this is also called automatically when
    /// the local pasteboard changes while a session is connected.
    func sendClipboard(_ text: String) {
        guard case .connected = phase, !text.isEmpty else { return }
        // RFB ClientCutText is Latin-1; fall back gracefully for unicode.
        Task {
            try? await connection?.sendClientCutText(text)
        }
    }

    func sendLocalPasteboardIfAvailable() {
        #if os(macOS)
        if let text = NSPasteboard.general.string(forType: .string) {
            sendClipboard(text)
        }
        #else
        if let text = UIPasteboard.general.string {
            sendClipboard(text)
        }
        #endif
    }

    private func startClipboardSync() {
        stopClipboardSync()
        #if os(macOS)
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboardForChange()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardSyncTimer = timer
        #endif
    }

    private func stopClipboardSync() {
        clipboardSyncTimer?.invalidate()
        clipboardSyncTimer = nil
    }

    #if os(macOS)
    private func checkPasteboardForChange() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pb.changeCount
        if let text = pb.string(forType: .string), !text.isEmpty {
            sendClipboard(text)
        }
    }
    #endif

    func sendKeyTap(code: UInt32) {
        guard case .connected = phase else { return }
        Task {
            try? await connection?.sendKeyEvent(down: true, key: code)
            try? await connection?.sendKeyEvent(down: false, key: code)
        }
    }

    func sendKeyCombo(code: UInt32, modifiers: [UInt32]) {
        guard case .connected = phase else { return }
        Task {
            for modifier in modifiers {
                try? await connection?.sendKeyEvent(down: true, key: modifier)
            }
            try? await connection?.sendKeyEvent(down: true, key: code)
            try? await connection?.sendKeyEvent(down: false, key: code)
            for modifier in modifiers.reversed() {
                try? await connection?.sendKeyEvent(down: false, key: modifier)
            }
        }
    }

    // MARK: - Private: Message loop

    private func startMessageLoop(_ conn: RFBConnection) {
        messageTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let msg = try await conn.readServerMessage() else { break }
                    self?.handleServerMessage(msg)
                }
            } catch {
                await MainActor.run {
                    if case .connected = self?.phase {
                        self?.scheduleReconnect(reason: error.localizedDescription)
                    }
                }
                return
            }
            await MainActor.run {
                if case .connected = self?.phase {
                    self?.scheduleReconnect(reason: "Server disconnected")
                }
            }
        }
    }

    private func scheduleReconnect(reason: String) {
        guard !isDisconnecting else {
            phase = .ended(reason: reason)
            return
        }
        reconnectAttempt += 1
        guard reconnectAttempt <= maxReconnectAttempts else {
            markFirstFrameFailure("\(reason) (reconnect failed after \(maxReconnectAttempts) attempts)")
            phase = .failed(reason: "\(reason) (reconnect failed after \(maxReconnectAttempts) attempts)")
            return
        }
        var telemetry = firstFrameTelemetry
        telemetry.reconnects = reconnectAttempt
        telemetry.lastFailure = reason
        firstFrameTelemetry = telemetry
        phase = .reconnecting(attempt: reconnectAttempt)
        Logger.shared.info("VNC reconnecting (attempt \(reconnectAttempt)/\(maxReconnectAttempts)): \(reason)")

        stopClipboardSync()
        messageTask?.cancel()
        messageTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        streamRegionRequestTask?.cancel()
        streamRegionRequestTask = nil
        connection = nil
        frameBuffer = nil
        currentImage = nil
        framebufferWaitStartedAt = .distantPast
        lastFramebufferUpdateAt = .distantPast
        lastFramebufferRequestAt = .distantPast
        lastFullFramebufferRequestAt = .distantPast
        renderRevision &+= 1

        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 16.0) // 1, 2, 4, 8, 16s
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startConnecting()
        }
    }

    private func handleServerMessage(_ msg: RFBConnection.ServerMessage) {
        switch msg {
        case .framebufferUpdate(let rects):
            guard !rects.isEmpty else { return }
            let wasWaitingForFirstFramebuffer = firstFrameTelemetry.firstFramebufferAt == nil
            lastFramebufferUpdateAt = Date()
            frameBuffer?.apply(rects)
            recordFrameStats(rects: rects)
            if isViewportRefreshPending {
                isViewportRefreshPending = false
                lastImagePublish = .distantPast
            }
            publishCurrentImageIfNeeded()
            if currentImage != nil || useMetalRendering {
                framebufferWaitStartedAt = .distantPast
                if wasWaitingForFirstFramebuffer {
                    markFirstFramebufferReceived(rects: rects)
                }
            }
            // Check for piggy-backed cursor update.
            Task {
                if let cursor = await connection?.consumePendingCursorShape() {
                    applyCursorShape(cursor)
                }
            }
        case .cursorShape(let cursor):
            applyCursorShape(cursor)
        case .desktopResize(let w, let h):
            streamRegionRequestTask?.cancel()
            streamRegionRequestTask = nil
            isViewportRefreshPending = false
            serverWidth = Int(w)
            serverHeight = Int(h)
            displayRegions = VNCDisplayRegion.options(serverWidth: serverWidth, serverHeight: serverHeight)
            selectedDisplayRegion = displayRegions.first
            streamRegion = initialStreamRegion(in: selectedDisplayRegion)
            frameBuffer = makeFrameBuffer(for: streamRegion)
            isViewportRefreshPending = true
            if let renderer = metalRenderer, let frameBuffer {
                renderer.ensureTextureSize(width: frameBuffer.width, height: frameBuffer.height)
            }
            currentImage = nil
            framebufferWaitStartedAt = Date()
            lastImagePublish = .distantPast
            renderRevision &+= 1
            if let streamRegion {
                scheduleFullStreamRegionRefresh(streamRegion)
            }
        case .bell:
            #if os(macOS)
            NSSound.beep()
            #endif
        case .serverCutText(let text):
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        }
    }

    private func recordFrameStats(rects: [RFBRect]) {
        fpsAccumulator += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            measuredFPS = Double(fpsAccumulator) / elapsed
            fpsAccumulator = 0
            fpsWindowStart = now
        }
    }

    private func applyCursorShape(_ cursor: RFBConnection.CursorShape) {
        let w = Int(cursor.width)
        let h = Int(cursor.height)
        guard w > 0, h > 0, cursor.pixels.count == w * h * 4 else {
            cursorImage = nil
            return
        }
        cursorHotspot = CGPoint(x: CGFloat(cursor.hotspotX), y: CGFloat(cursor.hotspotY))

        let maskRowBytes = (w + 7) / 8
        var rgba = [UInt8](cursor.pixels)

        // Apply 1-bit mask as alpha. Server sends BGRA pixels + 1-bit MSB mask.
        if cursor.mask.count == maskRowBytes * h {
            let maskBytes = Array(cursor.mask)
            for y in 0..<h {
                for x in 0..<w {
                    let maskBit = (maskBytes[y * maskRowBytes + x / 8] >> (7 - (x % 8))) & 1
                    let pixelIndex = (y * w + x) * 4
                    if maskBit == 0 {
                        rgba[pixelIndex] = 0     // B
                        rgba[pixelIndex + 1] = 0 // G
                        rgba[pixelIndex + 2] = 0 // R
                        rgba[pixelIndex + 3] = 0 // A
                    } else {
                        rgba[pixelIndex + 3] = 255 // fully opaque
                    }
                }
            }
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else {
            cursorImage = nil
            return
        }
        cursorImage = CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - Private: Refresh loop (request framebuffer updates)

    private func startRefreshLoop(_ conn: RFBConnection) {
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.sendFramebufferUpdateRequest(conn, incremental: false, reason: "initial")

            while !Task.isCancelled {
                guard case .connected = self.phase else { break }
                try? await Task.sleep(nanoseconds: self.frameRequestIntervalNanoseconds)
                guard case .connected = self.phase else { break }
                if self.shouldReconnectAfterMissingFirstFramebuffer() {
                    self.scheduleReconnect(reason: "Timed out waiting for the first VNC framebuffer")
                    break
                }
                guard !self.isViewportRefreshPending else { continue }
                let now = Date()
                let forceFull = self.shouldRequestRecoveryFullFrame(now: now)
                await self.sendFramebufferUpdateRequest(
                    conn,
                    incremental: !forceFull,
                    reason: forceFull ? "recovery" : "incremental"
                )
            }
        }
    }

    @discardableResult
    private func sendFramebufferUpdateRequest(
        _ conn: RFBConnection,
        incremental: Bool,
        region: VNCDisplayRegion? = nil,
        reason: String
    ) async -> Bool {
        guard case .connected = phase, !isDisconnecting else { return false }
        let requestRegion = region ?? streamRegion ?? selectedDisplayRegion
        let x = requestRegion?.x ?? viewportOriginX
        let y = requestRegion?.y ?? viewportOriginY
        let width = requestRegion?.width ?? viewWidth
        let height = requestRegion?.height ?? viewHeight
        guard width > 0, height > 0 else { return false }

        let now = Date()
        lastFramebufferRequestAt = now
        if !incremental {
            lastFullFramebufferRequestAt = now
        }
        if firstFrameTelemetry.firstFramebufferAt == nil, (!incremental || firstFrameTelemetry.firstFramebufferRequestAt == nil) {
            markFirstFramebufferRequest(at: now, reason: reason, incremental: incremental)
        }

        do {
            try await conn.sendFramebufferUpdateRequest(
                incremental: incremental,
                x: UInt16(clamping: x),
                y: UInt16(clamping: y),
                w: UInt16(clamping: width),
                h: UInt16(clamping: height)
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard case .connected = phase, !isDisconnecting else { return false }
            Logger.shared.warn("VNC \(reason) framebuffer request failed: \(error.localizedDescription)")
            scheduleReconnect(reason: "VNC framebuffer request failed: \(error.localizedDescription)")
            return false
        }
    }

    private func shouldRequestRecoveryFullFrame(now: Date) -> Bool {
        if currentImage == nil {
            return now.timeIntervalSince(lastFullFramebufferRequestAt) >= emptyFramebufferRetryInterval
        }
        if lastFramebufferUpdateAt == .distantPast {
            return now.timeIntervalSince(lastFullFramebufferRequestAt) >= steadyStateFullRefreshInterval
        }
        return now.timeIntervalSince(lastFramebufferUpdateAt) >= steadyStateFullRefreshInterval &&
            now.timeIntervalSince(lastFullFramebufferRequestAt) >= steadyStateFullRefreshInterval
    }

    private func shouldReconnectAfterMissingFirstFramebuffer() -> Bool {
        guard currentImage == nil, framebufferWaitStartedAt != .distantPast else { return false }
        return Date().timeIntervalSince(framebufferWaitStartedAt) >= firstFramebufferTimeout
    }

    private func setStreamRegion(_ region: VNCDisplayRegion) async {
        guard region.width > 0, region.height > 0 else { return }
        guard streamRegion != region else { return }
        streamRegion = region
        isViewportRefreshPending = true
        if let frameBuffer {
            frameBuffer.resize(width: region.width, height: region.height, originX: region.x, originY: region.y)
        } else {
            frameBuffer = makeFrameBuffer(for: region)
        }
        if let renderer = metalRenderer, let frameBuffer {
            renderer.ensureTextureSize(width: frameBuffer.width, height: frameBuffer.height)
        }
        currentImage = nil
        framebufferWaitStartedAt = Date()
        lastImagePublish = .distantPast
        renderRevision &+= 1
        scheduleFullStreamRegionRefresh(region)
    }

    private func scheduleFullStreamRegionRefresh(_ region: VNCDisplayRegion) {
        streamRegionRequestTask?.cancel()
        let elapsed = Date().timeIntervalSince(lastStreamRegionRequest)
        let delay = max(0, minimumStreamRegionRequestInterval - elapsed)
        streamRegionRequestTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.requestFullStreamRegionRefresh(region)
        }
    }

    private func requestFullStreamRegionRefresh(_ region: VNCDisplayRegion) async {
        guard case .connected = phase,
              !isDisconnecting,
              streamRegion == region else {
            return
        }
        lastStreamRegionRequest = Date()
        guard let connection else { return }
        await sendFramebufferUpdateRequest(connection, incremental: false, region: region, reason: "viewport")
    }

    private func initialStreamRegion(in bounds: VNCDisplayRegion?) -> VNCDisplayRegion? {
        guard let bounds else { return nil }
        #if os(iOS)
        if isLikelyLargeCombinedDesktop(bounds) {
            return boundedStreamRegion(
                in: bounds,
                centerX: bounds.x + bounds.width / 2,
                centerY: bounds.y + bounds.height / 2,
                targetPixels: defaultStreamPixels(for: bounds)
            )
        }
        #endif
        if canStreamFullRegionByDefault(bounds) {
            return bounds
        }
        return boundedStreamRegion(
            in: bounds,
            centerX: bounds.x + bounds.width / 2,
            centerY: bounds.y + bounds.height / 2,
            targetPixels: defaultStreamPixels(for: bounds)
        )
    }

    private func boundedStreamRegion(
        in bounds: VNCDisplayRegion,
        centerX: Int,
        centerY: Int,
        targetPixels: Int? = nil
    ) -> VNCDisplayRegion {
        #if os(iOS)
        let pixelBudget = min(maxStreamPixels(for: bounds), max(1, targetPixels ?? defaultStreamPixels(for: bounds)))
        guard bounds.pixelCount > pixelBudget else { return bounds }

        let targetAspect = preferredStreamAspect(for: bounds)
        let maxArea = CGFloat(pixelBudget)
        var width = Int((sqrt(maxArea * targetAspect)).rounded(.down))
        var height = Int((CGFloat(width) / targetAspect).rounded(.down))
        if width > bounds.width {
            width = bounds.width
            height = Int((CGFloat(width) / targetAspect).rounded(.down))
        }
        if height > bounds.height {
            height = bounds.height
            width = Int((CGFloat(height) * targetAspect).rounded(.down))
        }
        width = max(1, min(bounds.width, width))
        height = max(1, min(bounds.height, height))
        return clampedStreamRegion(
            in: bounds,
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
        #else
        return bounds
        #endif
    }

    private func canStreamFullRegionByDefault(_ bounds: VNCDisplayRegion) -> Bool {
        #if os(iOS)
        if isLikelyLargeCombinedDesktop(bounds) { return false }
        return bounds.pixelCount <= defaultFullStreamPixelLimit
        #else
        return true
        #endif
    }

    private func isLikelyLargeCombinedDesktop(_ bounds: VNCDisplayRegion) -> Bool {
        bounds.isFullDesktop && (
            bounds.width >= 3_000 ||
            bounds.height >= 2_200 ||
            CGFloat(bounds.width) / CGFloat(max(1, bounds.height)) >= 1.6
        )
    }

    private func clampedStreamRegion(in bounds: VNCDisplayRegion, x: Int, y: Int, width: Int, height: Int) -> VNCDisplayRegion {
        var nextWidth = max(1, min(bounds.width, width))
        var nextHeight = max(1, min(bounds.height, height))

        #if os(iOS)
        let maxPixels = maxStreamPixels(for: bounds)
        if nextWidth * nextHeight > maxPixels {
            let scale = sqrt(CGFloat(maxPixels) / CGFloat(nextWidth * nextHeight))
            nextWidth = max(1, min(bounds.width, Int((CGFloat(nextWidth) * scale).rounded(.down))))
            nextHeight = max(1, min(bounds.height, Int((CGFloat(nextHeight) * scale).rounded(.down))))
        }
        #endif

        let minX = bounds.x
        let minY = bounds.y
        let maxX = bounds.x + bounds.width - nextWidth
        let maxY = bounds.y + bounds.height - nextHeight
        let nextX = min(max(x, minX), max(minX, maxX))
        let nextY = min(max(y, minY), max(minY, maxY))
        if nextX == bounds.x, nextY == bounds.y, nextWidth == bounds.width, nextHeight == bounds.height {
            return bounds
        }
        return VNCDisplayRegion(
            id: "\(bounds.id)-viewport-\(nextX)-\(nextY)-\(nextWidth)-\(nextHeight)",
            name: "\(bounds.name) View",
            detail: "\(nextWidth)x\(nextHeight)",
            x: nextX,
            y: nextY,
            width: nextWidth,
            height: nextHeight
        )
    }

    private func makeFrameBuffer(for region: VNCDisplayRegion?) -> RFBFrameBuffer {
        RFBFrameBuffer(
            width: region?.width ?? serverWidth,
            height: region?.height ?? serverHeight,
            originX: region?.x ?? 0,
            originY: region?.y ?? 0
        )
    }

    private func remotePoint(viewX: Int, viewY: Int) -> (x: Int, y: Int) {
        let remoteX = viewportOriginX + viewX
        let remoteY = viewportOriginY + viewY
        return (
            max(0, min(serverWidth - 1, remoteX)),
            max(0, min(serverHeight - 1, remoteY))
        )
    }

    private func remotePoint(normalised point: NormalisedPoint) -> (remoteX: Int, remoteY: Int, viewX: Int, viewY: Int) {
        let base = streamRegion ?? selectedDisplayRegion ?? VNCDisplayRegion(
            id: "all",
            name: "All Displays",
            detail: "\(serverWidth)x\(serverHeight)",
            x: 0,
            y: 0,
            width: max(1, serverWidth),
            height: max(1, serverHeight)
        )
        let viewX = max(0, min(base.width - 1, Int((point.x * Double(max(1, base.width - 1))).rounded())))
        let viewY = max(0, min(base.height - 1, Int((point.y * Double(max(1, base.height - 1))).rounded())))
        let remoteX = max(0, min(serverWidth - 1, base.x + viewX))
        let remoteY = max(0, min(serverHeight - 1, base.y + viewY))
        return (remoteX, remoteY, viewX, viewY)
    }

    private func vncModifierKeysyms(for modifiers: KeyModifiers) -> [UInt32] {
        var result: [UInt32] = []
        if modifiers.contains(.shift) { result.append(0xFFE1) }
        if modifiers.contains(.control) { result.append(0xFFE3) }
        if modifiers.contains(.option) { result.append(0xFFE9) }
        if modifiers.contains(.command) { result.append(0xFFE7) }
        return result
    }

    private func vncKeysym(for key: KeyCode) -> UInt32? {
        switch key {
        case .returnKey: return 0xFF0D
        case .escape: return 0xFF1B
        case .tab: return 0xFF09
        case .backspace: return 0xFF08
        case .delete: return 0xFFFF
        case .arrowUp: return 0xFF52
        case .arrowDown: return 0xFF54
        case .arrowLeft: return 0xFF51
        case .arrowRight: return 0xFF53
        case .spacebar: return 0x0020
        case .home: return 0xFF50
        case .end: return 0xFF57
        case .pageUp: return 0xFF55
        case .pageDown: return 0xFF56
        case .a: return 0x0061
        case .c: return 0x0063
        case .d: return 0x0064
        case .f: return 0x0066
        case .h: return 0x0068
        case .l: return 0x006C
        case .m: return 0x006D
        case .q: return 0x0071
        case .v: return 0x0076
        case .w: return 0x0077
        case .x: return 0x0078
        case .z: return 0x007A
        case .f1: return 0xFFBE
        case .f2: return 0xFFBF
        case .f3: return 0xFFC0
        case .f4: return 0xFFC1
        case .f5: return 0xFFC2
        case .f6: return 0xFFC3
        case .f7: return 0xFFC4
        case .f8: return 0xFFC5
        case .f9: return 0xFFC6
        case .f10: return 0xFFC7
        case .f11: return 0xFFC8
        case .f12: return 0xFFC9
        case .capsLock:
            return 0xFFE5
        }
    }

    private func publishCurrentImageIfNeeded() {
        let now = Date()
        guard currentImage == nil || now.timeIntervalSince(lastImagePublish) >= imagePublishInterval else {
            return
        }
        lastImagePublish = now

        // Metal path: upload dirty pixels directly to GPU texture.
        if useMetalRendering, let renderer = metalRenderer, let fb = frameBuffer {
            let didUpload = fb.uploadToMetal(renderer)
            // Still publish a CGImage for thumbnails and fallback consumers.
            if currentImage == nil {
                currentImage = autoreleasepool {
                    fb.makeCGImage(maxDimension: renderMaxDimension)
                }
            }
            if didUpload {
                renderRevision &+= 1
            }
            return
        }

        // Legacy CGImage path.
        currentImage = autoreleasepool {
            frameBuffer?.makeCGImage(maxDimension: renderMaxDimension)
        }
    }

    /// Call once from the viewer to enable Metal-accelerated rendering.
    func enableMetalRendering() {
        guard metalRenderer == nil else { return }
        if let renderer = MetalFrameBufferRenderer() {
            metalRenderer = renderer
            useMetalRendering = true
            if let fb = frameBuffer {
                renderer.ensureTextureSize(width: fb.width, height: fb.height)
            }
        }
    }

    private var imagePublishInterval: TimeInterval {
        let targetFPS = streamProfile.mode == .custom ? streamProfile.targetFPS : streamQualityPreference.vncTargetFPS
        return 1.0 / Double(max(1, min(Self.isRunningOnIOS ? 30 : 60, targetFPS)))
    }

    private var renderMaxDimension: Int? {
        guard Self.isRunningOnIOS else { return nil }
        guard streamProfile.mode == .custom else {
            return streamQualityPreference.vncRenderMaxDimension(isIOS: Self.isRunningOnIOS)
        }
        switch streamProfile.scalePolicy {
        case .native:
            return Int(Double(max(serverWidth, serverHeight)) * 1.0)
        case .viewerMatched:
            return 2_560
        case .balancedDownscale:
            return 1_920
        case .bandwidthSaver:
            return 1_280
        }
    }

    private func preferredStreamAspect(for bounds: VNCDisplayRegion) -> CGFloat {
        #if os(iOS)
        if bounds.isFullDesktop, bounds.width > bounds.height {
            return max(0.2, min(6.0, CGFloat(bounds.width) / CGFloat(bounds.height)))
        }
        #endif
        return max(0.2, min(6.0, viewportAspect))
    }

    private func maxStreamPixels(for bounds: VNCDisplayRegion) -> Int {
        if canStreamFullRegionByDefault(bounds) {
            return defaultFullStreamPixelLimit
        }
        return streamQualityPreference.vncMaxStreamPixels(
            isFullDesktop: bounds.isFullDesktop,
            isIOS: Self.isRunningOnIOS
        )
    }

    private func defaultStreamPixels(for bounds: VNCDisplayRegion) -> Int {
        if canStreamFullRegionByDefault(bounds) {
            return bounds.pixelCount
        }
        return streamQualityPreference.vncDefaultStreamPixels(
            isFullDesktop: bounds.isFullDesktop,
            isIOS: Self.isRunningOnIOS
        )
    }

    private var defaultFullStreamPixelLimit: Int {
        streamQualityPreference.vncFullRegionPixelLimit(isIOS: Self.isRunningOnIOS)
    }

    private var emergencyStreamPixels: Int {
        #if os(iOS)
        return 360_000
        #else
        return Int.max / 4
        #endif
    }

    private var frameRequestIntervalNanoseconds: UInt64 {
        UInt64(max(0.01, imagePublishInterval) * 1_000_000_000)
    }

    private static var isRunningOnIOS: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}

extension VNCSession: RemoteSession {
    var remoteSessionDescriptor: RemoteSessionDescriptor {
        RemoteSessionDescriptor(
            id: remoteSessionID,
            kind: .vnc,
            label: peerLabel,
            host: host.isEmpty ? nil : host,
            port: port,
            platform: profile == .macScreenSharing ? .macOS : .unknown
        )
    }

    var remoteCapabilities: RemoteCapabilities {
        profile == .macScreenSharing ? .macScreenSharing : .vncCompatibility
    }
}
