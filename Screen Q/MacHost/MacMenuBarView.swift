//
//  MacMenuBarView.swift
//  Screen Q
//
//  SwiftUI panel hosted inside the menu-bar status item's NSPopover.
//  Inspired by the Tailscale menu bar UX: searchable device list,
//  live session controls, and quick-connect actions.
//

#if os(macOS)
import SwiftUI
import AppKit

struct MacMenuBarView: View {

    @ObservedObject var app: AppState
    @ObservedObject var sessionStore: ViewerSessionStore

    var onOpenApp: () -> Void
    var onOpenRole: (DeviceRole) -> Void
    var onConnect: (PendingViewerConnection) -> Void
    var onSelectSession: (UUID) -> Void
    var onCloseSession: (UUID) -> Void
    var onConnectSaved: (SavedConnection) -> Void
    var onStopHosting: () -> Void
    var onRefresh: () -> Void
    var onToggleMenuBarOnly: () -> Void
    var onQuit: () -> Void

    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if app.macHost.isSharing { hostingSection }
                    if !sessionStore.sessions.isEmpty { activeSessionsSection }
                    if !filteredBookmarks.isEmpty { bookmarksSection }
                    if !filteredDiscovered.isEmpty || !filteredRFB.isEmpty { discoveredSection }
                    if !filteredTailnet.isEmpty { tailnetSection }
                    if !filteredRecents.isEmpty { recentsSection }
                    if isEmptyResults { emptyState }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .frame(width: 360, height: 540)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ScreenQBrandMark(size: 28, cornerRadius: 7, glyphScale: 0.72)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Q").font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Refresh devices")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search devices…", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
        .padding(12)
    }

    // MARK: - Sections

    private var hostingSection: some View {
        sectionHeader("Hosting", icon: "dot.radiowaves.left.and.right", color: .green) {
            VStack(alignment: .leading, spacing: 6) {
                row(
                    title: "This Mac is being shared",
                    subtitle: hostingSubtitle,
                    icon: "macwindow",
                    accent: .green,
                    trailing: stopHostingButton,
                    action: { onOpenRole(.hostMac) }
                )
            }
        }
    }

    private var activeSessionsSection: some View {
        sectionHeader("Active", icon: "play.circle.fill", color: .green, count: sessionStore.sessions.count) {
            VStack(spacing: 4) {
                ForEach(sessionStore.sessions) { slot in
                    HStack(spacing: 8) {
                        Image(systemName: slot.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Color.green.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slot.label)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text("Connected")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            onCloseSession(slot.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .help("Disconnect")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(rowBackground(highlight: sessionStore.selectedSessionID == slot.id))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectSession(slot.id)
                        onOpenApp()
                    }
                }
            }
        }
    }

    private var bookmarksSection: some View {
        sectionHeader("Favourites", icon: "star.fill", color: .yellow, count: filteredBookmarks.count) {
            ForEach(filteredBookmarks) { saved in
                row(
                    title: saved.displayName,
                    subtitle: "\(saved.resolvedProtocol.displayName) · \(saved.address)",
                    icon: protocolIcon(saved.resolvedProtocol),
                    accent: .yellow,
                    action: { onConnectSaved(saved) }
                )
            }
        }
    }

    private var discoveredSection: some View {
        sectionHeader(
            "On Network",
            icon: "antenna.radiowaves.left.and.right",
            color: .accentColor,
            count: filteredDiscovered.count + filteredRFB.count
        ) {
            ForEach(filteredDiscovered, id: \.id) { host in
                row(
                    title: host.displayName + (host.isIOSShareOnlyPresence ? " · view-only" : ""),
                    subtitle: "Screen Q",
                    icon: hostIcon(host),
                    accent: .accentColor,
                    action: { onConnect(.screenQ(host)) }
                )
            }
            ForEach(filteredRFB, id: \.id) { host in
                row(
                    title: host.displayName,
                    subtitle: "Mac Screen Sharing",
                    icon: "macwindow",
                    accent: .blue,
                    action: { onConnect(.macScreenSharing(host)) }
                )
            }
        }
    }

    private var tailnetSection: some View {
        sectionHeader("Tailnet", icon: "network", color: .purple, count: filteredTailnet.count) {
            ForEach(filteredTailnet) { device in
                if let host = device.connectionHost {
                    row(
                        title: device.displayName,
                        subtitle: "\(device.recommendedProtocol.displayName) · \(host)",
                        icon: device.symbolName,
                        accent: .purple,
                        action: {
                            onConnect(.manual(
                                host: host,
                                port: device.recommendedProtocol.defaultPort,
                                displayName: device.displayName,
                                connectionProtocol: device.recommendedProtocol
                            ))
                        }
                    )
                }
            }
        }
    }

    private var recentsSection: some View {
        sectionHeader("Recents", icon: "clock", color: .secondary, count: filteredRecents.count) {
            ForEach(filteredRecents.prefix(8)) { saved in
                row(
                    title: saved.displayName,
                    subtitle: "\(saved.resolvedProtocol.displayName) · \(saved.address)",
                    icon: protocolIcon(saved.resolvedProtocol),
                    accent: .secondary,
                    action: { onConnectSaved(saved) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(query.isEmpty ? "No devices yet" : "No matches for \"\(query)\"")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if query.isEmpty {
                Text("Searching local network…")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onOpenApp()
            } label: {
                Label("Open App", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                onToggleMenuBarOnly()
            } label: {
                Image(systemName: app.menuBarOnlyMode ? "menubar.dock.rectangle" : "menubar.rectangle")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(app.menuBarOnlyMode ? "Show Dock icon" : "Menu Bar only mode")

            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Quit Screen Q")
        }
        .padding(10)
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func sectionHeader<Content: View>(
        _ title: String,
        icon: String,
        color: Color,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundColor(color)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            content()
        }
    }

    @ViewBuilder
    private func row(
        title: String,
        subtitle: String,
        icon: String,
        accent: Color,
        trailing: AnyView? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundColor(accent == .secondary ? .primary : accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let trailing { trailing } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rowBackground(highlight: false))
        }
        .buttonStyle(HoverableRowButtonStyle())
    }

    private func rowBackground(highlight: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(highlight ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var stopHostingButton: AnyView {
        AnyView(
            Button {
                onStopHosting()
            } label: {
                Text("Stop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red))
            }
            .buttonStyle(.plain)
        )
    }

    // MARK: - Filtering

    private var filteredBookmarks: [SavedConnection] {
        filter(app.savedConnections.connections.filter(\.isBookmark))
    }

    private var filteredRecents: [SavedConnection] {
        filter(app.savedConnections.connections.filter { !$0.isBookmark })
    }

    private var filteredDiscovered: [DiscoveredHost] {
        if query.isEmpty { return Array(app.discoveredHosts.prefix(8)) }
        return app.discoveredHosts.filter { matches($0.displayName) }
    }

    private var filteredRFB: [DiscoveredHost] {
        if query.isEmpty { return Array(app.discoveredRFBHosts.prefix(6)) }
        return app.discoveredRFBHosts.filter { matches($0.displayName) }
    }

    private var filteredTailnet: [TailnetDevice] {
        if query.isEmpty { return Array(app.tailnetDevices.prefix(8)) }
        return app.tailnetDevices.filter { matches($0.displayName) }
    }

    private func filter(_ items: [SavedConnection]) -> [SavedConnection] {
        if query.isEmpty { return items }
        return items.filter { matches($0.displayName) || matches($0.host) }
    }

    private func matches(_ s: String) -> Bool {
        s.range(of: query, options: .caseInsensitive) != nil
    }

    // MARK: - Misc

    private var isEmptyResults: Bool {
        !app.macHost.isSharing
        && sessionStore.sessions.isEmpty
        && filteredBookmarks.isEmpty
        && filteredDiscovered.isEmpty
        && filteredRFB.isEmpty
        && filteredTailnet.isEmpty
        && filteredRecents.isEmpty
    }

    private var statusLine: String {
        if !sessionStore.sessions.isEmpty {
            let n = sessionStore.sessions.count
            return "\(n) active session\(n == 1 ? "" : "s")"
        }
        if app.macHost.isSharing { return "Hosting · ready" }
        if app.browserStatus.isBrowsing { return "Searching local network…" }
        return "Idle"
    }

    private var hostingSubtitle: String {
        let pending = app.macHost.pendingRequests.count
        if pending > 0 { return "\(pending) pending request\(pending == 1 ? "" : "s")" }
        return "No pending requests"
    }

    private func protocolIcon(_ p: RemoteConnectionProtocol) -> String {
        switch p {
        case .screenQ:          return "display"
        case .macScreenSharing: return "macwindow"
        case .vnc:              return "rectangle.on.rectangle"
        case .rdp:              return "pc"
        }
    }

    private func hostIcon(_ host: DiscoveredHost) -> String {
        switch host.advertisedPlatform {
        case "macOS":    return "desktopcomputer"
        case "iPadOS":   return "ipad"
        case "iOS":      return "iphone"
        case "visionOS": return "visionpro"
        default:         return "display"
        }
    }
}

private struct HoverableRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(hovering || configuration.isPressed ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
#endif
