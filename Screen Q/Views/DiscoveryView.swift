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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nearby Devices")
                    .font(.title3).bold()
                Spacer()
                if app.browserStatus.isBrowsing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Rescan") { Task { await app.bonjourBrowser.start() } }
            }

            // Status banner
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(statusSummary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            // Screen Q hosts
            if !app.discoveredHosts.isEmpty {
                discoverySectionHeader(
                    title: hasNativeAndRFBHosts ? "Recommended: Screen Q Native" : "Screen Q Native",
                    detail: hasNativeAndRFBHosts ? "Use this first for the fastest Screen Q connection." : nil
                )
                ForEach(app.discoveredHosts) { host in
                    Button {
                        onSelect(host)
                    } label: {
                        DiscoveryRow(host: host)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
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

            // RFB / Apple Screen Sharing hosts
            if !app.discoveredRFBHosts.isEmpty {
                discoverySectionHeader(
                    title: hasNativeAndRFBHosts ? "Compatibility: Mac Screen Sharing" : "Mac Screen Sharing",
                    detail: "Uses Apple Screen Sharing on port 5900."
                )
                ForEach(app.discoveredRFBHosts) { host in
                    Button {
                        onSelectRFB?(host)
                    } label: {
                        RFBDiscoveryRow(host: host)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
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

            // Empty state
            if app.discoveredHosts.isEmpty && app.discoveredRFBHosts.isEmpty {
                VStack(spacing: 10) {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No devices found")
                            .font(.headline)
                        Text("On the Mac you want to share, enable Screen Sharing in System Settings or open Screen Q and tap Start Hosting.\n\nBonjour discovery only works on the same local network. For Tailscale or VPN, use Manual Connect below.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            if showsTailnet {
                Divider()
                    .padding(.vertical, 2)

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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
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
                .font(.caption.bold())
                .foregroundColor(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusIcon: String {
        if !app.discoveredHosts.isEmpty || !app.discoveredRFBHosts.isEmpty { return "checkmark.circle.fill" }
        if app.browserStatus.browserError != nil { return "exclamationmark.triangle" }
        return "magnifyingglass"
    }

    private var statusColor: Color {
        if !app.discoveredHosts.isEmpty { return .green }
        if !app.discoveredRFBHosts.isEmpty { return .blue }
        if app.browserStatus.browserError != nil { return .red }
        return .secondary
    }

    @ViewBuilder
    private var tailnetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tailnet Devices", systemImage: "lock.shield")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                if app.tailnetDiscoveryStatus.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                if app.tailnetAuthConfigured {
                    Button("Refresh") {
                        Task { await app.refreshTailnetDevices() }
                    }
                    .controlSize(.small)
                    Button("Forget") {
                        app.forgetTailscaleCredentials()
                        clearTailnetCredentialFields()
                        showTailnetTokenField = false
                    }
                    .controlSize(.small)
                    .foregroundColor(.red)
                } else {
                    Button(showTailnetTokenField ? "Cancel" : "Connect Tailscale") {
                        showTailnetTokenField.toggle()
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: tailnetStatusIcon)
                    .foregroundColor(tailnetStatusColor)
                Text(app.tailnetDiscoveryStatus.summary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
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
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            #endif
                        SecureField("Tailscale OAuth client secret", text: $tailscaleOAuthClientSecret)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            #endif
                    } else {
                        SecureField("Tailscale API access token", text: $tailscaleToken)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            #endif
                    }

                    HStack {
                        Text(tailnetCredentialHelpText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Save & Load") {
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
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canSaveTailnetCredentials)
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif
                }
            }

            if app.tailnetAuthConfigured, let credentialSummary = tailnetCredentialSummary {
                Label(credentialSummary, systemImage: "key")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !app.tailnetDevices.isEmpty {
                ForEach(app.tailnetDevices) { device in
                    TailnetDiscoveryRow(device: device) { selectedProtocol in
                        onSelectTailnet?(device, selectedProtocol)
                    }
                }
            }
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

    private var tailnetStatusIcon: String {
        switch app.tailnetDiscoveryStatus.phase {
        case .signedOut, .idle: return "lock.shield"
        case .loading: return "arrow.triangle.2.circlepath"
        case .loaded(let count): return count > 0 ? "checkmark.circle.fill" : "magnifyingglass"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var tailnetStatusColor: Color {
        switch app.tailnetDiscoveryStatus.phase {
        case .loaded(let count) where count > 0: return .green
        case .failed: return .orange
        default: return .secondary
        }
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
            Image(systemName: hostSymbol)
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.headline)
                HStack(spacing: 6) {
                    if let v = host.advertisedAppVersion {
                        Text("v\(v)").font(.caption).foregroundColor(.secondary)
                    }
                    if let p = host.advertisedPlatform {
                        Text(p).font(.caption).foregroundColor(.secondary)
                    }
                    if host.advertisesControl {
                        Label("Control", systemImage: "cursorarrow.click")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if host.isIOSShareOnlyPresence {
                        Label("ReplayKit", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundColor(.blue)
                    } else {
                        Label("View only", systemImage: "eye")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if !host.acceptsScreenQConnection {
                        Text("Share only")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: host.isIOSShareOnlyPresence ? "info.circle" : "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08))
        )
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
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.headline)
                HStack(spacing: 6) {
                    Label("Screen Sharing", systemImage: "rectangle.on.rectangle")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("Mac Screen Sharing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08))
        )
    }
}

private struct TailnetDiscoveryRow: View {
    let device: TailnetDevice
    var onConnect: (RemoteConnectionProtocol) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: device.symbolName)
                .font(.title2)
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.headline)
                HStack(spacing: 6) {
                    Label(device.statusText, systemImage: device.isOnline == false ? "circle" : "circle.fill")
                        .font(.caption)
                        .foregroundColor(device.isOnline == false ? .secondary : .green)
                    Text(device.primaryAddress ?? device.hostname ?? "No tailnet address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Label(device.recommendedProtocol.displayName, systemImage: protocolIcon(device.recommendedProtocol))
                        .font(.caption)
                        .foregroundColor(.blue)
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
                Image(systemName: "chevron.right.circle")
                    .foregroundColor(.secondary)
            }
            .disabled(device.connectionHost == nil)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08))
        )
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
