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

@MainActor
final class AppState: ObservableObject {

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

    // MARK: - Networking / Sessions

    let connectionManager: ConnectionManager
    @Published var session: SessionState = .idle

    // MARK: - Host (macOS)

    #if os(macOS)
    let macPermissions: MacPermissionsService
    let displaySelection: DisplaySelectionService
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
    @Published var hostPairingCode: String = ""
    @Published var hostIsSharing: Bool = false
    @Published var hostViewOnly: Bool = false
    @Published var hostPermissions: PermissionSet = .standard
    @Published var pendingPairingRequests: [PairingRequest] = []

    // Typed accessors for @available services (stored as AnyObject? for compatibility)
    @available(macOS 12.3, *)
    var macCaptureService: MacScreenCaptureService { macCapture as! MacScreenCaptureService }
    @available(macOS 13.0, *)
    var audioCaptureService: AudioCaptureService { audioCapture as! AudioCaptureService }
    #endif

    // MARK: - iOS host

    #if os(iOS)
    let replayKitModel: ReplayKitBroadcastModel
    #endif

    // MARK: - Trusted Peers

    @Published var trustedPeers: [TrustedPeer] = []

    // MARK: - Saved connections

    let savedConnections = SavedConnectionsStore()

    // MARK: - Adaptive bitrate

    let adaptiveBitrate = AdaptiveBitrateController()

    // MARK: - Fleet management

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

        #if os(macOS)
        let permissions = MacPermissionsService()
        let display = DisplaySelectionService()
        self.macPermissions = permissions
        self.displaySelection = display
        if #available(macOS 12.3, *) {
            self.macCapture = MacScreenCaptureService(displaySelection: display, permissions: permissions)
        } else {
            self.macCapture = nil
        }
        self.macInput = MacInputInjectionService(displaySelection: display, permissions: permissions)
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
        #endif

        #if os(iOS)
        self.replayKitModel = ReplayKitBroadcastModel()
        #endif

        bindBrowser()
    }

    // MARK: - Wiring

    private func bindBrowser() {
        Task { [weak self] in
            guard let self = self else { return }
            for await hosts in await self.bonjourBrowser.hostsStream() {
                self.discoveredHosts = hosts
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

    // MARK: - Role selection

    func selectRole(_ role: DeviceRole) {
        selectedRole = role
        Logger.shared.info("Role selected: \(role.rawValue)")
    }

    func clearRole() {
        selectedRole = nil
    }

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
