//
//  DiscoveryView.swift
//  Screen Q
//

import SwiftUI

struct DiscoveryView: View {

    @EnvironmentObject private var app: AppState
    var onSelect: (DiscoveredHost) -> Void
    var onSelectRFB: ((DiscoveredHost) -> Void)?

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
                Text("Screen Q")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                ForEach(app.discoveredHosts) { host in
                    Button {
                        onSelect(host)
                    } label: {
                        DiscoveryRow(host: host)
                    }
                    .buttonStyle(.plain)
                }
            }

            // RFB / Apple Screen Sharing hosts
            if !app.discoveredRFBHosts.isEmpty {
                Text("Apple Screen Sharing")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                ForEach(app.discoveredRFBHosts) { host in
                    Button {
                        onSelectRFB?(host)
                    } label: {
                        RFBDiscoveryRow(host: host)
                    }
                    .buttonStyle(.plain)
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
        if total > 0 { return "Found \(total) device\(total == 1 ? "" : "s") on your network" }
        if app.browserStatus.browserError != nil { return "Bonjour error: \(app.browserStatus.browserError!)" }
        if app.browserStatus.isBrowsing { return "Searching for devices on your local network\u{2026}" }
        return "Not searching"
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
                    } else {
                        Label("View only", systemImage: "eye")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
