//
//  HostMacView.swift
//  Screen Q
//

#if os(macOS)
import AppKit
import SwiftUI

struct HostMacView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HostMacContent(host: app.macHost)
            .environmentObject(app)
    }
}

private struct HostMacContent: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var host: MacHostRuntime
    @State private var showStopConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionsCard
                displayCard
                advertiseCard
                if host.isSharing { connectInfoCard }
                permissionsGrantCard
                pairingCard
                sessionsCard
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Host this Mac")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showStopConfirm = true
                } label: {
                    Label("Stop Sharing Now", systemImage: "stop.circle.fill")
                }
                .foregroundColor(.red)
                .disabled(!host.isSharing)
            }
        }
        .alert(isPresented: $showStopConfirm) {
            Alert(
                title: Text("Stop sharing this Mac?"),
                message: Text("All connected viewers will be disconnected. You can re-share at any time."),
                primaryButton: .destructive(Text("Stop")) { host.stopHosting() },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            Task { await host.refreshForHostSurface() }
        }
    }

    // MARK: - Cards

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Permissions")
            PermissionsView()
                .environmentObject(app.macPermissions)
        }
        .panel()
    }

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Display")
            if app.displaySelection.displays.isEmpty {
                Text("No displays detected yet. Grant Screen Recording, then click Refresh.")
                    .foregroundColor(.secondary)
            } else {
                Picker("Display", selection: Binding(
                    get: { app.displaySelection.selectedDisplayID ?? app.displaySelection.displays.first?.id ?? 0 },
                    set: { app.displaySelection.selectedDisplayID = $0 }
                )) {
                    ForEach(app.displaySelection.displayOptions()) { d in
                        Text("\(d.name) - \(d.pixelWidth)x\(d.pixelHeight)")
                            .tag(d.id)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Button("Refresh Displays") {
                    Task { await app.displaySelection.refreshUsingSCShareableContent() }
                }
                Spacer()
                qualitySlider
            }
        }
        .panel()
    }

    private var qualitySlider: some View {
        HStack(spacing: 8) {
            Text("Quality")
                .foregroundColor(.secondary)
            Slider(value: Binding(
                get: { host.quality },
                set: { host.quality = $0 }
            ), in: 0.2...1.0)
            .frame(width: 200)
            .onChange(of: host.quality) { newValue in
                host.applyStreamQuality(StreamQualityPreference(quality: newValue))
            }
            Text("\(Int(host.quality * 100))%")
                .font(.system(.body, design: .monospaced))
        }
    }

    private var advertiseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Advertise on local network")
            HStack {
                Toggle("View only (block input)", isOn: Binding(
                    get: { host.viewOnly },
                    set: { host.viewOnly = $0 }
                ))
                Spacer()
            }
            HStack {
                Button(host.isSharing ? "Hosting..." : "Start Hosting") {
                    Task { await host.startHosting() }
                }
                .disabled(host.isSharing || !host.readyToHost)
                .buttonStyle(.bordered)

                Spacer()

                Text("Bonjour: _screenq._tcp - port \(ScreenQProtocol.defaultPort)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Toggle("Auto-start hosting on launch", isOn: Binding(
                get: { host.autoStartHosting },
                set: { host.autoStartHosting = $0 }
            ))
            .font(.footnote)
            .foregroundColor(.secondary)
            Toggle("Share clipboard", isOn: Binding(
                get: { host.enableClipboard },
                set: { host.enableClipboard = $0 }
            ))
            .font(.footnote)
            .foregroundColor(.secondary)
            Toggle("Forward audio", isOn: Binding(
                get: { host.enableAudio },
                set: { host.enableAudio = $0 }
            ))
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .panel()
    }

    private var connectInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Connect from another device")
            Text("Give your viewer one of these addresses and port \(host.listeningPort):")
                .font(.footnote)
                .foregroundColor(.secondary)

            if host.listeningAddresses.isEmpty {
                Text("No connectable addresses detected. Check Wi-Fi or Ethernet.")
                    .foregroundColor(.orange)
                    .font(.footnote)
            } else {
                ForEach(host.listeningAddresses) { iface in
                    HStack(spacing: 8) {
                        Image(systemName: iface.kind == .tailscale ? "network" : "wifi")
                            .foregroundColor(iface.kind == .tailscale ? .blue : .green)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(iface.address):\(host.listeningPort)")
                                .font(.system(.body, design: .monospaced))

                            Text(iface.humanLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(iface.address):\(host.listeningPort)", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }
                    .padding(.vertical, 4)
                }
            }

            Text("Bonjour (same LAN) discovers automatically. For Tailscale or VPN, viewers use Manual Connect.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .panel()
        .onAppear {
            Task { await host.refreshListeningInfo() }
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Pairing")
            HStack(alignment: .firstTextBaseline) {
                Text("Code")
                    .font(.headline)
                Text(host.pairingCode)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))

                Spacer()
                Button("Regenerate") { host.regeneratePairingCode() }
            }
            Text("Tell your viewer this code. Codes expire after 5 minutes. The host still decides whether to trust or allow each connection.")
                .font(.footnote)
                .foregroundColor(.secondary)
            if !host.pendingRequests.isEmpty {
                Divider()
                Text("Incoming requests")
                    .font(.headline)
                ForEach(host.pendingRequests) { req in
                    PairingRequestRow(request: req, host: host)
                }
            }
        }
        .panel()
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Sessions")
            if host.hostConnections.isEmpty {
                Text(host.isSharing ? "Waiting for viewers to connect..." : "Not hosting.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(host.hostConnections) { box in
                    HostSessionRow(box: box, host: host)
                }
            }
        }
        .panel()
    }

    private var permissionsGrantCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Viewer Permissions")
            Text("Choose what connected viewers are allowed to do.")
                .font(.footnote)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(PermissionSet.allCases, id: \.label) { item in
                    Toggle(isOn: Binding(
                        get: { host.permissions.contains(item.flag) },
                        set: { enabled in
                            if enabled {
                                host.permissions.insert(item.flag)
                            } else {
                                host.permissions.remove(item.flag)
                            }
                        }
                    )) {
                        Label(item.label, systemImage: item.icon)
                            .font(.footnote)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack(spacing: 12) {
                Button("Full Access") { host.permissions = .fullAccess }
                    .font(.caption)
                Button("Standard") { host.permissions = .standard }
                    .font(.caption)
                Button("View Only") { host.permissions = .viewOnly }
                    .font(.caption)
            }
        }
        .panel()
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.title2).bold()
    }
}

private struct PairingRequestRow: View {
    let request: PairingRequest
    @ObservedObject var host: MacHostRuntime

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.viewer.displayName)
                Text(detailText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Reject") {
                Task { await host.reject(request) }
            }
            .foregroundColor(.red)
            Button(request.trustedReconnect ? "Allow" : "Trust") {
                Task { await host.approve(request) }
            }
            .buttonStyle(.bordered)
            .disabled(!host.pairingCodeMatches(request))
        }
        .padding(.vertical, 4)
    }

    private var detailText: String {
        if request.trustedReconnect {
            return "Trusted device - \(host.accessPolicy(for: request).displayName)"
        }
        return "Pairing code: \(request.claimedCode)"
    }
}

private struct HostSessionRow: View {
    @ObservedObject var box: HostSessionBox
    @ObservedObject var host: MacHostRuntime

    var body: some View {
        HStack {
            Image(systemName: "rectangle.connected.to.line.below")
            Text(box.peerName)
            Spacer()
            Text(box.state.humanDescription)
                .foregroundColor(.secondary)
                .font(.caption)
            if box.state.isActive && box.encryptionStatusKnown {
                Text(box.encryptionEnabled ? "Encrypted" : "Unencrypted")
                    .foregroundColor(box.encryptionEnabled ? .green : .orange)
                    .font(.caption.bold())
            }
            Button {
                Task { await host.disconnect(box) }
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private extension TrustedPeerAccessPolicy {
    var displayName: String {
        switch self {
        case .askEveryTime: return "Ask every time"
        case .alwaysAllow: return "Always allow"
        case .alwaysDeny: return "Always deny"
        }
    }
}

private extension View {
    func panel() -> some View {
        self.padding(20)
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
}
#endif
