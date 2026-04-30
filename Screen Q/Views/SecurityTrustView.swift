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
    @State private var refreshToken = UUID()

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

    private var credentialRecords: [StoredCredentialMetadata] {
        var recordsByID = Dictionary(
            uniqueKeysWithValues: CredentialInventoryStore.all().map { ($0.id, $0) }
        )
        for fallback in RDPKeychainCredentialStore.knownCredentialMetadata() + VNCKeychainCredentialStore.knownCredentialMetadata()
        where recordsByID[fallback.id] == nil {
            recordsByID[fallback.id] = fallback
        }
        return recordsByID.values.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.address.localizedStandardCompare($1.address) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                protocolTrustModel
                savedConnections
                rememberedCredentials
                trustedDevices
                rdpCertificatePins
                credentialBoundary
                auditTrail
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
            .id(refreshToken)
        }
        .navigationTitle("Security & Trust")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Security & Trust")
                .font(.title2.bold())
            Text("Review and revoke local trust decisions. Credentials stay in Keychain; this screen only stores non-secret metadata, saved endpoints, certificate pins, and peer fingerprints.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var protocolTrustModel: some View {
        trustPanel(title: "Protocol Trust Model", systemImage: "shield.lefthalf.filled") {
            protocolRow(
                title: "Screen Q Native",
                detail: "Best path: encrypted handshake, pinned device identity, host approval, and granular permissions. Clipboard and file transfer are available only when granted for the session.",
                systemImage: "display",
                tint: .green
            )
            protocolRow(
                title: "RDP",
                detail: "Windows path: TLS/NLA, Windows account credentials, and per-host certificate pin review. Clipboard redirection can be requested; Screen Q does not offer native file transfer on this route.",
                systemImage: "pc",
                tint: .purple
            )
            protocolRow(
                title: "Mac Screen Sharing",
                detail: "Apple compatibility path: prefers macOS account authentication; stream security depends on Apple/RFB and the network path. Clipboard and file transfer controls are disabled here.",
                systemImage: "macwindow",
                tint: .blue
            )
            protocolRow(
                title: "Generic VNC",
                detail: "Compatibility fallback: legacy password auth. Use only over Tailscale, VPN, or a private LAN. Clipboard and file transfer controls are disabled here.",
                systemImage: "rectangle.connected.to.line.below",
                tint: .orange
            )
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
                        Button("Remove") {
                            removeSavedConnection(connection)
                        }
                        .buttonStyle(.bordered)
                    }
                    Divider()
                }
            }
        }
    }

    private var rememberedCredentials: some View {
        trustPanel(title: "Remembered Credentials", systemImage: "key.fill") {
            if credentialRecords.isEmpty {
                Text("No remembered remote-access credentials are registered in Screen Q's credential inventory.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(credentialRecords) { credential in
                    HStack(alignment: .top) {
                        Image(systemName: credential.kind.systemImage)
                            .foregroundColor(tint(for: credential.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(credential.kind.displayName)
                                .font(.headline)
                            Text(credential.address)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let username = credential.username, !username.isEmpty {
                                Text("Username \(username)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(credential.requiresLocalAuthentication ? "Reuse requires Touch ID, Face ID, or passcode." : "Reuse allowed after device unlock.")
                                .font(.caption2)
                                .foregroundColor(credential.requiresLocalAuthentication ? .green : .orange)
                            if credential.lastUpdated == .distantPast {
                                Text("Existing Keychain item; metadata will update next time credentials are saved.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Updated \(Self.dateFormatter.string(from: credential.lastUpdated))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button("Forget") {
                            forgetCredential(credential)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
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
                        Spacer()
                        Picker("Access", selection: Binding(
                            get: { peer.accessPolicy },
                            set: { updateTrustedPeer(peer, accessPolicy: $0) }
                        )) {
                            ForEach(TrustedPeerAccessPolicy.allCases, id: \.self) { policy in
                                Text(policy.securityTrustLabel).tag(policy)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Button("Revoke") {
                            revokeTrustedPeer(peer)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
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
                        Spacer()
                        Button("Forget") {
                            forgetRDPCertificate(certificate)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                    Divider()
                }
            }
        }
    }

    private func protocolRow(title: String, detail: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var credentialBoundary: some View {
        trustPanel(title: "Credential Boundary", systemImage: "lock.shield") {
            Label("RDP, Mac Screen Sharing, and VNC credentials are stored in Keychain only when you choose to remember them.", systemImage: "key")
            Label("Saved credentials can require Touch ID, Face ID, or device passcode before reuse.", systemImage: "touchid")
            Label("Incoming Screen Q file offers require an explicit accept action before any chunks are written to Downloads.", systemImage: "doc.badge.arrow.up")
            Label("Screen Q clipboard sharing is bidirectional only on native sessions when both clipboard permission and the host clipboard setting are enabled.", systemImage: "doc.on.clipboard")
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

    private func tint(for credentialKind: StoredCredentialMetadata.Kind) -> Color {
        switch credentialKind {
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

    private func removeSavedConnection(_ connection: SavedConnection) {
        app.savedConnections.remove(connection.id)
        app.auditLog.log(
            peerName: connection.displayName,
            event: .securityStateChanged,
            detail: "Removed saved \(connection.resolvedProtocol.displayName) connection \(connection.address)"
        )
        refreshToken = UUID()
    }

    private func forgetCredential(_ credential: StoredCredentialMetadata) {
        switch credential.kind {
        case .macScreenSharing, .vnc:
            VNCKeychainCredentialStore.delete(host: credential.host, port: credential.port)
        case .rdp:
            RDPKeychainCredentialStore.delete(host: credential.host, port: credential.port)
        }
        app.auditLog.log(
            peerName: credential.address,
            event: .securityStateChanged,
            detail: "Forgot saved \(credential.kind.displayName) credentials"
        )
        refreshToken = UUID()
    }

    private func revokeTrustedPeer(_ peer: TrustedPeer) {
        var next = trustedPeers.filter { $0.id != peer.id || $0.fingerprint != peer.fingerprint }
        next.sort { $0.lastSeen > $1.lastSeen }
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: "ScreenQ.TrustedPeers")
        }
        app.auditLog.log(
            peerName: peer.displayName,
            peerID: peer.id,
            event: .trustChanged,
            detail: "Revoked trusted Screen Q device identity \(peer.fingerprint.prefix(16))..."
        )
        refreshToken = UUID()
    }

    private func updateTrustedPeer(_ peer: TrustedPeer, accessPolicy: TrustedPeerAccessPolicy) {
        var next = trustedPeers
        guard let index = next.firstIndex(where: { $0.id == peer.id && $0.fingerprint == peer.fingerprint }) else { return }
        next[index].accessPolicy = accessPolicy
        next.sort { $0.lastSeen > $1.lastSeen }
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: "ScreenQ.TrustedPeers")
        }
        app.auditLog.log(
            peerName: peer.displayName,
            peerID: peer.id,
            event: .trustChanged,
            detail: "Set Screen Q device identity \(peer.fingerprint.prefix(16))... access policy to \(accessPolicy.securityTrustLabel)."
        )
        refreshToken = UUID()
    }

    private func forgetRDPCertificate(_ certificate: RDPTrustedCertificate) {
        RDPCertificateTrustStore.delete(host: certificate.host, port: certificate.port)
        app.auditLog.log(
            peerName: "\(certificate.host):\(certificate.port)",
            event: .certificateDecision,
            detail: "Forgot pinned RDP certificate \(certificate.fingerprintSHA256.prefix(16))..."
        )
        refreshToken = UUID()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension TrustedPeerAccessPolicy {
    static var allCases: [TrustedPeerAccessPolicy] {
        [.askEveryTime, .alwaysAllow, .alwaysDeny]
    }

    var securityTrustLabel: String {
        switch self {
        case .askEveryTime: return "Ask Every Time"
        case .alwaysAllow: return "Always Allow"
        case .alwaysDeny: return "Always Deny"
        }
    }
}
