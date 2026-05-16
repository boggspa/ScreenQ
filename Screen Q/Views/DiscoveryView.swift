//
//  DiscoveryView.swift
//  Screen Q
//

import SwiftUI

struct DiscoveryView: View {

    @EnvironmentObject private var app: AppState
    @State private var tailscaleToken = ""
    @State private var tailscaleOAuthClientID = ""
    @State private var tailscaleOAuthClientSecret = ""
    @State private var tailscaleCredentialMode: TailnetCredentialMode = .oauthClient
    @State private var showTailnetTokenField = false
    var onSelect: (DiscoveredHost) -> Void
    var onSelectRFB: ((DiscoveredHost) -> Void)?
    var onSelectTailnet: ((TailnetDevice, RemoteConnectionProtocol) -> Void)? = nil
    var showsTailnet: Bool = true
    var onDetails: ((DiscoveredHost, RemoteConnectionProtocol) -> Void)? = nil
    var onManualConnect: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SQSectionHeader(
                "Nearby Devices",
                subtitle: statusSummary,
                action: .init("Rescan", systemImage: "arrow.clockwise") {
                    SQHaptics.tap()
                    Task { await app.bonjourBrowser.start() }
                }
            )

            statusRow

            // Screen Q hosts
            if !app.discoveredHosts.isEmpty {
                discoverySectionHeader(
                    title: hasNativeAndRFBHosts ? "Recommended: Screen Q Native" : "Screen Q Native",
                    detail: hasNativeAndRFBHosts ? "Use this first for the fastest Screen Q connection." : nil
                )
                VStack(spacing: 8) {
                    ForEach(app.discoveredHosts) { host in
                        Button {
                            SQHaptics.tap()
                            onSelect(host)
                        } label: {
                            DiscoveryRow(host: host)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                SQHaptics.tap()
                                onSelect(host)
                            } label: {
                                Label("Connect", systemImage: "play.fill")
                            }
                            Button {
                                onDetails?(host, .screenQ)
                            } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                        }
                    }
                }
            }

            // RFB / Apple Screen Sharing hosts
            if !app.discoveredRFBHosts.isEmpty {
                discoverySectionHeader(
                    title: hasNativeAndRFBHosts ? "Compatibility: Mac Screen Sharing" : "Mac Screen Sharing",
                    detail: "Uses Apple Screen Sharing on port 5900."
                )
                VStack(spacing: 8) {
                    ForEach(app.discoveredRFBHosts) { host in
                        Button {
                            SQHaptics.tap()
                            onSelectRFB?(host)
                        } label: {
                            RFBDiscoveryRow(host: host)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                SQHaptics.tap()
                                onSelectRFB?(host)
                            } label: {
                                Label("Connect", systemImage: "play.fill")
                            }
                            Button {
                                onDetails?(host, .macScreenSharing)
                            } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                        }
                    }
                }
            }

            // Empty state
            if app.discoveredHosts.isEmpty && app.discoveredRFBHosts.isEmpty {
                if let error = app.browserStatus.browserError {
                    SQErrorRecovery(
                        title: "Bonjour error",
                        message: "Discovery couldn't query the local network.",
                        detail: error,
                        onRetry: {
                            SQHaptics.tap()
                            Task { await app.bonjourBrowser.start() }
                        }
                    )
                } else {
                    SQEmptyState(
                        icon: "wifi.exclamationmark",
                        title: "No Macs found on this network",
                        message: "Make sure both devices are connected to the same Wi-Fi. Bonjour discovery doesn't reach across VPN or Tailscale — use Manual Connect for those.",
                        tint: ScreenQTheme.cosmicTeal,
                        primary: .init("Rescan", systemImage: "arrow.clockwise") {
                            SQHaptics.tap()
                            Task { await app.bonjourBrowser.start() }
                        },
                        secondary: onManualConnect.map { handler -> SQEmptyState.Action in
                            SQEmptyState.Action("Manual Connect", systemImage: "arrow.right") {
                                SQHaptics.tap()
                                handler()
                            }
                        }
                    )
                }
            }

            if showsTailnet {
                Divider().opacity(0.4).padding(.vertical, 2)
                tailnetSection
            }
        }
        .onAppear {
            if showsTailnet && app.tailnetAuthConfigured && app.tailnetDevices.isEmpty {
                Task { await app.refreshTailnetDevices() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenQCard(tint: ScreenQTheme.cosmicCyan)
        .overlay(
            Group {
                if app.browserStatus.isBrowsing && app.discoveredHosts.isEmpty && app.discoveredRFBHosts.isEmpty {
                    SQLoadingScrim(
                        title: "Scanning Bonjour…",
                        subtitle: "Looking for Macs on this network",
                        tint: .white
                    )
                    .allowsHitTesting(false)
                }
            },
            alignment: .center
        )
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if app.browserStatus.browserError != nil {
                SQPill(text: "Error", status: .error, compact: true)
            } else if !app.discoveredHosts.isEmpty || !app.discoveredRFBHosts.isEmpty {
                SQPill(text: "Found", status: .healthy, compact: true)
            } else if app.browserStatus.isBrowsing {
                SQPill(text: "Searching", status: .info, compact: true)
            } else {
                SQPill(text: "Idle", status: .muted, compact: true)
            }
            Text(statusSummary)
                .font(.sqCaption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    private var statusSummary: String {
        let sqCount = app.discoveredHosts.count
        let rfbCount = app.discoveredRFBHosts.count
        let total = sqCount + rfbCount
        if sqCount > 0 && rfbCount > 0 {
            return "Found Screen Q native and port 5900 compatibility hosts"
        }
        if total > 0 { return "Found \(total) device\(total == 1 ? "" : "s") on your network" }
        if app.browserStatus.browserError != nil { return "Bonjour error: \(app.browserStatus.browserError!)" }
        if app.browserStatus.isBrowsing { return "Searching for devices on your local network\u{2026}" }
        return "Not searching"
    }

    private var hasNativeAndRFBHosts: Bool {
        !app.discoveredHosts.isEmpty && !app.discoveredRFBHosts.isEmpty
    }

    private func discoverySectionHeader(title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.sqCaption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            if let detail {
                Text(detail)
                    .font(.sqCaption)
                    .foregroundColor(.secondary.opacity(0.85))
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var tailnetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tailnet Devices", systemImage: "lock.shield")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if app.tailnetDiscoveryStatus.isLoading {
                    ScreenQActivityTrail(tint: ScreenQTheme.cosmicMint)
                }
                if app.tailnetAuthConfigured {
                    Button("Refresh") {
                        SQHaptics.tap()
                        Task { await app.refreshTailnetDevices() }
                    }
                    .buttonStyle(.plain)
                    .font(.sqCaption)
                    .foregroundColor(ScreenQTheme.cosmicMint)

                    Button("Forget") {
                        SQHaptics.warning()
                        app.forgetTailscaleCredentials()
                        clearTailnetCredentialFields()
                        showTailnetTokenField = false
                    }
                    .buttonStyle(.plain)
                    .font(.sqCaption)
                    .foregroundColor(ScreenQTheme.cosmicRose)
                } else {
                    Button(showTailnetTokenField ? "Cancel" : "Connect Tailscale") {
                        SQHaptics.tap()
                        showTailnetTokenField.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.sqCaption)
                    .foregroundColor(ScreenQTheme.cosmicMint)
                }
            }

            HStack(spacing: 6) {
                SQPill(text: tailnetPillText, status: tailnetPillStatus, compact: true)
                Text(app.tailnetDiscoveryStatus.summary)
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            if showTailnetTokenField || (!app.tailnetAuthConfigured && app.tailnetDevices.isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Tailscale credential type", selection: $tailscaleCredentialMode) {
                        Text("OAuth").tag(TailnetCredentialMode.oauthClient)
                        Text("API token").tag(TailnetCredentialMode.apiToken)
                    }
                    .pickerStyle(.segmented)

                    if tailscaleCredentialMode == .oauthClient {
                        TextField("Tailscale OAuth client ID", text: $tailscaleOAuthClientID)
                            .textFieldStyle(.roundedBorder)
                            .font(.sqBody)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            #endif
                        SecureField("Tailscale OAuth client secret", text: $tailscaleOAuthClientSecret)
                            .textFieldStyle(.roundedBorder)
                            .font(.sqBody)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            #endif
                    } else {
                        SecureField("Tailscale API access token", text: $tailscaleToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.sqBody)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            #endif
                    }

                    HStack {
                        Text(tailnetCredentialHelpText)
                            .font(.sqCaption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            SQHaptics.success()
                            Task {
                                switch tailscaleCredentialMode {
                                case .oauthClient:
                                    await app.saveTailscaleOAuthClient(
                                        id: tailscaleOAuthClientID,
                                        secret: tailscaleOAuthClientSecret
                                    )
                                case .apiToken:
                                    await app.saveTailscaleAPIToken(tailscaleToken)
                                }
                                clearTailnetCredentialFields()
                                showTailnetTokenField = false
                            }
                        } label: {
                            Text("Save & Load")
                                .font(.sqHeadline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(
                                        canSaveTailnetCredentials
                                            ? ScreenQTheme.cosmicMint
                                            : Color.secondary.opacity(0.18)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSaveTailnetCredentials)
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif
                }
                .screenQCard(tint: ScreenQTheme.cosmicMint, padding: 12)
            }

            if app.tailnetAuthConfigured, let credentialSummary = tailnetCredentialSummary {
                Label(credentialSummary, systemImage: "key")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
            }

            if !app.tailnetDevices.isEmpty {
                VStack(spacing: 8) {
                    ForEach(app.tailnetDevices) { device in
                        TailnetDiscoveryRow(device: device) { selectedProtocol in
                            SQHaptics.tap()
                            onSelectTailnet?(device, selectedProtocol)
                        }
                    }
                }
            } else if app.tailnetAuthConfigured && !app.tailnetDiscoveryStatus.isLoading {
                SQEmptyState(
                    icon: "lock.shield",
                    title: "No tailnet devices",
                    message: "Your tailnet is connected but doesn't expose any reachable Macs right now.",
                    tint: ScreenQTheme.cosmicMint,
                    primary: .init("Refresh", systemImage: "arrow.clockwise") {
                        SQHaptics.tap()
                        Task { await app.refreshTailnetDevices() }
                    },
                    compact: true
                )
            }
        }
    }

    private var tailnetPillText: String {
        switch app.tailnetDiscoveryStatus.phase {
        case .signedOut: return "Sign in"
        case .idle:     return "Idle"
        case .loading:  return "Loading"
        case .loaded(let count): return count > 0 ? "\(count)" : "Empty"
        case .failed:   return "Failed"
        }
    }

    private var tailnetPillStatus: SQStatus {
        switch app.tailnetDiscoveryStatus.phase {
        case .loaded(let count) where count > 0: return .healthy
        case .failed: return .error
        case .loading: return .info
        default: return .muted
        }
    }

    private var canSaveTailnetCredentials: Bool {
        switch tailscaleCredentialMode {
        case .oauthClient:
            return !tailscaleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !tailscaleOAuthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .apiToken:
            return !tailscaleToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var tailnetCredentialHelpText: String {
        switch tailscaleCredentialMode {
        case .oauthClient:
            return "Use a Tailscale OAuth client with devices:core read access. Screen Q stores the client ID and secret in Keychain, then mints short-lived access tokens only when listing devices."
        case .apiToken:
            return "Use a scoped Tailscale token with device read access. Screen Q stores it in Keychain and only uses it to list tailnet devices."
        }
    }

    private var tailnetCredentialSummary: String? {
        switch app.tailnetCredentialKind {
        case .oauthClient:
            return "Using Tailscale OAuth credentials stored in Keychain."
        case .apiToken:
            return "Using a Tailscale API token stored in Keychain."
        case nil:
            return nil
        }
    }

    private func clearTailnetCredentialFields() {
        tailscaleToken = ""
        tailscaleOAuthClientID = ""
        tailscaleOAuthClientSecret = ""
    }
}

private enum TailnetCredentialMode: Hashable {
    case oauthClient
    case apiToken
}

private struct DiscoveryRow: View {
    let host: DiscoveredHost
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ScreenQTheme.accent(ScreenQTheme.cosmicCyan))
                    .frame(width: 38, height: 38)
                Image(systemName: hostSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                HStack(spacing: 6) {
                    if let v = host.advertisedAppVersion {
                        Text("v\(v)")
                            .font(.sqCaption)
                            .foregroundColor(.secondary)
                    }
                    if let p = host.advertisedPlatform {
                        Text(p)
                            .font(.sqCaption)
                            .foregroundColor(.secondary)
                    }
                    if host.advertisesControl {
                        SQPill(text: "Control", status: .healthy, compact: true)
                    } else if host.isIOSShareOnlyPresence {
                        SQPill(text: "Apple-native", status: .info, compact: true)
                    } else {
                        SQPill(text: "View only", status: .muted, compact: true)
                    }
                    if !host.acceptsScreenQConnection {
                        Text("Share only")
                            .font(.sqCaption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: host.isIOSShareOnlyPresence ? "info.circle" : "chevron.right")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .screenQCard(tint: ScreenQTheme.cosmicCyan, padding: 12)
        .accessibilityElement(children: .combine)
    }

    private var hostSymbol: String {
        switch host.advertisedPlatform {
        case "macOS": return "desktopcomputer"
        case "iPadOS": return "ipad"
        case "iOS":   return "iphone"
        case "visionOS": return "visionpro"
        default: return "tv"
        }
    }
}

private struct RFBDiscoveryRow: View {
    let host: DiscoveredHost
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ScreenQTheme.accent(ScreenQTheme.cosmicViolet))
                    .frame(width: 38, height: 38)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                HStack(spacing: 6) {
                    SQPill(text: "Screen Sharing", status: .info, compact: true)
                    Text("Apple RFB port 5900")
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .screenQCard(tint: ScreenQTheme.cosmicViolet, padding: 12)
        .accessibilityElement(children: .combine)
    }
}

private struct TailnetDiscoveryRow: View {
    let device: TailnetDevice
    var onConnect: (RemoteConnectionProtocol) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ScreenQTheme.accent(ScreenQTheme.cosmicMint))
                    .frame(width: 38, height: 38)
                Image(systemName: device.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                HStack(spacing: 6) {
                    SQPill(
                        text: device.statusText,
                        status: device.isOnline == false ? .muted : .healthy,
                        compact: true
                    )
                    Text(device.primaryAddress ?? device.hostname ?? "No tailnet address")
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    SQPill(text: device.recommendedProtocol.displayName, status: .info, compact: true)
                }
            }
            Spacer()
            Menu {
                Button {
                    onConnect(device.recommendedProtocol)
                } label: {
                    Label("Best Available", systemImage: protocolIcon(device.recommendedProtocol))
                }
                Button {
                    onConnect(.screenQ)
                } label: {
                    Label("Screen Q Native", systemImage: "display")
                }
                Button {
                    onConnect(.macScreenSharing)
                } label: {
                    Label("Mac Screen Sharing", systemImage: "macwindow")
                }
                Button {
                    onConnect(.rdp)
                } label: {
                    Label("RDP", systemImage: "pc")
                }
                Button {
                    onConnect(.vnc)
                } label: {
                    Label("Generic VNC", systemImage: "rectangle.connected.to.line.below")
                }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(ScreenQTheme.cosmicMint)
            }
            .menuStyle(.borderlessButton)
            .disabled(device.connectionHost == nil)
            .accessibilityLabel("Connect options")
        }
        .screenQCard(tint: ScreenQTheme.cosmicMint, padding: 12)
    }

    private func protocolIcon(_ connectionProtocol: RemoteConnectionProtocol) -> String {
        switch connectionProtocol {
        case .screenQ: return "display"
        case .macScreenSharing: return "macwindow"
        case .vnc: return "rectangle.connected.to.line.below"
        case .rdp: return "pc"
        }
    }
}
