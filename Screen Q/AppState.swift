//
//  AppState.swift
//  Screen Q
//
//  Top-level observable application state shared across views. Owns the
//  pieces of the app that need to outlive any single screen — discovery,
//  connection lifecycle, host services, viewer services, diagnostics.
//

import Foundation
import SwiftUI
import Combine
import Network
#if os(iOS)
import UIKit
#endif

@MainActor
final class AppState: ObservableObject {
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Identity

    let localDeviceID: UUID
    @Published var localDeviceName: String

    // MARK: - Role

    @Published var selectedRole: DeviceRole?
    @Published var viewerHasActiveSession: Bool = false
    @Published var viewerFocusMode: Bool = false

    // MARK: - Discovery

    let bonjourBrowser: BonjourBrowser
    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var discoveredRFBHosts: [DiscoveredHost] = []
    @Published var browserStatus = BrowserStatus()
    @Published var pendingViewerConnection: PendingViewerConnection?
    @Published var tailnetDevices: [TailnetDevice] = []
    @Published var tailnetDiscoveryStatus = TailnetDiscoveryStatus()
    @Published var tailnetAuthConfigured = false
    @Published var tailnetCredentialKind: TailscaleCredentialStore.CredentialKind?

    // MARK: - Networking / Sessions

    let connectionManager: ConnectionManager
    @Published var session: SessionState = .idle

    /// Globally-owned viewer session store so the menu bar / status surfaces can
    /// observe and act on active sessions regardless of which role pane is visible.
    let viewerSessions = ViewerSessionStore()

    // MARK: - Menu bar / headless mode

    /// When `true`, Screen Q runs as a menu-bar-only accessory app (no Dock icon,
    /// no app menu). Closing the main window keeps the app alive in either mode.
    @Published var menuBarOnlyMode: Bool = {
        UserDefaults.standard.bool(forKey: "ScreenQ.MenuBarOnlyMode")
    }() {
        didSet {
            UserDefaults.standard.set(menuBarOnlyMode, forKey: "ScreenQ.MenuBarOnlyMode")
            #if os(macOS)
            // AppState is @MainActor, so calls are already isolated to main.
            NSApp?.setActivationPolicy(menuBarOnlyMode ? .accessory : .regular)
            if !menuBarOnlyMode { MacWindowControls.activateApp() }
            #endif
        }
    }

    // MARK: - Host (macOS)

    #if os(macOS)
    let macPermissions: MacPermissionsService
    let displaySelection: DisplaySelectionService
    let captureTargetSelection: AnyObject?
    let macCapture: AnyObject?
    let macInput: MacInputInjectionService
    let bonjourAdvertiser: BonjourAdvertiser
    let cursorTracker: CursorTracker
    let clipboardSync: ClipboardSyncService
    let audioCapture: AnyObject?
    let remoteCommandService: RemoteCommandService
    let systemActionService: SystemActionService
    let systemReportCollector: SystemReportCollector
    let packageInstallService: PackageInstallService
    let macHost: MacHostRuntime

    // Typed accessors for @available services (stored as AnyObject? for compatibility)
    @available(macOS 12.3, *)
    var macCaptureService: MacScreenCaptureService { macCapture as! MacScreenCaptureService }
    @available(macOS 12.3, *)
    var captureTargetService: CaptureTargetSelectionService { captureTargetSelection as! CaptureTargetSelectionService }
    @available(macOS 13.0, *)
    var audioCaptureService: AudioCaptureService { audioCapture as! AudioCaptureService }
    #endif

    // MARK: - iOS host

    #if os(iOS)
    let replayKitModel: ReplayKitBroadcastModel
    let iosPresenceAdvertiser: BonjourAdvertiser
    @Published var iosPresenceAdvertising: Bool = false
    @Published var iosPresenceError: String?
    #endif

    // MARK: - Trusted Peers

    @Published var trustedPeers: [TrustedPeer] = []

    // MARK: - Saved connections

    let savedConnections = SavedConnectionsStore()

    // MARK: - Adaptive bitrate

    let adaptiveBitrate = AdaptiveBitrateController()

    // MARK: - Connection organization

    let computerList = ComputerListStore()
    let multiObserve = MultiObserveStore()

    // MARK: - Audit log

    let auditLog = AuditLog()

    // MARK: - Diagnostics

    @Published var transportStats = TransportStats()
    @Published var lastError: String?

    // MARK: - Init

    init() {
        let id = AppState.loadOrCreateDeviceID()
        let name = DeviceName.localDeviceName()
        self.localDeviceID = id
        self.localDeviceName = name

        Logger.shared.info("Screen Q launching as \(name) [\(id)]")

        self.bonjourBrowser = BonjourBrowser()
        self.connectionManager = ConnectionManager()
        let tailnetCredentialKind = TailscaleCredentialStore.configuredKind
        self.tailnetCredentialKind = tailnetCredentialKind
        self.tailnetAuthConfigured = tailnetCredentialKind != nil
        self.tailnetDiscoveryStatus = TailnetDiscoveryStatus(phase: tailnetCredentialKind == nil ? .signedOut : .idle)

        #if os(macOS)
        let permissions = MacPermissionsService()
        let display = DisplaySelectionService()
        self.macPermissions = permissions
        self.displaySelection = display
        let captureTargets: AnyObject?
        if #available(macOS 12.3, *) {
            let targets = CaptureTargetSelectionService(displaySelection: display)
            captureTargets = targets
            self.macCapture = MacScreenCaptureService(displaySelection: display, captureTargets: targets, permissions: permissions)
        } else {
            captureTargets = nil
            self.macCapture = nil
        }
        self.captureTargetSelection = captureTargets
        self.macInput = MacInputInjectionService(displaySelection: display, permissions: permissions, captureTargetSelection: captureTargets)
        self.bonjourAdvertiser = BonjourAdvertiser()
        self.cursorTracker = CursorTracker()
        self.clipboardSync = ClipboardSyncService()
        if #available(macOS 13.0, *) {
            self.audioCapture = AudioCaptureService()
        } else {
            self.audioCapture = nil
        }
        self.remoteCommandService = RemoteCommandService()
        self.systemActionService = SystemActionService()
        self.systemReportCollector = SystemReportCollector()
        self.packageInstallService = PackageInstallService()
        self.macHost = MacHostRuntime()
        #endif

        #if os(iOS)
        self.replayKitModel = ReplayKitBroadcastModel()
        self.iosPresenceAdvertiser = BonjourAdvertiser()
        #endif

        bindBrowser()

        #if os(macOS)
        self.macHost.configure(app: self)
        self.macHost.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        #endif

        #if os(iOS)
        Task { [weak self] in
            await self?.startIOSPresenceAdvertising()
        }
        #endif
    }

    // MARK: - Wiring

    private func bindBrowser() {
        Task { [weak self] in
            guard let self = self else { return }
            for await hosts in await self.bonjourBrowser.hostsStream() {
                self.discoveredHosts = hosts.filter { $0.advertisedDeviceID != self.localDeviceID.uuidString }
            }
        }
        Task { [weak self] in
            guard let self = self else { return }
            for await hosts in await self.bonjourBrowser.rfbHostsStream() {
                self.discoveredRFBHosts = hosts
            }
        }
        Task { [weak self] in
            guard let self = self else { return }
            for await status in await self.bonjourBrowser.statusStream() {
                self.browserStatus = status
            }
        }
    }

    // MARK: - Tailnet discovery

    func refreshTailnetDevices() async {
        guard let credentials = TailscaleCredentialStore.loadCredentials() else {
            tailnetAuthConfigured = false
            tailnetCredentialKind = nil
            tailnetDevices = []
            tailnetDiscoveryStatus = TailnetDiscoveryStatus(phase: .signedOut)
            return
        }

        tailnetAuthConfigured = true
        tailnetCredentialKind = TailscaleCredentialStore.configuredKind
        tailnetDiscoveryStatus = TailnetDiscoveryStatus(phase: .loading)
        do {
            let devices = try await TailnetDeviceProvider.fetchDevices(credentials: credentials)
            tailnetDevices = devices
            tailnetDiscoveryStatus = TailnetDiscoveryStatus(phase: .loaded(count: devices.count))
        } catch {
            tailnetDiscoveryStatus = TailnetDiscoveryStatus(phase: .failed(error.localizedDescription))
        }
    }

    func saveTailscaleAPIToken(_ token: String) async {
        TailscaleCredentialStore.saveAPIToken(token)
        tailnetCredentialKind = TailscaleCredentialStore.configuredKind
        tailnetAuthConfigured = TailscaleCredentialStore.hasCredentials
        await refreshTailnetDevices()
    }

    func saveTailscaleOAuthClient(id: String, secret: String) async {
        TailscaleCredentialStore.saveOAuthClientCredentials(id: id, secret: secret)
        tailnetCredentialKind = TailscaleCredentialStore.configuredKind
        tailnetAuthConfigured = TailscaleCredentialStore.hasCredentials
        await refreshTailnetDevices()
    }

    func forgetTailscaleAPIToken() {
        forgetTailscaleCredentials()
    }

    func forgetTailscaleCredentials() {
        TailscaleCredentialStore.deleteCredentials()
        tailnetAuthConfigured = false
        tailnetCredentialKind = nil
        tailnetDevices = []
        tailnetDiscoveryStatus = TailnetDiscoveryStatus(phase: .signedOut)
    }

    func wakeMACAddress(forHost host: String, port: UInt16) -> String? {
        if let saved = savedConnections.wakeMACAddress(host: host, port: port) {
            return saved
        }
        return computerList.computers.first {
            $0.host == host && $0.port == port
        }.flatMap { WakeOnLAN.normalizedMACString($0.macAddress) }
    }

    // MARK: - Role selection

    func selectRole(_ role: DeviceRole) {
        selectedRole = role
        Logger.shared.info("Role selected: \(role.rawValue)")
    }

    func clearRole() {
        selectedRole = nil
    }

    func requestViewerConnection(_ pending: PendingViewerConnection) {
        pendingViewerConnection = pending
        viewerFocusMode = false
        selectRole(.viewer)
    }

    func clearPendingViewerConnection(id: String? = nil) {
        guard let pending = pendingViewerConnection else { return }
        if let id, pending.id != id { return }
        pendingViewerConnection = nil
    }

    #if os(macOS)
    func requestHostManagement() {
        viewerFocusMode = false
        selectRole(.hostMac)
    }

    func requestStopHostingFromMenu() {
        macHost.stopHosting()
    }
    #endif

    // MARK: - iOS / iPadOS presence

    #if os(iOS)
    func startIOSPresenceAdvertising() async {
        do {
            try await iosPresenceAdvertiser.start(
                deviceName: localDeviceName,
                capabilities: .iosViewOnlyHost,
                deviceID: localDeviceID,
                metadata: [
                    ScreenQProtocol.TXT.platform: localMobilePeerPlatform.rawValue,
                    ScreenQProtocol.TXT.presence: "iosScreenShare",
                    ScreenQProtocol.TXT.supportsReplayKit: "true",
                    ScreenQProtocol.TXT.acceptsScreenQ: "false",
                    ScreenQProtocol.TXT.status: replayKitModel.isBroadcastingHint ? "broadcasting" : "ready"
                ]
            ) { connection in
                Logger.shared.info("Rejected Screen Q control connection to iOS share-only presence from \(connection.endpoint)")
                connection.cancel()
            }
            iosPresenceAdvertising = true
            iosPresenceError = nil
        } catch {
            iosPresenceAdvertising = false
            iosPresenceError = error.localizedDescription
            Logger.shared.error("iOS presence advertising failed: \(error.localizedDescription)")
        }
    }

    func stopIOSPresenceAdvertising() async {
        try? await iosPresenceAdvertiser.stop()
        iosPresenceAdvertising = false
    }

    var localMobilePeerPlatform: PeerPlatform {
        UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
    }
    #endif

    // MARK: - Trusted peers

    func trustPeer(_ peer: TrustedPeer) {
        if !trustedPeers.contains(where: { $0.id == peer.id }) {
            trustedPeers.append(peer)
        }
    }

    func untrust(peerID: UUID) {
        trustedPeers.removeAll { $0.id == peerID }
    }

    // MARK: - Persistence helpers

    private static func loadOrCreateDeviceID() -> UUID {
        let key = "ScreenQ.LocalDeviceID"
        if let raw = UserDefaults.standard.string(forKey: key),
           let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
