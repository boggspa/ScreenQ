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
import ImageIO

struct ViewerView: View {

    @EnvironmentObject private var app: AppState
    @StateObject private var sessionStore = ViewerSessionStore()
    @State private var savedConnectionTab: SavedConnectionTab = .connected
    @State private var selectedShareOnlyDevice: DiscoveredHost?

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
                    if host.isIOSShareOnlyPresence {
                        selectedShareOnlyDevice = host
                    } else {
                        Task { await sessionStore.connect(via: app, discoveredHost: host) }
                    }
                } onSelectRFB: { rfbHost in
                    Task { await sessionStore.openRFBHost(via: app, host: rfbHost) }
                } onSelectTailnet: { device, connectionProtocol in
                    guard let host = device.connectionHost else { return }
                    Task {
                        await sessionStore.connect(
                            via: app,
                            hostText: host,
                            port: connectionProtocol.defaultPort,
                            connectionProtocol: connectionProtocol
                        )
                    }
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
        .sheet(item: $selectedShareOnlyDevice) { host in
            IOSShareOnlyDeviceSheet(host: host)
        }
    }

    @ViewBuilder
    private var savedConnectionsCard: some View {
        let conns = app.savedConnections.connections
        if !conns.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Connections", systemImage: "rectangle.connected.to.line.below")
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

                Picker("Connection view", selection: $savedConnectionTab) {
                    Text("Connected").tag(SavedConnectionTab.connected)
                    Text("All").tag(SavedConnectionTab.all)
                }
                .pickerStyle(.segmented)

                if savedConnectionTab == .connected {
                    let continueItems = continueConnections(from: conns)
                    if continueItems.isEmpty {
                        Text("Connect once to create quick resume thumbnails.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(continueItems) { saved in
                                    Button {
                                        connect(to: saved)
                                    } label: {
                                        continueCard(saved)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    ForEach(conns) { saved in
                        HStack {
                            Button {
                                connect(to: saved)
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
            }
            .padding(14)
            .background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func continueCard(_ saved: SavedConnection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            savedConnectionThumbnail(saved)
                .frame(width: 210, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(continueProtocolBadge(saved))
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(saved.address)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 210, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func continueProtocolBadge(_ saved: SavedConnection) -> some View {
        VStack {
            HStack {
                Label(saved.resolvedProtocol.displayName, systemImage: protocolIcon(saved.resolvedProtocol))
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.68))
                    .clipShape(Capsule())
                Spacer()
            }
            Spacer()
        }
        .padding(8)
    }

    @ViewBuilder
    private func savedConnectionThumbnail(_ saved: SavedConnection) -> some View {
        if let data = saved.thumbnailData,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.65))
                Image(systemName: protocolIcon(saved.resolvedProtocol))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func continueConnections(from connections: [SavedConnection]) -> [SavedConnection] {
        var result: [SavedConnection] = []
        if let windows = connections.first(where: { $0.resolvedProtocol == .rdp }) {
            result.append(windows)
        }
        if let mac = connections.first(where: { $0.resolvedProtocol == .screenQ || $0.resolvedProtocol == .macScreenSharing || $0.resolvedProtocol == .vnc }) {
            result.append(mac)
        }
        if result.isEmpty {
            result = Array(connections.prefix(2))
        }
        return result
    }

    private func connect(to saved: SavedConnection) {
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
    }

    private func protocolIcon(_ connectionProtocol: RemoteConnectionProtocol) -> String {
        switch connectionProtocol {
        case .screenQ: return "display"
        case .macScreenSharing: return "macwindow"
        case .vnc: return "rectangle.on.rectangle"
        case .rdp: return "pc"
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

private struct IOSShareOnlyDeviceSheet: View {
    let host: DiscoveredHost
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: host.advertisedPlatform == "iPadOS" ? "ipad" : "iphone")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName)
                        .font(.title2.bold())
                    Text("View-only iOS screen share")
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Ask the user to open Screen Q on this device and choose Share this iPhone or iPad screen.", systemImage: "1.circle")
                Label("They must start Screen Q Broadcast from Apple's system broadcast sheet.", systemImage: "2.circle")
                Label("Screen Q treats this path as view-only; iOS does not allow third-party remote control.", systemImage: "3.circle")
            }
            .font(.subheadline)

            HStack {
                Label(host.advertisedStatus == "broadcasting" ? "Broadcasting" : "Ready to share", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Done") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding(24)
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 520, alignment: .leading)
    }
}

private enum SavedConnectionTab: String, CaseIterable, Hashable {
    case connected
    case all
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
        await connect(
            via: app,
            endpoint: endpoint,
            label: "\(hostText):\(port)",
            controlPreferenceScope: ViewerControlPreferenceScope(
                connectionProtocol: .screenQ,
                host: hostText,
                port: port
            )
        )
    }

    func connect(
        via app: AppState,
        endpoint: NWEndpoint,
        label: String,
        controlPreferenceScope: ViewerControlPreferenceScope? = nil
    ) async {
        do {
            let connection = try await app.connectionManager.dial(endpoint)
            let session = ViewerSession(
                connection: connection,
                peerLabel: label,
                app: app,
                controlPreferenceScope: controlPreferenceScope
            )
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
        session.startConnecting()
    }

    func startVNCSession(endpoint: NWEndpoint, label: String, profile: RFBConnectionProfile = .macScreenSharing) {
        let session = VNCSession(endpoint: endpoint, label: label, profile: profile)
        self.activeVNCSession = session
        session.startConnecting()
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
