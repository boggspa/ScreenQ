//
//  ConnectionHubView.swift
//  Screen Q
//
//  The premium connection hub used by the viewer surface — inspired
//  by Screens (iOS) and Apple Remote Desktop (macOS). Replaces the
//  former plain "discoverySurface" with a sectioned visual layout
//  built around large, gradient-tinted cards.
//

import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ConnectionHubView: View {

    @EnvironmentObject private var app: AppState
    @ObservedObject var sessionStore: ViewerSessionStore

    var onConnectDiscovered: (DiscoveredHost) -> Void
    var onConnectRFB: (DiscoveredHost) -> Void
    var onConnectTailnet: (TailnetDevice, RemoteConnectionProtocol) -> Void
    var onConnectSaved: (SavedConnection) -> Void
    var onManualConnect: (String, UInt16, RemoteConnectionProtocol, String?) -> Void
    var onImportRDP: (RDPConnectionProfile) -> Void

    @State private var showManualSheet = false
    @State private var selectedSavedConnection: SavedConnection?
    @State private var editingSavedConnection: SavedConnectionEditorDraft?
    @State private var selectedNearbyHost: NearbyHostDetail?
    @State private var selectedTailnetDevice: TailnetDevice?
    @State private var editingGroup: ConnectionGroupEditorDraft?
    @State private var showTailnetSetupSheet = false
    @State private var quickConnectText = ""
    @State private var quickConnectProtocol: RemoteConnectionProtocol = .screenQ
    @State private var quickConnectError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroHeader
                if !sessionStore.sessions.isEmpty {
                    activeSessionsSection
                }
                savedSection
                linksSection
                recentsSection
                nearbySection
                tailnetLibrarySection
                groupsSection
                infoFooter
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 40)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(backgroundGradient.ignoresSafeArea())
        .sheet(isPresented: $showManualSheet) {
            manualConnectSheet
        }
        .sheet(item: $selectedSavedConnection) { saved in
            SavedConnectionDetailSheet(
                saved: saved,
                groups: groups(for: saved),
                onConnect: {
                    selectedSavedConnection = nil
                    onConnectSaved(saved)
                },
                onEdit: {
                    selectedSavedConnection = nil
                    editingSavedConnection = SavedConnectionEditorDraft(saved: saved)
                },
                onCopyLink: { copyQuickLink(saved.quickConnectURLString) },
                onDelete: {
                    app.savedConnections.remove(saved.id)
                    selectedSavedConnection = nil
                }
            )
        }
        .sheet(item: $editingSavedConnection) { draft in
            SavedConnectionEditorSheet(
                draft: draft,
                groups: app.computerList.groups,
                onCancel: { editingSavedConnection = nil },
                onSave: { updated in
                    app.savedConnections.update(updated)
                    editingSavedConnection = nil
                }
            )
        }
        .sheet(item: $selectedNearbyHost) { detail in
            NearbyHostDetailSheet(
                detail: detail,
                onConnect: {
                    selectedNearbyHost = nil
                    connect(detail)
                }
            )
        }
        .sheet(item: $selectedTailnetDevice) { device in
            TailnetDeviceDetailSheet(
                device: device,
                onConnect: { connectionProtocol in
                    selectedTailnetDevice = nil
                    onConnectTailnet(device, connectionProtocol)
                },
                onSave: {
                    saveTailnetDevice(device, bookmark: true)
                }
            )
        }
        .sheet(item: $editingGroup) { draft in
            ConnectionGroupEditorSheet(
                draft: draft,
                onCancel: { editingGroup = nil },
                onSave: { group in
                    if app.computerList.groups.contains(where: { $0.id == group.id }) {
                        app.computerList.updateGroup(group)
                    } else {
                        app.computerList.addGroup(name: group.name, icon: group.icon)
                    }
                    editingGroup = nil
                }
            )
        }
        .sheet(isPresented: $showTailnetSetupSheet) {
            tailnetSetupSheet
        }
        #if os(iOS)
        .overlay(
            quickConnectFAB.padding(20),
            alignment: .bottomTrailing
        )
        #endif
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeOfDayGreeting)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text("Pick a screen.")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                }
                Spacer()
                #if os(macOS)
                Button {
                    showManualSheet = true
                } label: {
                    Label("New Connection", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.18))
                        )
                        .overlay(
                            Capsule().stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                        )
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                #endif
            }
            HStack(spacing: 8) {
                Circle().fill(networkStatusColor).frame(width: 7, height: 7)
                Text(networkStatusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Active sessions

    private var activeSessionsSection: some View {
        sectionContainer(
            title: "Active",
            count: sessionStore.sessions.count,
            symbol: "dot.radiowaves.left.and.right"
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(sessionStore.sessions) { slot in
                        ActiveSessionCard(slot: slot) {
                            sessionStore.selectSession(id: slot.id)
                        } onClose: {
                            Task { await sessionStore.closeSession(id: slot.id) }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Saved

    private var savedSection: some View {
        let bookmarks = app.savedConnections.connections.filter(\.isBookmark)
        return Group {
            if !bookmarks.isEmpty {
                sectionContainer(
                    title: "Saved",
                    count: bookmarks.count,
                    symbol: "star.fill"
                ) {
                    cardGrid(bookmarks, large: true)
                }
            }
        }
    }

    // MARK: - Links / Quick Connect

    private var linksSection: some View {
        sectionContainer(
            title: "Links / Quick Connect",
            count: nil,
            symbol: "link",
            trailing: AnyView(importRDPButton)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(RemoteConnectionProtocol.allCases, id: \.self) { connectionProtocol in
                            Button {
                                quickConnectProtocol = connectionProtocol
                            } label: {
                                Label(connectionProtocol.displayName, systemImage: connectionProtocol.systemImage)
                            }
                        }
                    } label: {
                        Label(quickConnectProtocol.displayName, systemImage: quickConnectProtocol.systemImage)
                            .frame(minWidth: 128)
                    }
                    .buttonStyle(.bordered)

                    TextField("host, host:port, screenq://, screens://, vnc://, rdp://", text: $quickConnectText)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                        #endif

                    Button {
                        connectQuickLink(saveFirst: false)
                    } label: {
                        Label("Connect", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(quickConnectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        connectQuickLink(saveFirst: true)
                    } label: {
                        Label("Save", systemImage: "star")
                    }
                    .buttonStyle(.bordered)
                    .disabled(quickConnectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let quickConnectError {
                    Label(quickConnectError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                let quickLinks = app.savedConnections.connections.filter(\.isBookmark).prefix(8)
                if !quickLinks.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(quickLinks)) { saved in
                                Button {
                                    copyQuickLink(saved.quickConnectURLString)
                                } label: {
                                    Label(saved.quickConnectURLString, systemImage: "link")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .contextMenu {
                                    Button {
                                        onConnectSaved(saved)
                                    } label: {
                                        Label("Connect", systemImage: "play.fill")
                                    }
                                    Button {
                                        copyQuickLink(saved.quickConnectURLString)
                                    } label: {
                                        Label("Copy Link", systemImage: "doc.on.doc")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(panelBackground)
        }
    }

    private var importRDPButton: some View {
        Button {
            showManualSheet = true
        } label: {
            Label("New / Import", systemImage: "plus")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    // MARK: - Recents

    private var recentsSection: some View {
        let recents = app.savedConnections.connections.filter { !$0.isBookmark }
        return Group {
            if !recents.isEmpty {
                sectionContainer(
                    title: "Recents",
                    count: recents.count,
                    symbol: "clock.arrow.circlepath",
                    trailing: AnyView(clearRecentsButton)
                ) {
                    cardGrid(Array(recents.prefix(12)), large: false)
                }
            }
        }
    }

    private var clearRecentsButton: some View {
        Button("Clear") {
            app.savedConnections.clearRecents()
        }
        .font(.caption)
        .foregroundColor(.red)
    }

    // MARK: - Nearby

    private var nearbySection: some View {
        sectionContainer(
            title: "Nearby",
            count: app.discoveredHosts.count + app.discoveredRFBHosts.count,
            symbol: "antenna.radiowaves.left.and.right",
            trailing: AnyView(rescanButton)
        ) {
            DiscoveryView(
                onSelect: onConnectDiscovered,
                onSelectRFB: onConnectRFB,
                onSelectTailnet: onConnectTailnet,
                showsTailnet: false,
                onDetails: { host, connectionProtocol in
                    selectedNearbyHost = NearbyHostDetail(host: host, connectionProtocol: connectionProtocol)
                }
            )
            .padding(16)
            .background(panelBackground)
        }
    }

    private var rescanButton: some View {
        Button {
            Task { await app.bonjourBrowser.start() }
        } label: {
            Label("Rescan", systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    // MARK: - Tailnet

    private var tailnetLibrarySection: some View {
        sectionContainer(
            title: "Tailnet",
            count: app.tailnetDevices.count,
            symbol: "lock.shield",
            trailing: AnyView(tailnetRefreshButton)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if !app.tailnetAuthConfigured {
                    HStack {
                        Label("Connect Tailscale credentials to list remote devices.", systemImage: "key")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Configure") { showTailnetSetupSheet = true }
                            .buttonStyle(.bordered)
                    }
                } else if app.tailnetDevices.isEmpty {
                    Label(app.tailnetDiscoveryStatus.summary, systemImage: "magnifyingglass")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(app.tailnetDevices) { device in
                            TailnetLibraryRow(device: device) { connectionProtocol in
                                onConnectTailnet(device, connectionProtocol)
                            } onDetails: {
                                selectedTailnetDevice = device
                            } onSave: {
                                saveTailnetDevice(device, bookmark: true)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(panelBackground)
        }
    }

    private var tailnetRefreshButton: some View {
        Button {
            Task { await app.refreshTailnetDevices() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    private var tailnetSetupSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tailnet")
                    .font(.title3.bold())
                Spacer()
                Button {
                    showTailnetSetupSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            Divider()
            DiscoveryView(
                onSelect: { _ in },
                onSelectRFB: { _ in },
                onSelectTailnet: { device, connectionProtocol in
                    showTailnetSetupSheet = false
                    onConnectTailnet(device, connectionProtocol)
                },
                showsTailnet: true
            )
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 520, idealHeight: 680)
    }

    // MARK: - Groups

    private var groupsSection: some View {
        sectionContainer(
            title: "Groups",
            count: app.computerList.groups.count,
            symbol: "folder",
            trailing: AnyView(newGroupButton)
        ) {
            Group {
                if app.computerList.groups.isEmpty {
                    HStack {
                        Label("Create groups for clients, sites, labs, or environments.", systemImage: "folder.badge.plus")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(16)
                    .background(panelBackground)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(app.computerList.groups.sorted { $0.sortOrder < $1.sortOrder }) { group in
                            GroupLibraryRow(
                                group: group,
                                savedConnections: app.savedConnections.connections(in: group.id),
                                onConnect: onConnectSaved,
                                onEdit: { editingGroup = ConnectionGroupEditorDraft(group: group) },
                                onDelete: {
                                    app.savedConnections.removeGroupReferences(group.id)
                                    app.computerList.removeGroup(group.id)
                                },
                                onEditConnection: { saved in
                                    editingSavedConnection = SavedConnectionEditorDraft(saved: saved)
                                },
                                onShowConnection: { saved in
                                    selectedSavedConnection = saved
                                }
                            )
                        }
                    }
                    .padding(16)
                    .background(panelBackground)
                }
            }
        }
    }

    private var newGroupButton: some View {
        Button {
            editingGroup = ConnectionGroupEditorDraft()
        } label: {
            Label("New Group", systemImage: "folder.badge.plus")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    private var manualConnectSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New Connection")
                    .font(.title3.bold())
                Spacer()
                Button {
                    showManualSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            Divider()
            ScrollView {
                ManualConnectView(
                    onConnectWithWake: { host, port, proto, wakeMAC in
                        showManualSheet = false
                        onManualConnect(host, port, proto, wakeMAC)
                    },
                    onImportRDP: { profile in
                        showManualSheet = false
                        onImportRDP(profile)
                    }
                )
                .padding(20)
            }
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 480, idealHeight: 600)
    }

    // MARK: - Floating Action Button (iOS)

    #if os(iOS)
    private var quickConnectFAB: some View {
        Button {
            showManualSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                Text("Connect")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            )
            .shadow(color: Color.accentColor.opacity(0.45), radius: 16, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Footer

    private var infoFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Bonjour discovers devices on your local network.", systemImage: "network")
            Label("Tailscale or a VPN lets you reach devices remotely.", systemImage: "lock.shield")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .opacity(0.85)
    }

    // MARK: - Section container helper

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        count: Int?,
        symbol: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Capsule())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    // MARK: - Card grid

    @ViewBuilder
    private func cardGrid(_ items: [SavedConnection], large: Bool) -> some View {
        let columns = large ? largeColumns : smallColumns
        LazyVGrid(columns: columns, alignment: .leading, spacing: large ? 18 : 20) {
            ForEach(items) { saved in
                Button {
                    onConnectSaved(saved)
                } label: {
                    SavedConnectionCard(
                        saved: saved,
                        large: large,
                        isBookmark: saved.isBookmark,
                        onToggleBookmark: {
                            app.savedConnections.toggleBookmark(saved.id)
                        }
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        onConnectSaved(saved)
                    } label: {
                        Label("Connect", systemImage: "play.fill")
                    }
                    Button {
                        selectedSavedConnection = saved
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    Button {
                        editingSavedConnection = SavedConnectionEditorDraft(saved: saved)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button {
                        app.savedConnections.toggleBookmark(saved.id)
                    } label: {
                        Label(saved.isBookmark ? "Remove from Saved" : "Save", systemImage: saved.isBookmark ? "star.slash" : "star")
                    }
                    Menu {
                        ForEach(app.computerList.groups) { group in
                            Button {
                                toggle(saved, in: group)
                            } label: {
                                Label(group.name, systemImage: saved.groupIDs.contains(group.id) ? "checkmark.circle.fill" : group.icon)
                            }
                        }
                    } label: {
                        Label("Groups", systemImage: "folder")
                    }
                    Button {
                        copyQuickLink(saved.quickConnectURLString)
                    } label: {
                        Label("Copy Quick Link", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button {
                        app.savedConnections.remove(saved.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.top, 2)
    }

    private var largeColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: 18, alignment: .top)]
    }

    private var smallColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 210), spacing: 20, alignment: .top)]
    }

    // MARK: - Library actions

    private func connectQuickLink(saveFirst: Bool) {
        let resolution = QuickConnectParser.resolve(quickConnectText, defaultProtocol: quickConnectProtocol)
        guard case .target(let target) = resolution else {
            switch resolution {
            case .unsupported(let unsupported):
                quickConnectError = unsupported.message
            case .invalid(let message):
                quickConnectError = message
            case .target:
                break
            }
            return
        }
        quickConnectError = nil
        if saveFirst {
            app.savedConnections.addOrUpdate(
                host: target.host,
                port: target.port,
                displayName: target.displayName,
                connectionProtocol: target.connectionProtocol,
                source: .quickConnect,
                isBookmark: true
            )
        }
        onManualConnect(target.host, target.port, target.connectionProtocol, nil)
    }

    private func saveTailnetDevice(_ device: TailnetDevice, bookmark: Bool) {
        guard let host = device.connectionHost else { return }
        app.savedConnections.addOrUpdate(
            host: host,
            port: device.recommendedProtocol.defaultPort,
            displayName: device.displayName,
            connectionProtocol: device.recommendedProtocol,
            source: .tailnet,
            isBookmark: bookmark
        )
    }

    private func connect(_ detail: NearbyHostDetail) {
        switch detail.connectionProtocol {
        case .screenQ:
            onConnectDiscovered(detail.host)
        case .macScreenSharing, .vnc:
            onConnectRFB(detail.host)
        case .rdp:
            break
        }
    }

    private func groups(for saved: SavedConnection) -> [ComputerGroup] {
        app.computerList.groups.filter { saved.groupIDs.contains($0.id) }
    }

    private func toggle(_ saved: SavedConnection, in group: ComputerGroup) {
        var groupIDs = saved.groupIDs
        if groupIDs.contains(group.id) {
            groupIDs.removeAll { $0 == group.id }
        } else {
            groupIDs.append(group.id)
        }
        app.savedConnections.assign(saved.id, to: groupIDs)
    }

    private func copyQuickLink(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = value
        #endif
    }

    // MARK: - Misc styling

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Welcome back"
        }
    }

    private var networkStatusColor: Color {
        if app.browserStatus.isBrowsing { return .green }
        return .orange
    }

    private var networkStatusText: String {
        if app.browserStatus.isBrowsing {
            let n = app.discoveredHosts.count + app.discoveredRFBHosts.count
            return n > 0 ? "Live discovery — \(n) device\(n == 1 ? "" : "s") nearby" : "Listening on local network…"
        }
        return "Discovery paused"
    }

    private var horizontalPadding: CGFloat {
        #if os(macOS)
        return 30
        #else
        return 20
        #endif
    }

    private var panelFill: Color {
        Color.primary.opacity(0.04)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(panelFill)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.05),
                Color.clear,
                Color.accentColor.opacity(0.02)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Active session card

private struct ActiveSessionCard: View {
    let slot: ViewerSessionSlot
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 240, height: 130)
                    .overlay(
                        Image(systemName: slot.systemImage)
                            .font(.system(size: 44, weight: .light))
                            .foregroundColor(.white.opacity(0.8))
                    )

                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("LIVE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(10)
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slot.label)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(protocolLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
            }
            .frame(width: 240)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.4), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var protocolLabel: String {
        switch slot.kind {
        case .screenQ:  return "Screen Q"
        case .vnc(let s): return s.profile.displayName
        case .rdp:      return "RDP"
        }
    }

    private var gradientColors: [Color] {
        switch slot.kind {
        case .screenQ:  return [.orange, .pink]
        case .vnc:      return [.blue, .purple]
        case .rdp:      return [Color(red: 0.20, green: 0.65, blue: 0.70), .blue]
        }
    }
}

// MARK: - Saved-connection card

private struct SavedConnectionCard: View {
    let saved: SavedConnection
    let large: Bool
    let isBookmark: Bool
    let onToggleBookmark: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(height: large ? 150 : 110)
                    .frame(maxWidth: .infinity)
                    .clipped()

                ZStack(alignment: .topLeading) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.multiply)

                    HStack {
                        protocolPill
                        Spacer()
                        Button(action: onToggleBookmark) {
                            Image(systemName: isBookmark ? "star.fill" : "star")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isBookmark ? .yellow : .white.opacity(0.85))
                                .frame(width: 28, height: 28)
                                .background(Color.black.opacity(0.35))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                }
                .allowsHitTesting(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(saved.displayName)
                    .font(.system(size: large ? 15 : 13, weight: .semibold))
                    .lineLimit(1)
                Text(saved.address)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !large {
                    Text(timeAgoString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, large ? 10 : 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.20 : 0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .zIndex(isHovered ? 1 : 0)
        .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.0), radius: isHovered ? 14 : 0, x: 0, y: isHovered ? 6 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = saved.thumbnailData,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: protocolIcon)
                    .font(.system(size: large ? 56 : 40, weight: .light))
                    .foregroundColor(.white.opacity(0.78))
            }
        }
    }

    private var protocolPill: some View {
        HStack(spacing: 4) {
            Image(systemName: protocolIcon)
                .font(.system(size: 10, weight: .bold))
            Text(saved.resolvedProtocol.displayName)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
        .frame(maxWidth: large ? 170 : 145, alignment: .leading)
    }

    private var protocolIcon: String {
        switch saved.resolvedProtocol {
        case .screenQ:          return "display"
        case .macScreenSharing: return "macwindow"
        case .vnc:              return "rectangle.on.rectangle"
        case .rdp:              return "pc"
        }
    }

    private var gradientColors: [Color] {
        switch saved.resolvedProtocol {
        case .screenQ:          return [Color(red: 1.00, green: 0.45, blue: 0.30), Color(red: 0.95, green: 0.20, blue: 0.45)]
        case .macScreenSharing: return [Color(red: 0.30, green: 0.55, blue: 0.95), Color(red: 0.50, green: 0.35, blue: 0.85)]
        case .vnc:              return [Color(red: 0.55, green: 0.30, blue: 0.85), Color(red: 0.80, green: 0.30, blue: 0.65)]
        case .rdp:              return [Color(red: 0.20, green: 0.65, blue: 0.70), Color(red: 0.25, green: 0.45, blue: 0.85)]
        }
    }

    private var timeAgoString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: saved.lastConnected, relativeTo: Date())
    }
}

// MARK: - Library rows

private struct TailnetLibraryRow: View {
    let device: TailnetDevice
    var onConnect: (RemoteConnectionProtocol) -> Void
    var onDetails: () -> Void
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(device.statusText, systemImage: device.isOnline == false ? "circle" : "circle.fill")
                        .foregroundColor(device.isOnline == false ? .secondary : .green)
                    Text(device.connectionHost ?? "No tailnet address")
                        .foregroundColor(.secondary)
                    Label(device.recommendedProtocol.displayName, systemImage: device.recommendedProtocol.systemImage)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }
            Spacer()
            Menu {
                Button { onConnect(device.recommendedProtocol) } label: {
                    Label("Best Available", systemImage: device.recommendedProtocol.systemImage)
                }
                ForEach(RemoteConnectionProtocol.allCases, id: \.self) { connectionProtocol in
                    Button { onConnect(connectionProtocol) } label: {
                        Label(connectionProtocol.displayName, systemImage: connectionProtocol.systemImage)
                    }
                }
                Divider()
                Button { onDetails() } label: {
                    Label("Details", systemImage: "info.circle")
                }
                Button { onSave() } label: {
                    Label("Save", systemImage: "star")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .disabled(device.connectionHost == nil)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button { onConnect(device.recommendedProtocol) } label: {
                Label("Connect", systemImage: "play.fill")
            }
            Button { onDetails() } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button { onSave() } label: {
                Label("Save", systemImage: "star")
            }
        }
    }
}

private struct GroupLibraryRow: View {
    let group: ComputerGroup
    let savedConnections: [SavedConnection]
    var onConnect: (SavedConnection) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onEditConnection: (SavedConnection) -> Void
    var onShowConnection: (SavedConnection) -> Void

    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if savedConnections.isEmpty {
                Text("No saved connections in this group.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(savedConnections) { saved in
                        GroupConnectionRow(
                            saved: saved,
                            onConnect: { onConnect(saved) },
                            onDetails: { onShowConnection(saved) },
                            onEdit: { onEditConnection(saved) }
                        )
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 18)
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(savedConnections.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit Group", systemImage: "pencil")
            }
            Button { onDelete() } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct GroupConnectionRow: View {
    let saved: SavedConnection
    var onConnect: () -> Void
    var onDetails: () -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: saved.resolvedProtocol.systemImage)
                .foregroundColor(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(saved.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(saved.address)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onConnect) {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contextMenu {
            Button { onConnect() } label: {
                Label("Connect", systemImage: "play.fill")
            }
            Button { onDetails() } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
    }
}

// MARK: - Detail and edit sheets

private struct SavedConnectionEditorDraft: Identifiable {
    let id: UUID
    var saved: SavedConnection

    init(saved: SavedConnection) {
        id = saved.id
        self.saved = saved
    }
}

private struct SavedConnectionEditorSheet: View {
    let groups: [ComputerGroup]
    var onCancel: () -> Void
    var onSave: (SavedConnection) -> Void

    @State private var saved: SavedConnection
    @State private var portText: String
    @State private var selectedGroupIDs: Set<UUID>
    @State private var validationMessage: String?

    init(
        draft: SavedConnectionEditorDraft,
        groups: [ComputerGroup],
        onCancel: @escaping () -> Void,
        onSave: @escaping (SavedConnection) -> Void
    ) {
        self.groups = groups
        self.onCancel = onCancel
        self.onSave = onSave
        _saved = State(initialValue: draft.saved)
        _portText = State(initialValue: String(draft.saved.port))
        _selectedGroupIDs = State(initialValue: Set(draft.saved.groupIDs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(title: "Edit Connection", systemImage: saved.resolvedProtocol.systemImage)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Display name", text: $saved.displayName)
                TextField("Host or IP", text: $saved.host)
                HStack {
                    Picker("Protocol", selection: protocolBinding) {
                        ForEach(RemoteConnectionProtocol.allCases, id: \.self) { connectionProtocol in
                            Label(connectionProtocol.displayName, systemImage: connectionProtocol.systemImage)
                                .tag(connectionProtocol)
                        }
                    }
                    TextField("Port", text: $portText)
                        .frame(width: 92)
                }
                TextField("Wake MAC address", text: wakeBinding)
                Toggle("Saved", isOn: $saved.isBookmark)
                if !groups.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Groups")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        ForEach(groups) { group in
                            Toggle(group.name, isOn: groupBinding(group.id))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    TextEditor(text: $saved.notes)
                        .frame(height: 86)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }
            }
            .textFieldStyle(.roundedBorder)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") {
                    save()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480)
    }

    private var protocolBinding: Binding<RemoteConnectionProtocol> {
        Binding(
            get: { saved.resolvedProtocol },
            set: { newValue in
                saved.connectionProtocol = newValue
                if portText == String(saved.port) || portText.isEmpty {
                    portText = String(newValue.defaultPort)
                }
            }
        )
    }

    private var wakeBinding: Binding<String> {
        Binding(
            get: { saved.wakeMACAddress ?? "" },
            set: { saved.wakeMACAddress = $0 }
        )
    }

    private func groupBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedGroupIDs.contains(id) },
            set: { enabled in
                if enabled {
                    selectedGroupIDs.insert(id)
                } else {
                    selectedGroupIDs.remove(id)
                }
            }
        )
    }

    private func save() {
        guard let port = UInt16(portText) else {
            validationMessage = "Port must be between 0 and 65535."
            return
        }
        var updated = saved
        updated.port = port
        updated.groupIDs = Array(selectedGroupIDs)
        onSave(updated)
    }
}

private struct SavedConnectionDetailSheet: View {
    let saved: SavedConnection
    let groups: [ComputerGroup]
    var onConnect: () -> Void
    var onEdit: () -> Void
    var onCopyLink: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(title: saved.displayName, systemImage: saved.resolvedProtocol.systemImage)
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Address", saved.address)
                detailRow("Protocol", saved.resolvedProtocol.displayName)
                detailRow("Source", saved.sourceLabel)
                detailRow("Quick link", saved.quickConnectURLString)
                if !groups.isEmpty {
                    detailRow("Groups", groups.map(\.name).joined(separator: ", "))
                }
                if !saved.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(saved.notes)
                        .font(.body)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            HStack {
                Button("Delete", action: onDelete)
                    .foregroundColor(.red)
                Spacer()
                Button("Copy Link", action: onCopyLink)
                Button("Edit", action: onEdit)
                Button("Connect", action: onConnect)
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 500)
    }
}

private struct NearbyHostDetail: Identifiable {
    var host: DiscoveredHost
    var connectionProtocol: RemoteConnectionProtocol
    var id: String { "\(connectionProtocol.rawValue):\(host.id)" }
}

private struct NearbyHostDetailSheet: View {
    let detail: NearbyHostDetail
    var onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(title: detail.host.displayName, systemImage: detail.connectionProtocol.systemImage)
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Protocol", detail.connectionProtocol.displayName)
                detailRow("Bonjour identity", detail.host.id)
                detailRow("Endpoint", detail.host.endpointDescription)
                if let version = detail.host.advertisedAppVersion {
                    detailRow("App version", version)
                }
                if let platform = detail.host.advertisedPlatform {
                    detailRow("Platform", platform)
                }
                detailRow("Control", detail.host.advertisesControl ? "Available" : "View only")
            }
            HStack {
                Spacer()
                Button("Connect", action: onConnect)
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 540)
    }
}

private struct TailnetDeviceDetailSheet: View {
    let device: TailnetDevice
    var onConnect: (RemoteConnectionProtocol) -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(title: device.displayName, systemImage: device.symbolName)
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Status", device.statusText)
                detailRow("Host", device.connectionHost ?? "Unavailable")
                detailRow("Recommended", device.recommendedProtocol.displayName)
                if let os = device.os {
                    detailRow("OS", os)
                }
                if !device.addresses.isEmpty {
                    detailRow("Addresses", device.addresses.joined(separator: ", "))
                }
                if !device.tags.isEmpty {
                    detailRow("Tags", device.tags.joined(separator: ", "))
                }
            }
            HStack {
                Button("Save", action: onSave)
                Spacer()
                Menu("Connect") {
                    Button { onConnect(device.recommendedProtocol) } label: {
                        Label("Best Available", systemImage: device.recommendedProtocol.systemImage)
                    }
                    ForEach(RemoteConnectionProtocol.allCases, id: \.self) { connectionProtocol in
                        Button { onConnect(connectionProtocol) } label: {
                            Label(connectionProtocol.displayName, systemImage: connectionProtocol.systemImage)
                        }
                    }
                }
                .disabled(device.connectionHost == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 520)
    }
}

private struct ConnectionGroupEditorDraft: Identifiable {
    let id: UUID
    var name: String
    var icon: String
    var sortOrder: Int

    init(group: ComputerGroup? = nil) {
        id = group?.id ?? UUID()
        name = group?.name ?? ""
        icon = group?.icon ?? "folder"
        sortOrder = group?.sortOrder ?? 0
    }
}

private struct ConnectionGroupEditorSheet: View {
    @State var draft: ConnectionGroupEditorDraft
    var onCancel: () -> Void
    var onSave: (ComputerGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(title: draft.name.isEmpty ? "New Group" : "Edit Group", systemImage: draft.icon)
            TextField("Group name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            TextField("SF Symbol", text: $draft.icon)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") {
                    onSave(ComputerGroup(id: draft.id, name: draft.name, icon: draft.icon, sortOrder: draft.sortOrder))
                }
                .buttonStyle(.bordered)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 340, idealWidth: 380)
    }
}

private func sheetHeader(title: String, systemImage: String) -> some View {
    HStack(spacing: 10) {
        Image(systemName: systemImage)
            .foregroundColor(.accentColor)
        Text(title)
            .font(.title3.bold())
            .lineLimit(1)
        Spacer()
    }
}

private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(label)
            .font(.caption.bold())
            .foregroundColor(.secondary)
            .frame(width: 110, alignment: .leading)
        Text(value)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
