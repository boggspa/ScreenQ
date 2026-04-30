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

struct ConnectionHubView: View {

    @EnvironmentObject private var app: AppState
    @ObservedObject var sessionStore: ViewerSessionStore

    var onConnectDiscovered: (DiscoveredHost) -> Void
    var onConnectRFB: (DiscoveredHost) -> Void
    var onConnectTailnet: (TailnetDevice, RemoteConnectionProtocol) -> Void
    var onConnectSaved: (SavedConnection) -> Void
    var onManualConnect: (String, UInt16, RemoteConnectionProtocol) -> Void
    var onImportRDP: (RDPConnectionProfile) -> Void

    @State private var showManualSheet = false
    @State private var selectedSavedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroHeader
                if !sessionStore.sessions.isEmpty {
                    activeSessionsSection
                }
                bookmarksSection
                recentsSection
                discoveredSection
                #if os(macOS)
                manualConnectInline
                #endif
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

    // MARK: - Bookmarks

    private var bookmarksSection: some View {
        let bookmarks = app.savedConnections.connections.filter(\.isBookmark)
        return Group {
            if !bookmarks.isEmpty {
                sectionContainer(
                    title: "Favourites",
                    count: bookmarks.count,
                    symbol: "star.fill"
                ) {
                    cardGrid(bookmarks, large: true)
                }
            }
        }
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

    // MARK: - Discovered

    private var discoveredSection: some View {
        sectionContainer(
            title: "On Your Network",
            count: app.discoveredHosts.count + app.discoveredRFBHosts.count,
            symbol: "antenna.radiowaves.left.and.right",
            trailing: AnyView(rescanButton)
        ) {
            DiscoveryView(
                onSelect: onConnectDiscovered,
                onSelectRFB: onConnectRFB,
                onSelectTailnet: onConnectTailnet
            )
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
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

    // MARK: - Manual connect

    #if os(macOS)
    private var manualConnectInline: some View {
        sectionContainer(
            title: "Manual Connection",
            count: nil,
            symbol: "keyboard"
        ) {
            ManualConnectView(
                onConnect: onManualConnect,
                onImportRDP: onImportRDP
            )
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }
    #endif

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
                    onConnect: { host, port, proto in
                        showManualSheet = false
                        onManualConnect(host, port, proto)
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
        LazyVGrid(columns: columns, spacing: 14) {
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
            }
        }
    }

    private var largeColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 14)]
    }

    private var smallColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]
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
        .scaleEffect(isHovered ? 1.02 : 1.0)
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
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
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
