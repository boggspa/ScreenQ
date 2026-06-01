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
import Combine
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
    var onImportRDP: (RDPConnectionProfile, String?) -> Void

    @State private var showManualSheet = false
    @State private var selectedSavedConnection: SavedConnection?
    @State private var editingSavedConnection: SavedConnectionEditorDraft?
    @State private var selectedNearbyHost: NearbyHostDetail?
    @State private var selectedTailnetDevice: TailnetDevice?
    @State private var editingGroup: ConnectionGroupEditorDraft?
    @State private var showTailnetSetupSheet = false
    @State private var manualInitialProtocol: RemoteConnectionProtocol = .screenQ
    @State private var manualLaunchRDPImporter = false
    @State private var quickConnectText = ""
    @State private var quickConnectProtocol: RemoteConnectionProtocol = .screenQ
    @State private var quickConnectError: String?
    @State private var isRescanning = false
    #if os(iOS)
    @State private var showQRScanner = false
    #endif

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
        .sheet(
            isPresented: $showManualSheet,
            onDismiss: {
                manualInitialProtocol = .screenQ
                manualLaunchRDPImporter = false
            }
        ) {
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
        .onAppear {
            if let action = app.consumePendingConnectionHubStartupAction() {
                consumeStartupAction(action)
            }
        }
        .onReceive(app.$pendingConnectionHubStartupAction.compactMap { $0 }) { _ in
            if let action = app.consumePendingConnectionHubStartupAction() {
                consumeStartupAction(action)
            }
        }
        #if os(iOS)
        .overlay(
            quickConnectFAB.padding(20),
            alignment: .bottomTrailing
        )
        .sheet(isPresented: $showQRScanner) {
            QRScanSheet(
                onResult: { url in
                    showQRScanner = false
                    app.handleExternalURL(url)
                },
                onCancel: { showQRScanner = false }
            )
        }
        #endif
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ScreenQBrandMark(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeOfDayGreeting)
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text("Pick a screen.")
                        .font(.sqDisplay)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                #if os(macOS)
                Button {
                    showManualSheet = true
                } label: {
                    Label("New Connection", systemImage: "plus.circle.fill")
                        .font(.sqHeadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(ScreenQTheme.cosmicCyan.opacity(0.18))
                        )
                        .overlay(
                            Capsule().stroke(ScreenQTheme.cosmicCyan.opacity(0.45), lineWidth: 1)
                        )
                        .foregroundColor(ScreenQTheme.cosmicCyan)
                }
                .buttonStyle(.plain)
                #endif
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    LiveStatusDot(color: networkStatus.tint, active: app.browserStatus.isBrowsing)
                    Text(networkStatusText)
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                SQPill(text: networkStatusPillText, status: networkStatus)
                SQPill(text: "End-to-end encrypted", status: .healthy)
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
        return sectionContainer(
            title: "Saved",
            count: bookmarks.isEmpty ? nil : bookmarks.count,
            symbol: "star.fill"
        ) {
            if bookmarks.isEmpty {
                SQEmptyState(
                    icon: "rectangle.connected.to.line.below",
                    title: "No saved connections yet",
                    message: "Connect to a Mac, PC, or Tailscale device and save it for one-tap access.",
                    tint: ScreenQTheme.cosmicCyan,
                    primary: .init("Quick Connect", systemImage: "bolt.fill") {
                        SQHaptics.tap()
                        showManualSheet = true
                    },
                    secondary: .init("Scan nearby", systemImage: "antenna.radiowaves.left.and.right") {
                        SQHaptics.tap()
                        isRescanning = true
                        Task {
                            await app.bonjourBrowser.start()
                            await MainActor.run { isRescanning = false }
                        }
                    }
                )
                .screenQCard(tint: ScreenQTheme.cosmicCyan)
            } else {
                cardGrid(bookmarks, large: true)
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
                    #if os(iOS)
                    qrScanButton
                    #endif

                    Menu {
                        ForEach(RemoteConnectionProtocol.allCases, id: \.self) { connectionProtocol in
                            Button {
                                SQHaptics.tap()
                                quickConnectProtocol = connectionProtocol
                            } label: {
                                Label(connectionProtocol.displayName, systemImage: connectionProtocol.systemImage)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            quickConnectProtocolMark
                            Text(quickConnectProtocol.displayName)
                        }
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
                        SQHaptics.tap()
                        connectQuickLink(saveFirst: false)
                    } label: {
                        Label("Connect", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(quickConnectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        SQHaptics.tap()
                        connectQuickLink(saveFirst: true)
                    } label: {
                        Label("Save", systemImage: "star")
                    }
                    .buttonStyle(.bordered)
                    .disabled(quickConnectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let reachability = reachabilityPill {
                    HStack(spacing: 6) {
                        SQPill(text: reachability.text, status: reachability.status, compact: true)
                        Spacer(minLength: 0)
                    }
                }

                if let quickConnectError {
                    SQErrorRecovery(
                        title: "Couldn't connect",
                        message: quickConnectError,
                        retryTitle: "Try again",
                        onRetry: {
                            SQHaptics.tap()
                            connectQuickLink(saveFirst: false)
                        }
                    )
                }

                let quickLinks = app.savedConnections.connections.filter(\.isBookmark).prefix(8)
                if !quickLinks.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(quickLinks)) { saved in
                                Button {
                                    SQHaptics.tap()
                                    copyQuickLink(saved.quickConnectURLString)
                                } label: {
                                    Label(saved.quickConnectURLString, systemImage: "link")
                                        .font(.sqCaption)
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
            SQHaptics.tap()
            showManualSheet = true
        } label: {
            Label("New / Import", systemImage: "plus")
                .font(.sqCaption)
        }
        .buttonStyle(.plain)
        .foregroundColor(ScreenQTheme.cosmicCyan)
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
        Button {
            SQHaptics.bump()
            app.savedConnections.clearRecents()
        } label: {
            Text("Clear all")
                .font(.sqCaption)
                .foregroundColor(ScreenQTheme.cosmicRose)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Nearby

    private var nearbySection: some View {
        let total = app.discoveredHosts.count + app.discoveredRFBHosts.count
        return sectionContainer(
            title: "Nearby",
            count: total,
            symbol: "antenna.radiowaves.left.and.right",
            trailing: AnyView(rescanButton)
        ) {
            Group {
                if total == 0 && !isRescanning {
                    SQEmptyState(
                        icon: "wifi.exclamationmark",
                        title: "No Macs found on this network",
                        message: "Make sure both devices are on the same Wi-Fi.",
                        tint: ScreenQTheme.cosmicTeal,
                        primary: .init("Rescan", systemImage: "arrow.clockwise") {
                            SQHaptics.tap()
                            isRescanning = true
                            Task {
                                await app.bonjourBrowser.start()
                                await MainActor.run { isRescanning = false }
                            }
                        },
                        compact: true
                    )
                    .screenQCard(tint: ScreenQTheme.cosmicTeal)
                } else {
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
            .overlay(
                Group {
                    if isRescanning {
                        SQLoadingScrim(title: "Scanning…", subtitle: "Listening on your local network", tint: .white)
                            .clipShape(RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous))
                    }
                }
            )
        }
    }

    private var rescanButton: some View {
        Button {
            SQHaptics.tap()
            isRescanning = true
            Task {
                await app.bonjourBrowser.start()
                await MainActor.run { isRescanning = false }
            }
        } label: {
            Label("Rescan", systemImage: "arrow.clockwise")
                .font(.sqCaption)
        }
        .buttonStyle(.plain)
        .foregroundColor(ScreenQTheme.cosmicCyan)
    }

    // MARK: - Tailnet

    private var tailnetLibrarySection: some View {
        sectionContainer(
            title: "Tailnet",
            count: app.tailnetDevices.count,
            symbol: "lock.shield",
            trailing: AnyView(tailnetRefreshButton)
        ) {
            if !app.tailnetAuthConfigured {
                SQEmptyState(
                    icon: "network",
                    title: "Tailscale not configured",
                    message: "Connect across networks with end-to-end encryption.",
                    tint: ScreenQTheme.cosmicMint,
                    primary: .init("Set up Tailscale", systemImage: "arrow.right") {
                        SQHaptics.tap()
                        showTailnetSetupSheet = true
                    },
                    compact: true
                )
                .screenQCard(tint: ScreenQTheme.cosmicMint)
            } else if app.tailnetDevices.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(app.tailnetDiscoveryStatus.summary, systemImage: "magnifyingglass")
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .padding(16)
                .background(panelBackground)
            } else {
                VStack(alignment: .leading, spacing: 10) {
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
                .padding(16)
                .background(panelBackground)
            }
        }
    }

    private var tailnetRefreshButton: some View {
        Button {
            SQHaptics.tap()
            Task { await app.refreshTailnetDevices() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
                .font(.sqCaption)
        }
        .buttonStyle(.plain)
        .foregroundColor(ScreenQTheme.cosmicCyan)
    }

    private var tailnetSetupSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tailnet")
                    .font(.sqTitle)
                Spacer()
                Button {
                    SQHaptics.tap()
                    showTailnetSetupSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.sqTitle)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
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
                    SQEmptyState(
                        icon: "folder.badge.plus",
                        title: "No groups yet",
                        message: "Create groups for clients, sites, labs, or environments.",
                        tint: ScreenQTheme.cosmicViolet,
                        primary: .init("Add group", systemImage: "plus") {
                            SQHaptics.tap()
                            editingGroup = ConnectionGroupEditorDraft()
                        },
                        compact: true
                    )
                    .screenQCard(tint: ScreenQTheme.cosmicViolet)
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
            SQHaptics.tap()
            editingGroup = ConnectionGroupEditorDraft()
        } label: {
            Label("Add group", systemImage: "folder.badge.plus")
                .font(.sqCaption)
        }
        .buttonStyle(.plain)
        .foregroundColor(ScreenQTheme.cosmicCyan)
    }

    private var manualConnectSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New Connection")
                    .font(.sqTitle)
                Spacer()
                Button {
                    SQHaptics.tap()
                    showManualSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.sqTitle)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(20)
            Divider()
            ScrollView {
                ManualConnectView(
                    initialProtocol: manualInitialProtocol,
                    launchRDPImporter: manualLaunchRDPImporter,
                    onConnectWithWake: { host, port, proto, wakeMAC in
                        showManualSheet = false
                        onManualConnect(host, port, proto, wakeMAC)
                    },
                    onImportRDP: { profile, wakeMAC in
                        showManualSheet = false
                        onImportRDP(profile, wakeMAC)
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
            SQHaptics.tap()
            showManualSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityHidden(true)
                Text("Connect")
                    .font(.sqHeadline)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(ScreenQTheme.accent(ScreenQTheme.cosmicCyan))
            )
            .shadow(color: ScreenQTheme.cosmicCyan.opacity(0.45), radius: 16, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New connection")
    }

    private var qrScanButton: some View {
        Button {
            SQHaptics.tap()
            showQRScanner = true
        } label: {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundColor(ScreenQTheme.cosmicCyan)
                .background(Circle().fill(ScreenQTheme.cosmicCyan.opacity(0.15)))
                .overlay(
                    Circle().stroke(ScreenQTheme.cosmicCyan.opacity(0.45), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan QR code")
    }
    #endif

    // MARK: - Reachability hint (Quick Connect)

    private struct ReachabilityHint {
        let text: String
        let status: SQStatus
    }

    private var reachabilityPill: ReachabilityHint? {
        let trimmed = quickConnectText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let candidates = app.discoveredHosts + app.discoveredRFBHosts
        let match = candidates.first { host in
            let displayName = host.displayName.lowercased()
            if displayName == trimmed { return true }
            // Bonjour names commonly arrive with a ".local" suffix in DNS.
            if displayName + ".local" == trimmed { return true }
            if displayName == trimmed.replacingOccurrences(of: ".local", with: "") { return true }
            if host.endpointDescription.lowercased().contains(trimmed) { return true }
            return false
        }
        guard let match else { return nil }
        return ReachabilityHint(
            text: "On this network — \(match.displayName)",
            status: .info
        )
    }

    // MARK: - Footer

    private var infoFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            iCloudSyncFooterRow
            VStack(alignment: .leading, spacing: 6) {
                Label("Bonjour discovers devices on your local network.", systemImage: "network")
                Label("Tailscale or a VPN lets you reach devices remotely.", systemImage: "lock.shield")
            }
            .font(.sqCaption)
            .foregroundColor(.secondary)
            .opacity(0.85)
        }
    }

    private var iCloudSyncFooterRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SQPill(text: iCloudSyncPillText, status: iCloudSyncStatus)
                Spacer(minLength: 0)
                if let lastSync = iCloudSyncLastSyncText {
                    Text(lastSync)
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button {
                    SQHaptics.tap()
                    app.iCloudSync.syncNow(markPreferencesChanged: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                        .font(.sqCaption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundColor(.primary)
                        .background(
                            Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!app.iCloudSync.isEnabled || app.iCloudSync.status.phase == .syncing)
                Spacer(minLength: 0)
                Toggle("iCloud Sync", isOn: iCloudSyncEnabledBinding)
                    .font(.sqCallout)
                    #if os(macOS)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    #endif
            }
        }
        .padding(14)
        .screenQGlass()
    }

    private var iCloudSyncStatus: SQStatus {
        switch app.iCloudSync.status.phase {
        case .idle: return .healthy
        case .syncing: return .info
        case .disabled, .unavailable: return .muted
        case .error: return .error
        }
    }

    private var iCloudSyncPillText: String {
        switch app.iCloudSync.status.phase {
        case .idle: return "Synced"
        case .syncing: return "Syncing…"
        case .disabled: return "iCloud sync off"
        case .unavailable: return "iCloud unavailable"
        case .error: return "Sync error"
        }
    }

    private var iCloudSyncLastSyncText: String? {
        guard let date = app.iCloudSync.status.lastSyncedAt else { return nil }
        return "Last synced \(RelativeDateTimeFormatter.screenQShort.localizedString(for: date, relativeTo: Date()))"
    }

    private var iCloudSyncEnabledBinding: Binding<Bool> {
        Binding(
            get: { app.iCloudSync.isEnabled },
            set: { app.iCloudSync.isEnabled = $0 }
        )
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
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ScreenQTheme.cosmicCyan)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.sqCaption)
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

    private func consumeStartupAction(_ action: ConnectionHubStartupAction) {
        switch action {
        case .screenQManualConnect:
            manualInitialProtocol = .screenQ
            manualLaunchRDPImporter = false
            quickConnectProtocol = .screenQ
            showManualSheet = true
        case .tailnetSetup:
            showTailnetSetupSheet = true
            Task { await app.refreshTailnetDevices() }
        case .appleScreenSharing:
            manualInitialProtocol = .macScreenSharing
            manualLaunchRDPImporter = false
            quickConnectProtocol = .macScreenSharing
            showManualSheet = true
        case .importRDP:
            manualInitialProtocol = .rdp
            manualLaunchRDPImporter = true
            quickConnectProtocol = .rdp
            showManualSheet = true
        }
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

    private var networkStatus: SQStatus {
        app.browserStatus.isBrowsing ? .healthy : .attention
    }

    @ViewBuilder
    private var quickConnectProtocolMark: some View {
        if quickConnectProtocol == .screenQ {
            ScreenQLogoGlyph()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Image(systemName: quickConnectProtocol.systemImage)
                .accessibilityHidden(true)
        }
    }

    private var networkStatusText: String {
        if app.browserStatus.isBrowsing {
            let n = app.discoveredHosts.count + app.discoveredRFBHosts.count
            return n > 0 ? "Live discovery — \(n) device\(n == 1 ? "" : "s") nearby" : "Listening on local network…"
        }
        return "Discovery paused"
    }

    private var networkStatusPillText: String {
        app.browserStatus.isBrowsing ? "On this network" : "Discovery paused"
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
                ScreenQTheme.cosmicCyan.opacity(0.06),
                Color.clear,
                ScreenQTheme.cosmicViolet.opacity(0.04)
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
        Button(action: {
            SQHaptics.tap()
            onSelect()
        }) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 240, height: 130)
                    .overlay(
                        activeSessionMark
                    )

                    HStack(spacing: 6) {
                        LiveStatusDot(color: ScreenQTheme.cosmicMint, active: true)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                        Text("LIVE")
                            .font(.sqCaption)
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
                            .font(.sqHeadline)
                            .lineLimit(1)
                        Text(protocolLabel)
                            .font(.sqCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        SQHaptics.bump()
                        onClose()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Disconnect from session")
                }
                .padding(10)
            }
            .frame(width: 240)
            .clipShape(RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(ScreenQTheme.cosmicMint.opacity(0.5), lineWidth: 1.2)
            )
            .shadow(color: ScreenQTheme.cosmicMint.opacity(0.15), radius: 12, x: 0, y: 6)
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

    private var protocolTint: Color {
        switch slot.kind {
        case .screenQ:  return ScreenQTheme.cosmicCyan
        case .vnc:      return ScreenQTheme.cosmicTeal
        case .rdp:      return ScreenQTheme.cosmicAmber
        }
    }

    private var gradientColors: [Color] {
        switch slot.kind {
        case .screenQ:  return [ScreenQTheme.cosmicCyan, ScreenQTheme.cosmicViolet]
        case .vnc:      return [ScreenQTheme.cosmicTeal, ScreenQTheme.cosmicCyan]
        case .rdp:      return [ScreenQTheme.cosmicAmber, ScreenQTheme.cosmicRose]
        }
    }

    @ViewBuilder
    private var activeSessionMark: some View {
        switch slot.kind {
        case .screenQ:
            ScreenQLogoGlyph()
                .frame(width: 72, height: 72)
                .opacity(0.92)
                .accessibilityHidden(true)
        case .vnc, .rdp:
            Image(systemName: slot.systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.white.opacity(0.8))
                .accessibilityHidden(true)
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
    @State private var cachedThumbnailImage: CGImage? = nil

    /// Window during which a freshly captured thumbnail is badged "Live".
    private static let liveWindow: TimeInterval = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(height: large ? 150 : 110)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                ZStack(alignment: .topLeading) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.multiply)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 6) {
                            SQPill(text: saved.resolvedProtocol.displayName, status: .info, compact: true)
                                .frame(maxWidth: large ? 170 : 145, alignment: .leading)
                            if let freshness = thumbnailFreshness {
                                SQPill(text: freshness.text, status: freshness.status, compact: true)
                                    .accessibilityLabel(freshness.accessibilityLabel)
                            }
                        }
                        Spacer()
                        Button(action: {
                            SQHaptics.tap()
                            onToggleBookmark()
                        }) {
                            Image(systemName: isBookmark ? "star.fill" : "star")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isBookmark ? ScreenQTheme.cosmicAmber : .white.opacity(0.85))
                                .frame(width: 28, height: 28)
                                .background(Color.black.opacity(0.35))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isBookmark ? "Remove bookmark" : "Bookmark")
                    }
                    .padding(10)
                }
                .allowsHitTesting(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(saved.displayName)
                    .font(large ? .sqHeadline : .sqBody)
                    .lineLimit(1)
                Text(saved.address)
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !large {
                    Text(timeAgoString)
                        .font(.sqCaption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, large ? 10 : 8)
        }
        .screenQCard(tint: protocolTint, padding: 10)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .zIndex(isHovered ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .onAppear { loadCachedThumbnail() }
        .screenQOnChange(of: saved.thumbnailUpdatedAt) { _ in
            loadCachedThumbnail()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(saved.resolvedProtocol.displayName) connection: \(saved.displayName), \(saved.address)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = resolvedCGImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .saturation(thumbnailIsStale ? 0.0 : 1.0)
                .colorMultiply(thumbnailIsStale ? Color.gray.opacity(0.85) : .white)
        } else {
            ZStack {
                ScreenQTheme.accent(protocolTint)
                placeholderMark
            }
        }
    }

    @ViewBuilder
    private var placeholderMark: some View {
        if saved.resolvedProtocol == .screenQ {
            ScreenQBrandMark(
                size: large ? 74 : 58,
                cornerRadius: large ? 18 : 14,
                glyphScale: 0.72
            )
            .accessibilityHidden(true)
        } else {
            Image(systemName: protocolIcon)
                .font(.system(size: large ? 56 : 40, weight: .light))
                .foregroundColor(.white.opacity(0.78))
                .accessibilityHidden(true)
        }
    }

    /// Returns the CGImage to show, preferring the inline `thumbnailData`
    /// (always present alongside the timestamp) but falling back to the
    /// disk-backed `SavedConnectionThumbnailCache` when callers populate it
    /// directly.
    private var resolvedCGImage: CGImage? {
        if let data = saved.thumbnailData,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        return cachedThumbnailImage
    }

    /// Pull the disk-backed cache (if any) into a CGImage we can display.
    private func loadCachedThumbnail() {
        if saved.thumbnailData != nil {
            // Inline payload wins; no need to hit the disk cache.
            cachedThumbnailImage = nil
            return
        }
        guard let data = SavedConnectionThumbnailCache.shared.loadData(for: saved.id),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            cachedThumbnailImage = nil
            return
        }
        cachedThumbnailImage = image
    }

    private var thumbnailIsStale: Bool {
        guard resolvedCGImage != nil else { return false }
        guard let date = saved.thumbnailUpdatedAt else { return true }
        return Date().timeIntervalSince(date) >= Self.liveWindow
    }

    private struct Freshness {
        let text: String
        let status: SQStatus
        let accessibilityLabel: String
    }

    private var thumbnailFreshness: Freshness? {
        guard resolvedCGImage != nil else { return nil }
        guard let date = saved.thumbnailUpdatedAt else { return nil }
        let age = Date().timeIntervalSince(date)
        if age < Self.liveWindow {
            return Freshness(text: "Live", status: .healthy, accessibilityLabel: "Live preview")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return Freshness(text: relative, status: .muted, accessibilityLabel: "Thumbnail \(relative)")
    }

    private var protocolIcon: String {
        switch saved.resolvedProtocol {
        case .screenQ:          return "display"
        case .macScreenSharing: return "macwindow"
        case .vnc:              return "rectangle.on.rectangle"
        case .rdp:              return "pc"
        }
    }

    private var protocolTint: Color {
        switch saved.resolvedProtocol {
        case .screenQ:          return ScreenQTheme.cosmicCyan
        case .macScreenSharing: return ScreenQTheme.cosmicViolet
        case .vnc:              return ScreenQTheme.cosmicTeal
        case .rdp:              return ScreenQTheme.cosmicAmber
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

    private var onlineStatus: SQStatus {
        device.isOnline == false ? .muted : .healthy
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(ScreenQTheme.cosmicMint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.sqHeadline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        LiveStatusDot(color: onlineStatus.tint, active: device.isOnline == true)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                        Text(device.statusText)
                            .foregroundColor(onlineStatus.tint)
                    }
                    Text(device.connectionHost ?? "No tailnet address")
                        .foregroundColor(.secondary)
                    Label(device.recommendedProtocol.displayName, systemImage: device.recommendedProtocol.systemImage)
                        .foregroundColor(.secondary)
                }
                .font(.sqCaption)
            }
            Spacer()
            Menu {
                Button {
                    SQHaptics.tap()
                    onConnect(device.recommendedProtocol)
                } label: {
                    Label("Best Available", systemImage: device.recommendedProtocol.systemImage)
                }
                ForEach(RemoteConnectionProtocol.allCases, id: \.self) { connectionProtocol in
                    Button {
                        SQHaptics.tap()
                        onConnect(connectionProtocol)
                    } label: {
                        Label(connectionProtocol.displayName, systemImage: connectionProtocol.systemImage)
                    }
                }
                Divider()
                Button { onDetails() } label: {
                    Label("Details", systemImage: "info.circle")
                }
                Button {
                    SQHaptics.tap()
                    onSave()
                } label: {
                    Label("Save", systemImage: "star")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .disabled(device.connectionHost == nil)
            .accessibilityLabel("Actions")
        }
        .screenQCard(tint: ScreenQTheme.cosmicMint, padding: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tailnet device: \(device.displayName), \(device.statusText)")
        .contextMenu {
            Button {
                SQHaptics.tap()
                onConnect(device.recommendedProtocol)
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            Button { onDetails() } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button {
                SQHaptics.tap()
                onSave()
            } label: {
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
                    .font(.sqCaption)
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
                    .foregroundColor(ScreenQTheme.cosmicCyan)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(group.name)
                    .font(.sqHeadline)
                Text("\(savedConnections.count)")
                    .font(.sqCaption)
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
            Button {
                SQHaptics.bump()
                onDelete()
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
        .screenQCard(padding: 10)
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(saved.displayName)
                    .font(.sqCallout)
                    .lineLimit(1)
                Text(saved.address)
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: {
                SQHaptics.tap()
                onConnect()
            }) {
                Image(systemName: "play.circle")
                    .foregroundColor(ScreenQTheme.cosmicCyan)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connect to \(saved.displayName)")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(saved.resolvedProtocol.displayName) connection: \(saved.displayName), \(saved.address)")
        .contextMenu {
            Button {
                SQHaptics.tap()
                onConnect()
            } label: {
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
                            .font(.sqCaption)
                            .foregroundColor(.secondary)
                        ForEach(groups) { group in
                            Toggle(group.name, isOn: groupBinding(group.id))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.sqCaption)
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
                SQPill(text: validationMessage, status: .attention)
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
                        .font(.sqBody)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            HStack {
                Button("Delete") {
                    SQHaptics.bump()
                    onDelete()
                }
                .foregroundColor(ScreenQTheme.cosmicRose)
                Spacer()
                Button("Copy Link", action: onCopyLink)
                Button("Edit", action: onEdit)
                Button("Connect") {
                    SQHaptics.tap()
                    onConnect()
                }
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
            .foregroundColor(ScreenQTheme.cosmicCyan)
            .accessibilityHidden(true)
        Text(title)
            .font(.sqTitle)
            .lineLimit(1)
        Spacer()
    }
}

private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(label)
            .font(.sqCaption)
            .foregroundColor(.secondary)
            .frame(width: 110, alignment: .leading)
        Text(value)
            .font(.sqBody)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension RelativeDateTimeFormatter {
    static let screenQShort: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
