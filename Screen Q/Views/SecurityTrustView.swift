//
//  SecurityTrustView.swift
//  Screen Q
//
//  Local trust inventory for remote access: saved connections, native trusted
//  device identities, credential boundaries, and recent audit entries.
//

import SwiftUI

struct SecurityTrustView: View {
    @EnvironmentObject private var app: AppState

    private var trustedPeers: [TrustedPeer] {
        guard let data = UserDefaults.standard.data(forKey: "ScreenQ.TrustedPeers"),
              let peers = try? JSONDecoder().decode([TrustedPeer].self, from: data) else {
            return []
        }
        return peers.sorted { $0.lastSeen > $1.lastSeen }
    }

    private var rdpCertificates: [RDPTrustedCertificate] {
        RDPCertificateTrustStore.all()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                savedConnections
                trustedDevices
                rdpCertificatePins
                credentialBoundary
                auditTrail
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Security & Trust")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Security & Trust")
                .font(.title2.bold())
            Text("Review what Screen Q trusts locally. Credentials stay in Keychain; saved connections and peer fingerprints are not secrets.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var savedConnections: some View {
        trustPanel(title: "Saved Connections", systemImage: "clock.badge.checkmark") {
            if app.savedConnections.connections.isEmpty {
                Text("No saved connections yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(app.savedConnections.connections) { connection in
                    HStack(alignment: .top) {
                        Image(systemName: icon(for: connection.resolvedProtocol))
                            .foregroundColor(tint(for: connection.resolvedProtocol))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.displayName)
                                .font(.headline)
                            Text("\(connection.resolvedProtocol.displayName) - \(connection.address)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(securitySummary(for: connection.resolvedProtocol))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if connection.isBookmark {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private var trustedDevices: some View {
        trustPanel(title: "Native Screen Q Trusted Devices", systemImage: "person.badge.key") {
            if trustedPeers.isEmpty {
                Text("No pinned Screen Q device identities yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(trustedPeers) { peer in
                    HStack(alignment: .top) {
                        Image(systemName: "key.horizontal")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                                .font(.headline)
                            Text("Fingerprint \(peer.fingerprint.prefix(16))...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("Last seen \(Self.dateFormatter.string(from: peer.lastSeen))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private var rdpCertificatePins: some View {
        trustPanel(title: "Pinned RDP Certificates", systemImage: "checkmark.seal") {
            if rdpCertificates.isEmpty {
                Text("No Windows RDP certificates have been trusted yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(rdpCertificates) { certificate in
                    HStack(alignment: .top) {
                        Image(systemName: "desktopcomputer")
                            .foregroundColor(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(certificate.host):\(certificate.port)")
                                .font(.headline)
                            Text(certificate.subject.isEmpty ? "Unknown certificate subject" : certificate.subject)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("SHA-256 \(certificate.fingerprintSHA256.prefix(24))...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("Last trusted \(Self.dateFormatter.string(from: certificate.lastTrustedAt))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private var credentialBoundary: some View {
        trustPanel(title: "Credential Boundary", systemImage: "lock.shield") {
            Label("RDP, Mac Screen Sharing, and VNC credentials are stored in Keychain only when you choose to remember them.", systemImage: "key")
            Label("Saved credentials can require Touch ID, Face ID, or device passcode before reuse.", systemImage: "touchid")
            Label("A VNC password is not a Mac admin/user password. Screen Q labels that fallback separately.", systemImage: "exclamationmark.shield")
            Label("RDP certificate trust is pinned per Windows host and blocks changed identities until reviewed.", systemImage: "checkmark.seal")
        }
        .font(.footnote)
    }

    private var auditTrail: some View {
        trustPanel(title: "Recent Audit", systemImage: "list.bullet.clipboard") {
            if app.auditLog.recentEntries.isEmpty {
                Text("No audit entries yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(app.auditLog.recentEntries.suffix(12).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.eventType.rawValue) - \(entry.peerName)")
                            .font(.headline)
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(Self.dateFormatter.string(from: entry.timestamp))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Divider()
                }
            }
        }
    }

    private func trustPanel<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.12))
        )
    }

    private func icon(for connectionProtocol: RemoteConnectionProtocol) -> String {
        switch connectionProtocol {
        case .screenQ: return "display"
        case .macScreenSharing: return "macwindow"
        case .vnc: return "rectangle.connected.to.line.below"
        case .rdp: return "pc"
        }
    }

    private func tint(for connectionProtocol: RemoteConnectionProtocol) -> Color {
        switch connectionProtocol {
        case .screenQ: return .green
        case .macScreenSharing: return .blue
        case .vnc: return .orange
        case .rdp: return .purple
        }
    }

    private func securitySummary(for connectionProtocol: RemoteConnectionProtocol) -> String {
        switch connectionProtocol {
        case .screenQ:
            return "Native Screen Q sessions require encrypted transport and pinned device identity."
        case .macScreenSharing:
            return "Prefers macOS account authentication; legacy VNC password is a weaker fallback."
        case .vnc:
            return "Legacy VNC compatibility; use only over Tailscale, VPN, or private LAN."
        case .rdp:
            return "Windows RDP over TLS/NLA with certificate pin review."
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
