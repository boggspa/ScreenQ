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
#endif

@MainActor
final class VNCSession: ObservableObject {

    enum Phase: Equatable {
        case connecting
        case authenticating
        case connected
        case failed(reason: String)
        case ended(reason: String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var currentImage: CGImage?
    @Published private(set) var serverName: String = ""
    @Published private(set) var serverWidth: Int = 0
    @Published private(set) var serverHeight: Int = 0
    @Published var vncPassword: String = ""
    @Published var username: String = ""
    @Published var needsPassword = false       // VNC Auth (type 2)
    @Published var needsCredentials = false     // Apple DH (type 30)
    @Published var rememberCredentials = true
    @Published var requireLocalAuthenticationForSavedCredentials = true
    @Published private(set) var securityStatus: RemoteSecurityStatus = .unknown

    let remoteSessionID = UUID()
    let peerLabel: String
    let profile: RFBConnectionProfile

    private var connection: RFBConnection?
    private var frameBuffer: RFBFrameBuffer?
    private var messageTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private let host: String
    private let port: UInt16
    private let endpoint: NWEndpoint?

    // MARK: - Init

    init(host: String, port: UInt16 = 5900, label: String, profile: RFBConnectionProfile = .genericVNC) {
        self.host = host
        self.port = port
        self.endpoint = nil
        self.peerLabel = label
        self.profile = profile
        self.securityStatus = .vncConnecting(scope: NetworkTrustScope.classify(host: host), profile: profile)
    }

    init(endpoint: NWEndpoint, label: String, profile: RFBConnectionProfile = .macScreenSharing) {
        self.host = ""
        self.port = 5900
        self.endpoint = endpoint
        self.peerLabel = label
        self.profile = profile
        self.securityStatus = .vncConnecting(scope: NetworkTrustScope.classify(host: label), profile: profile)
    }

    deinit {
        messageTask?.cancel()
        refreshTask?.cancel()
    }

    // MARK: - Connect

    func connect() async {
        phase = .connecting
        securityStatus = .vncConnecting(scope: networkTrustScope, profile: profile)
        loadStoredCredentialIfNeeded()

        let conn: RFBConnection
        if let endpoint = endpoint {
            conn = RFBConnection(endpoint: endpoint)
        } else {
            conn = RFBConnection(host: host, port: port)
        }
        self.connection = conn

        do {
            let serverInit = try await conn.connect(
                username: username.isEmpty ? nil : username,
                password: vncPassword.isEmpty ? nil : vncPassword,
                securityPreference: profile == .macScreenSharing ? .macAccountFirst : .vncPasswordFirst
            )
            serverName = serverInit.name
            serverWidth = Int(serverInit.width)
            serverHeight = Int(serverInit.height)
            frameBuffer = RFBFrameBuffer(width: serverWidth, height: serverHeight)
            securityStatus = .vnc(report: await conn.securityReport(), scope: networkTrustScope, profile: profile)
            phase = .connected
            Logger.shared.info("VNC connected to \(serverInit.name) (\(serverInit.width)×\(serverInit.height))")
            saveCredentialIfAllowed()
            startMessageLoop(conn)
            startRefreshLoop(conn)
        } catch RFBError.authRequired {
            securityStatus = .vnc(report: await conn.securityReport(), scope: networkTrustScope, profile: profile)
            needsPassword = true
            phase = .authenticating
            await conn.disconnect()
        } catch RFBError.credentialsRequired {
            securityStatus = .vnc(report: await conn.securityReport(), scope: networkTrustScope, profile: profile)
            needsCredentials = true
            phase = .authenticating
            await conn.disconnect()
        } catch RFBError.authFailed(let reason) {
            let report = await conn.securityReport()
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
            await conn.disconnect()
        } catch {
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
    }

    /// Retry connection after VNC password is entered.
    func retryWithPassword() async {
        needsPassword = false
        await connect()
    }

    /// Retry connection after macOS credentials are entered.
    func retryWithCredentials() async {
        needsCredentials = false
        await connect()
    }

    func disconnect() async {
        messageTask?.cancel()
        refreshTask?.cancel()
        await connection?.disconnect()
        phase = .ended(reason: "Disconnected")
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

    private func loadStoredCredentialIfNeeded() {
        guard vncPassword.isEmpty || username.isEmpty else { return }
        guard let stored = VNCKeychainCredentialStore.load(
            host: credentialHost,
            port: credentialPort,
            operationPrompt: CredentialKeychainAccess.operationPrompt(protocolName: profile.displayName, host: credentialHost)
        ) else { return }
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
            VNCStoredCredential(username: username, password: vncPassword),
            host: credentialHost,
            port: credentialPort,
            requireLocalAuthentication: requireLocalAuthenticationForSavedCredentials
        )
    }

    // MARK: - Input forwarding

    func sendMouseMove(x: Int, y: Int, buttons: UInt8 = 0) {
        guard case .connected = phase else { return }
        Task {
            try? await connection?.sendPointerEvent(
                buttons: buttons,
                x: UInt16(clamping: x),
                y: UInt16(clamping: y)
            )
        }
    }

    func sendMouseClick(x: Int, y: Int, button: Int, isDown: Bool) {
        guard case .connected = phase else { return }
        let mask: UInt8 = UInt8(1 << button)
        Task {
            try? await connection?.sendPointerEvent(
                buttons: isDown ? mask : 0,
                x: UInt16(clamping: x),
                y: UInt16(clamping: y)
            )
        }
    }

    func sendScroll(x: Int, y: Int, deltaY: Int) {
        guard case .connected = phase else { return }
        // RFB scroll: button 4 = scroll up, button 5 = scroll down
        let button: UInt8 = deltaY < 0 ? (1 << 3) : (1 << 4) // button 4 or 5
        Task {
            try? await connection?.sendPointerEvent(buttons: button, x: UInt16(clamping: x), y: UInt16(clamping: y))
            try? await connection?.sendPointerEvent(buttons: 0, x: UInt16(clamping: x), y: UInt16(clamping: y))
        }
    }

    func sendKey(code: UInt32, isDown: Bool) {
        guard case .connected = phase else { return }
        Task {
            try? await connection?.sendKeyEvent(down: isDown, key: code)
        }
    }

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
                    await self?.handleServerMessage(msg)
                }
            } catch {
                await MainActor.run {
                    if case .connected = self?.phase {
                        self?.phase = .failed(reason: error.localizedDescription)
                    }
                }
            }
            await MainActor.run {
                if case .connected = self?.phase {
                    self?.phase = .ended(reason: "Server disconnected")
                }
            }
        }
    }

    private func handleServerMessage(_ msg: RFBConnection.ServerMessage) {
        switch msg {
        case .framebufferUpdate(let rects):
            frameBuffer?.apply(rects)
            currentImage = frameBuffer?.makeCGImage()
        case .desktopResize(let w, let h):
            serverWidth = Int(w)
            serverHeight = Int(h)
            frameBuffer?.resize(width: Int(w), height: Int(h))
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

    // MARK: - Private: Refresh loop (request framebuffer updates)

    private func startRefreshLoop(_ conn: RFBConnection) {
        refreshTask = Task { [weak self] in
            // Initial full request.
            try? await conn.sendFramebufferUpdateRequest(
                incremental: false, x: 0, y: 0,
                w: UInt16(self?.serverWidth ?? 1920),
                h: UInt16(self?.serverHeight ?? 1080)
            )

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_333_333) // ~30 fps
                guard let s = self, case .connected = s.phase else { break }
                try? await conn.sendFramebufferUpdateRequest(
                    incremental: true, x: 0, y: 0,
                    w: UInt16(s.serverWidth),
                    h: UInt16(s.serverHeight)
                )
            }
        }
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
