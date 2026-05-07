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
    @EnvironmentObject private var sessionStore: ViewerSessionStore
    @State private var selectedShareOnlyDevice: DiscoveredHost?
    @State private var showingMultiObserveOverview = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if !sessionStore.sessions.isEmpty {
                MacSessionTabBar(
                    store: sessionStore,
                    showingMultiObserveOverview: $showingMultiObserveOverview
                )
            }
            #endif
            Group {
                if showingMultiObserveOverview && !sessionStore.sessions.isEmpty {
                    MultiObserveSessionGrid(store: sessionStore) { id in
                        sessionStore.selectSession(id: id)
                        showingMultiObserveOverview = false
                    }
                } else if let vncSession = sessionStore.activeVNCSession {
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
            if let pending = app.pendingViewerConnection {
                consumePendingViewerConnection(pending)
            }
        }
        .onReceive(app.$pendingViewerConnection.compactMap { $0 }) { pending in
            consumePendingViewerConnection(pending)
        }
        .onReceive(sessionStore.$activeSession.combineLatest(sessionStore.$activeVNCSession)) { _, _ in
            app.viewerHasActiveSession = sessionStore.hasActiveSession
            if !sessionStore.hasActiveSession {
                app.viewerFocusMode = false
                showingMultiObserveOverview = false
            }
        }
        .onReceive(sessionStore.$activeRDPSession) { _ in
            app.viewerHasActiveSession = sessionStore.hasActiveSession
            if !sessionStore.hasActiveSession {
                app.viewerFocusMode = false
                showingMultiObserveOverview = false
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
        ConnectionHubView(
            sessionStore: sessionStore,
            onConnectDiscovered: { host in
                if host.isIOSShareOnlyPresence {
                    selectedShareOnlyDevice = host
                } else {
                    Task { await sessionStore.connect(via: app, discoveredHost: host) }
                }
            },
            onConnectRFB: { rfbHost in
                Task { await sessionStore.openRFBHost(via: app, host: rfbHost) }
            },
            onConnectTailnet: { device, connectionProtocol in
                guard let host = device.connectionHost else { return }
                Task {
                    await sessionStore.connect(
                        via: app,
                        hostText: host,
                        port: connectionProtocol.defaultPort,
                        connectionProtocol: connectionProtocol
                    )
                }
            },
            onConnectSaved: { saved in
                connect(to: saved)
            },
            onManualConnect: { hostText, port, connectionProtocol, wakeMAC in
                Task {
                    await sessionStore.connect(
                        via: app,
                        hostText: hostText,
                        port: port,
                        connectionProtocol: connectionProtocol,
                        wakeMACAddress: wakeMAC
                    )
                }
            },
            onImportRDP: { profile in
                sessionStore.startRDPSession(profile: profile, app: app)
            }
        )
        .sheet(item: $selectedShareOnlyDevice) { host in
            IOSShareOnlyDeviceSheet(host: host)
        }
    }


    private func connect(to saved: SavedConnection) {
        Task {
            await sessionStore.connect(
                via: app,
                hostText: saved.host,
                port: saved.port,
                connectionProtocol: saved.resolvedProtocol,
                displayName: saved.displayName,
                wakeMACAddress: saved.wakeMACAddress
            )
        }
    }

    private func consumePendingViewerConnection(_ pending: PendingViewerConnection) {
        // With multi-session support, new connections always open in a new tab.
        app.clearPendingViewerConnection(id: pending.id)
        switch pending {
        case .screenQ(let host):
            if host.isIOSShareOnlyPresence {
                selectedShareOnlyDevice = host
            } else {
                Task { await sessionStore.connect(via: app, discoveredHost: host) }
            }
        case .macScreenSharing(let host):
            Task { await sessionStore.openRFBHost(via: app, host: host) }
        case .manual(let host, let port, let displayName, let connectionProtocol):
            Task {
                await sessionStore.connect(
                    via: app,
                    hostText: host,
                    port: port,
                    connectionProtocol: connectionProtocol,
                    displayName: displayName
                )
            }
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

#if os(macOS)
private struct MacSessionTabBar: View {
    @ObservedObject var store: ViewerSessionStore
    @Binding var showingMultiObserveOverview: Bool

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.sessions) { slot in
                        tabButton(for: slot)
                    }
                }
                .padding(.horizontal, 6)
            }

            Button {
                store.showDiscoverySurface()
                showingMultiObserveOverview = false
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(store.selectedSessionID == nil ? Color.accentColor.opacity(0.25) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("New connection")

            Button {
                showingMultiObserveOverview.toggle()
            } label: {
                Image(systemName: showingMultiObserveOverview ? "rectangle.3.group.fill" : "rectangle.3.group")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(showingMultiObserveOverview ? Color.accentColor.opacity(0.25) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .disabled(store.sessions.count < 2)
            .opacity(store.sessions.count < 2 ? 0.45 : 1)
            .help("Multi-observe")
            .padding(.trailing, 8)
        }
        .frame(height: 30)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    private func tabButton(for slot: ViewerSessionSlot) -> some View {
        let isSelected = store.selectedSessionID == slot.id
        return HStack(spacing: 6) {
            Image(systemName: slot.systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(slot.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                Task { await store.closeSession(id: slot.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(slot.label)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectSession(id: slot.id)
            showingMultiObserveOverview = false
        }
    }
}
#endif

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
                    Text("Apple-native iPhone/iPad sharing")
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Use iPhone Mirroring on a nearby Mac when you need interactive control.", systemImage: "1.circle")
                Label("Use FaceTime SharePlay Remote Control when both people can join the same call.", systemImage: "2.circle")
                Label("Screen Q does not market ReplayKit iPhone/iPad sharing as a commercial remote-control path.", systemImage: "3.circle")
            }
            .font(.subheadline)

            HStack {
                Label("Use Apple-managed controls", systemImage: "sparkles.tv")
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

enum ViewerSessionSlotKind {
    case screenQ(ViewerSession)
    case vnc(VNCSession)
    case rdp(RDPSession)
}

struct ViewerSessionSlot: Identifiable {
    let id = UUID()
    var kind: ViewerSessionSlotKind

    var label: String {
        switch kind {
        case .screenQ(let s): return s.peerLabel
        case .vnc(let s):     return s.serverName.isEmpty ? s.peerLabel : s.serverName
        case .rdp(let s):     return s.profile.displayName
        }
    }

    var systemImage: String {
        switch kind {
        case .screenQ: return "display"
        case .vnc:     return "rectangle.on.rectangle"
        case .rdp:     return "pc"
        }
    }
}

@MainActor
final class ViewerSessionStore: ObservableObject {

    @Published private(set) var sessions: [ViewerSessionSlot] = []
    @Published var selectedSessionID: UUID?

    @Published var activeSession: ViewerSession?
    @Published var activeVNCSession: VNCSession?
    @Published var activeRDPSession: RDPSession?
    @Published var lastError: String?

    var hasActiveSession: Bool {
        !sessions.isEmpty && selectedSessionID != nil
    }

    var currentSlot: ViewerSessionSlot? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    /// Deselect — shows the discovery surface while keeping background sessions alive.
    func showDiscoverySurface() {
        selectedSessionID = nil
        refreshActiveBindings()
    }

    func selectSession(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        refreshActiveBindings()
    }

    func closeSession(id: UUID) async {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let slot = sessions[idx]
        switch slot.kind {
        case .screenQ(let s): await s.tearDown(reason: "User disconnected")
        case .vnc(let s):     await s.disconnect()
        case .rdp(let s):     await s.disconnect()
        }
        sessions.remove(at: idx)
        if selectedSessionID == id {
            selectedSessionID = sessions.last?.id
        }
        refreshActiveBindings()
    }

    private func append(_ slot: ViewerSessionSlot) {
        sessions.append(slot)
        selectedSessionID = slot.id
        refreshActiveBindings()
    }

    private func refreshActiveBindings() {
        switch currentSlot?.kind {
        case .screenQ(let s):
            activeSession = s; activeVNCSession = nil; activeRDPSession = nil
        case .vnc(let s):
            activeSession = nil; activeVNCSession = s; activeRDPSession = nil
        case .rdp(let s):
            activeSession = nil; activeVNCSession = nil; activeRDPSession = s
        case .none:
            activeSession = nil; activeVNCSession = nil; activeRDPSession = nil
        }
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

    func connect(
        via app: AppState,
        hostText: String,
        port: UInt16,
        connectionProtocol: RemoteConnectionProtocol,
        displayName: String? = nil,
        wakeMACAddress: String? = nil
    ) async {
        let label = displayName ?? hostText
        let wakeMAC = WakeOnLAN.normalizedMACString(wakeMACAddress)
            ?? app.wakeMACAddress(forHost: hostText, port: port)
        let didSendWake = await sendWakePacketIfPossible(macAddress: wakeMAC, host: hostText, port: port)

        switch connectionProtocol {
        case .macScreenSharing:
            app.savedConnections.addOrUpdate(
                host: hostText,
                port: port,
                displayName: label,
                connectionProtocol: connectionProtocol,
                wakeMACAddress: wakeMAC
            )
            startVNCSession(host: hostText, port: port, label: label, profile: .macScreenSharing)
            return

        case .vnc:
            app.savedConnections.addOrUpdate(
                host: hostText,
                port: port,
                displayName: label,
                connectionProtocol: connectionProtocol,
                wakeMACAddress: wakeMAC
            )
            startVNCSession(host: hostText, port: port, label: label, profile: .genericVNC)
            return

        case .rdp:
            app.savedConnections.addOrUpdate(
                host: hostText,
                port: port,
                displayName: label,
                connectionProtocol: connectionProtocol,
                wakeMACAddress: wakeMAC
            )
            startRDPSession(host: hostText, port: port, label: label, app: app)
            return

        case .screenQ:
            break
        }

        let probeTimeout: TimeInterval = didSendWake ? 18 : 5
        let probe = await ConnectivityProbe.probe(host: hostText, port: port, timeoutSeconds: probeTimeout)
        guard probe.succeeded else {
            lastError = didSendWake
                ? "\(probe.friendlyMessage) A Wake-on-LAN packet was sent first, but the host did not become reachable before the timeout."
                : probe.friendlyMessage
            Logger.shared.error("Probe \(hostText):\(port) → \(probe.friendlyMessage)")
            return
        }

        let host = NWEndpoint.Host(hostText)
        let p = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: ScreenQProtocol.defaultPort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: p)
        app.savedConnections.addOrUpdate(
            host: hostText,
            port: port,
            displayName: label,
            connectionProtocol: connectionProtocol,
            wakeMACAddress: wakeMAC
        )
        await connect(
            via: app,
            endpoint: endpoint,
            label: displayName ?? "\(hostText):\(port)",
            controlPreferenceScope: ViewerControlPreferenceScope(
                connectionProtocol: .screenQ,
                host: hostText,
                port: port
            )
        )
    }

    private func sendWakePacketIfPossible(macAddress: String?, host: String, port: UInt16) async -> Bool {
        guard let macAddress else { return false }
        do {
            try await WakeOnLAN.wake(macString: macAddress)
            Logger.shared.info("Sent Wake-on-LAN packet before connecting to \(host):\(port)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return true
        } catch {
            Logger.shared.warn("Wake-on-LAN failed for \(host):\(port): \(error.localizedDescription)")
            return false
        }
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
                endpoint: endpoint,
                controlPreferenceScope: controlPreferenceScope
            )
            append(ViewerSessionSlot(kind: .screenQ(session)))
            await session.beginHandshake()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func tearDown() async {
        if let id = currentSlot?.id, case .screenQ = currentSlot?.kind {
            await closeSession(id: id)
        }
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
        append(ViewerSessionSlot(kind: .vnc(session)))
        session.startConnecting()
    }

    func startVNCSession(endpoint: NWEndpoint, label: String, profile: RFBConnectionProfile = .macScreenSharing) {
        let session = VNCSession(endpoint: endpoint, label: label, profile: profile)
        append(ViewerSessionSlot(kind: .vnc(session)))
        session.startConnecting()
    }

    func tearDownVNC() async {
        if let id = currentSlot?.id, case .vnc = currentSlot?.kind {
            await closeSession(id: id)
        }
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
        append(ViewerSessionSlot(kind: .rdp(session)))
        Task { await session.connect() }
    }

    func tearDownRDP() async {
        if let id = currentSlot?.id, case .rdp = currentSlot?.kind {
            await closeSession(id: id)
        }
    }

    func tearDownAll() async {
        // Snapshot ids so closeSession's mutations don't invalidate iteration.
        let ids = sessions.map(\.id)
        for id in ids {
            await closeSession(id: id)
        }
    }
}
