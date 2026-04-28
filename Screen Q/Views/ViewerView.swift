//
//  ViewerView.swift
//  Screen Q
//
//  Hosts the discovery + manual-connect surface, then transitions into the
//  RemoteScreenView once a session is approved.
//

import SwiftUI
import Combine
import Network

struct ViewerView: View {

    @EnvironmentObject private var app: AppState
    @StateObject private var sessionStore = ViewerSessionStore()

    var body: some View {
        Group {
            if let vncSession = sessionStore.activeVNCSession {
                VNCViewerView(session: vncSession) {
                    Task { await sessionStore.tearDownVNC() }
                }
            } else if let rdpSession = sessionStore.activeRDPSession {
                RDPViewerView(session: rdpSession) {
                    Task { await sessionStore.tearDownRDP() }
                }
            } else if let session = sessionStore.activeSession {
                RemoteScreenView(session: session) {
                    Task { await sessionStore.tearDown() }
                }
                .environmentObject(app)
            } else {
                discoverySurface
            }
        }
        #if os(iOS)
        .navigationTitle(sessionStore.hasActiveSession ? "" : "Connect to a remote host")
        .navigationBarTitleDisplayMode(sessionStore.hasActiveSession ? .inline : .large)
        .toolbar(sessionStore.hasActiveSession ? .hidden : .visible, for: .navigationBar)
        #else
        .navigationTitle("Connect to a remote host")
        #endif
        .onAppear {
            Task { await app.bonjourBrowser.start() }
            app.viewerHasActiveSession = sessionStore.hasActiveSession
            if !sessionStore.hasActiveSession {
                app.viewerFocusMode = false
            }
        }
        .onReceive(sessionStore.$activeSession.combineLatest(sessionStore.$activeVNCSession)) { _, _ in
            app.viewerHasActiveSession = sessionStore.hasActiveSession
            if !sessionStore.hasActiveSession {
                app.viewerFocusMode = false
            }
        }
        .onReceive(sessionStore.$activeRDPSession) { _ in
            app.viewerHasActiveSession = sessionStore.hasActiveSession
            if !sessionStore.hasActiveSession {
                app.viewerFocusMode = false
            }
        }
        .onDisappear {
            Task {
                await app.bonjourBrowser.stop()
                if app.selectedRole != .viewer {
                    await sessionStore.tearDownAll()
                    await MainActor.run {
                        app.viewerHasActiveSession = false
                        app.viewerFocusMode = false
                    }
                }
            }
        }
        .alert(isPresented: Binding(
            get: { sessionStore.lastError != nil },
            set: { if !$0 { sessionStore.lastError = nil } }
        )) {
            Alert(
                title: Text("Connection error"),
                message: Text(sessionStore.lastError ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var discoverySurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DiscoveryView { host in
                    Task { await sessionStore.connect(via: app, discoveredHost: host) }
                } onSelectRFB: { rfbHost in
                    Task { await sessionStore.openRFBHost(via: app, host: rfbHost) }
                }
                savedConnectionsCard
                ManualConnectView { hostText, port, connectionProtocol in
                    Task { await sessionStore.connect(via: app, hostText: hostText, port: port, connectionProtocol: connectionProtocol) }
                } onImportRDP: { profile in
                    sessionStore.startRDPSession(profile: profile, app: app)
                }
                infoCard
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var savedConnectionsCard: some View {
        let conns = app.savedConnections.connections
        if !conns.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Recent & Bookmarked", systemImage: "clock")
                        .font(.headline)
                    Spacer()
                    if conns.contains(where: { !$0.isBookmark }) {
                        Button("Clear Recents") {
                            app.savedConnections.clearRecents()
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }
                }
                ForEach(conns) { saved in
                    HStack {
                        Button {
                            Task {
                                if saved.resolvedProtocol == .macScreenSharing {
                                    sessionStore.startVNCSession(host: saved.host, port: saved.port, label: saved.displayName, profile: .macScreenSharing)
                                } else if saved.resolvedProtocol == .vnc {
                                    sessionStore.startVNCSession(host: saved.host, port: saved.port, label: saved.displayName, profile: .genericVNC)
                                } else if saved.resolvedProtocol == .rdp {
                                    sessionStore.startRDPSession(host: saved.host, port: saved.port, label: saved.displayName, app: app)
                                } else {
                                    await sessionStore.connect(via: app, hostText: saved.host, port: saved.port, connectionProtocol: saved.resolvedProtocol)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: saved.isBookmark ? "star.fill" : "clock")
                                    .foregroundColor(saved.isBookmark ? .yellow : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(saved.displayName).font(.body)
                                    Text("\(saved.resolvedProtocol.displayName) - \(saved.address)").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            app.savedConnections.toggleBookmark(saved.id)
                        } label: {
                            Image(systemName: saved.isBookmark ? "star.slash" : "star")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(14)
            .background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local network discovery uses Bonjour over your current Wi-Fi or wired LAN.", systemImage: "antenna.radiowaves.left.and.right")
            Label("To connect across networks, install Tailscale on both devices and use the MagicDNS name or 100.x address.", systemImage: "lock.shield")
            Label("Default Screen Q port is \(ScreenQProtocol.defaultPort). VNC's 5900 is intentionally avoided.", systemImage: "number")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
    }
}

@MainActor
final class ViewerSessionStore: ObservableObject {

    @Published var activeSession: ViewerSession?
    @Published var activeVNCSession: VNCSession?
    @Published var activeRDPSession: RDPSession?
    @Published var lastError: String?

    var hasActiveSession: Bool {
        activeSession != nil || activeVNCSession != nil || activeRDPSession != nil
    }

    // MARK: - Screen Q connections

    func connect(via app: AppState, discoveredHost: DiscoveredHost) async {
        guard let endpoint = await app.bonjourBrowser.endpoint(for: discoveredHost) else {
            lastError = "Could not resolve \(discoveredHost.displayName)."
            return
        }
        await connect(via: app, endpoint: endpoint, label: discoveredHost.displayName)
    }

    func connect(via app: AppState, hostText: String, port: UInt16) async {
        let legacyProtocol: RemoteConnectionProtocol = port == RemoteConnectionProtocol.vnc.defaultPort ? .macScreenSharing : .screenQ
        await connect(via: app, hostText: hostText, port: port, connectionProtocol: legacyProtocol)
    }

    func connect(via app: AppState, hostText: String, port: UInt16, connectionProtocol: RemoteConnectionProtocol) async {
        switch connectionProtocol {
        case .macScreenSharing:
            app.savedConnections.addOrUpdate(host: hostText, port: port, displayName: hostText, connectionProtocol: connectionProtocol)
            startVNCSession(host: hostText, port: port, label: hostText, profile: .macScreenSharing)
            return

        case .vnc:
            app.savedConnections.addOrUpdate(host: hostText, port: port, displayName: hostText, connectionProtocol: connectionProtocol)
            startVNCSession(host: hostText, port: port, label: hostText, profile: .genericVNC)
            return

        case .rdp:
            app.savedConnections.addOrUpdate(host: hostText, port: port, displayName: hostText, connectionProtocol: connectionProtocol)
            startRDPSession(host: hostText, port: port, label: hostText, app: app)
            return

        case .screenQ:
            break
        }

        let probe = await ConnectivityProbe.probe(host: hostText, port: port, timeoutSeconds: 5)
        guard probe.succeeded else {
            lastError = probe.friendlyMessage
            Logger.shared.error("Probe \(hostText):\(port) → \(probe.friendlyMessage)")
            return
        }

        let host = NWEndpoint.Host(hostText)
        let p = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: ScreenQProtocol.defaultPort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: p)
        app.savedConnections.addOrUpdate(host: hostText, port: port, displayName: hostText, connectionProtocol: connectionProtocol)
        await connect(via: app, endpoint: endpoint, label: "\(hostText):\(port)")
    }

    func connect(via app: AppState, endpoint: NWEndpoint, label: String) async {
        do {
            let connection = try await app.connectionManager.dial(endpoint)
            let session = ViewerSession(connection: connection, peerLabel: label, app: app)
            self.activeSession = session
            await session.beginHandshake()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func tearDown() async {
        if let s = activeSession {
            await s.tearDown(reason: "User disconnected")
        }
        activeSession = nil
    }

    // MARK: - VNC / RFB connections

    /// Connect to a discovered Apple Screen Sharing host using our native VNC viewer.
    func openRFBHost(via app: AppState, host: DiscoveredHost) async {
        guard let endpoint = await app.bonjourBrowser.endpoint(for: host) else {
            lastError = "Could not resolve \(host.displayName) to a network address."
            return
        }
        startVNCSession(endpoint: endpoint, label: host.displayName, profile: .macScreenSharing)
    }

    func startVNCSession(host: String, port: UInt16 = 5900, label: String, profile: RFBConnectionProfile = .genericVNC) {
        let session = VNCSession(host: host, port: port, label: label, profile: profile)
        self.activeVNCSession = session
        Task { await session.connect() }
    }

    func startVNCSession(endpoint: NWEndpoint, label: String, profile: RFBConnectionProfile = .macScreenSharing) {
        let session = VNCSession(endpoint: endpoint, label: label, profile: profile)
        self.activeVNCSession = session
        Task { await session.connect() }
    }

    func tearDownVNC() async {
        if let s = activeVNCSession {
            await s.disconnect()
        }
        activeVNCSession = nil
    }

    // MARK: - RDP connections

    func startRDPSession(host: String, port: UInt16 = RemoteConnectionProtocol.rdp.defaultPort, label: String, app: AppState) {
        let profile = RDPConnectionProfile(displayName: label, host: host, port: port)
        startRDPSession(profile: profile, app: app)
    }

    func startRDPSession(profile: RDPConnectionProfile, app: AppState) {
        app.savedConnections.addOrUpdate(
            host: profile.host,
            port: profile.port,
            displayName: profile.displayName,
            connectionProtocol: .rdp
        )
        let session = RDPSession(profile: profile)
        self.activeRDPSession = session
        Task { await session.connect() }
    }

    func tearDownRDP() async {
        if let s = activeRDPSession {
            await s.disconnect()
        }
        activeRDPSession = nil
    }

    func tearDownAll() async {
        await tearDown()
        await tearDownVNC()
        await tearDownRDP()
    }
}
