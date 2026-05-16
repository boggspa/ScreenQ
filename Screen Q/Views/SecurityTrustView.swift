//
//  SecurityTrustView.swift
//  Screen Q
//
//  Local trust inventory for remote access: saved connections, native trusted
//  device identities, credential boundaries, and recent audit entries.
//

import SwiftUI

/// Thin wrapper that keeps the existing sheet / NavigationLink call sites
/// working. The body just embeds `SecurityTrustSettingsContent` so it can
/// be reused inside the unified Settings pane.
struct SecurityTrustView: View {
    var body: some View {
        SecurityTrustSettingsContent()
            .navigationTitle("Security & Trust")
    }
}

/// The full Security & Trust surface, extracted so it can be embedded in
/// the Settings pane (`SettingsScene.Tab.security`) and in the legacy
/// sheet/NavigationLink entry point.
struct SecurityTrustSettingsContent: View {
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
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Security & Trust")
                .font(.sqTitle)
            Text("Review and revoke local trust decisions. Credentials stay in Keychain; this screen only stores non-secret metadata, saved endpoints, certificate pins, and peer fingerprints.")
                .font(.sqCallout)
                .foregroundColor(.secondary)
        }
    }

    private var protocolTrustModel: some View {
        trustPanel(title: "Protocol Trust Model", systemImage: "shield.lefthalf.filled", tint: ScreenQTheme.cosmicIndigo) {
            protocolRow(
                title: "Screen Q Native",
                detail: "Best path: encrypted handshake, pinned device identity, host approval, and granular permissions. Clipboard and file transfer are available only when granted for the session.",
                systemImage: "display",
                tint: ScreenQTheme.cosmicMint
            )
            protocolRow(
                title: "RDP",
                detail: "Windows path: TLS/NLA, Windows account credentials, and per-host certificate pin review. Clipboard redirection can be requested; Screen Q does not offer native file transfer on this route.",
                systemImage: "pc",
                tint: ScreenQTheme.cosmicViolet
            )
            protocolRow(
                title: "Mac Screen Sharing",
                detail: "Apple compatibility path: prefers macOS account authentication; stream security depends on Apple/RFB and the network path. Clipboard and file transfer controls are disabled here.",
                systemImage: "macwindow",
                tint: ScreenQTheme.cosmicCyan
            )
            protocolRow(
                title: "Generic VNC",
                detail: "Compatibility fallback: legacy password auth. Use only over Tailscale, VPN, or a private LAN. Clipboard and file transfer controls are disabled here.",
                systemImage: "rectangle.connected.to.line.below",
                tint: ScreenQTheme.cosmicAmber
            )
        }
    }

    private var savedConnections: some View {
        trustPanel(title: "Saved Connections", systemImage: "clock.badge.checkmark", tint: ScreenQTheme.cosmicCyan) {
            if app.savedConnections.connections.isEmpty {
                SQEmptyState(
                    icon: "bookmark",
                    title: "No saved connections yet",
                    message: "Connections you save appear here for review and removal.",
                    tint: ScreenQTheme.cosmicCyan,
                    compact: true
                )
            } else {
                ForEach(app.savedConnections.connections) { connection in
                    HStack(alignment: .top) {
                        Image(systemName: icon(for: connection.resolvedProtocol))
                            .foregroundColor(tint(for: connection.resolvedProtocol))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.displayName)
                                .font(.sqHeadline)
                            Text("\(connection.resolvedProtocol.displayName) - \(connection.address)")
                                .font(.sqCaption)
                                .foregroundColor(.secondary)
                            Text(securitySummary(for: connection.resolvedProtocol))
                                .font(.sqCaption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if connection.isBookmark {
                            Image(systemName: "star.fill")
                                .foregroundColor(ScreenQTheme.cosmicAmber)
                                .accessibilityLabel("Bookmarked")
                        }
                        SQDestructiveButton(
                            title: "Remove",
                            systemImage: "trash",
                            isEnabled: true
                        ) {
                            removeSavedConnection(connection)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private var rememberedCredentials: some View {
        trustPanel(title: "Remembered Credentials", systemImage: "key.fill", tint: ScreenQTheme.cosmicAmber) {
            if credentialRecords.isEmpty {
                SQEmptyState(
                    icon: "key.slash",
                    title: "No remembered credentials",
                    message: "Saved RDP, VNC, and Mac Screen Sharing credentials will appear here.",
                    tint: ScreenQTheme.cosmicAmber,
                    compact: true
                )
            } else {
                ForEach(credentialRecords) { credential in
                    HStack(alignment: .top) {
                        Image(systemName: credential.kind.systemImage)
                            .foregroundColor(tint(for: credential.kind))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(credential.kind.displayName)
                                .font(.sqHeadline)
                            Text(credential.address)
                                .font(.sqCaption)
                                .foregroundColor(.secondary)
                            if let username = credential.username, !username.isEmpty {
                                Text("Username \(username)")
                                    .font(.sqCaption)
                                    .foregroundColor(.secondary)
                            }
                            SQPill(
                                text: credential.requiresLocalAuthentication
                                    ? "Touch ID / Face ID required"
                                    : "Allowed after unlock",
                                status: credential.requiresLocalAuthentication ? .healthy : .attention,
                                compact: true
                            )
                            if credential.lastUpdated == .distantPast {
                                Text("Existing Keychain item; metadata will update next time credentials are saved.")
                                    .font(.sqCaption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Updated \(Self.dateFormatter.string(from: credential.lastUpdated))")
                                    .font(.sqCaption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        SQDestructiveButton(
                            title: "Forget",
                            systemImage: "trash",
                            isEnabled: true
                        ) {
                            forgetCredential(credential)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private var trustedDevices: some View {
        trustPanel(title: "Native Screen Q Trusted Devices", systemImage: "person.badge.key", tint: ScreenQTheme.cosmicMint) {
            if trustedPeers.isEmpty {
                SQEmptyState(
                    icon: "person.badge.shield.checkmark",
                    title: "No pinned device identities",
                    message: "Devices you trust during pairing appear here.",
                    tint: ScreenQTheme.cosmicMint,
                    compact: true
                )
            } else {
                ForEach(trustedPeers) { peer in
                    HStack(alignment: .top) {
                        Image(systemName: "key.horizontal")
                            .foregroundColor(ScreenQTheme.cosmicMint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                                .font(.sqHeadline)
                            Text("Fingerprint \(peer.fingerprint.prefix(16))…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("Last seen \(Self.dateFormatter.string(from: peer.lastSeen))")
                                .font(.sqCaption)
                                .foregroundColor(.secondary)
                            SQPill(
                                text: peer.accessPolicy.securityTrustLabel,
                                status: trustPillStatus(for: peer.accessPolicy),
                                compact: true
                            )
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
                        SQDestructiveButton(
                            title: "Revoke",
                            systemImage: "xmark.shield",
                            isEnabled: true
                        ) {
                            revokeTrustedPeer(peer)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private var rdpCertificatePins: some View {
        trustPanel(title: "Pinned RDP Certificates", systemImage: "checkmark.seal", tint: ScreenQTheme.cosmicViolet) {
            if rdpCertificates.isEmpty {
                SQEmptyState(
                    icon: "seal",
                    title: "No pinned RDP certificates",
                    message: "Certificates you trust when connecting to Windows hosts appear here.",
                    tint: ScreenQTheme.cosmicViolet,
                    compact: true
                )
            } else {
                ForEach(rdpCertificates) { certificate in
                    HStack(alignment: .top) {
                        Image(systemName: "desktopcomputer")
                            .foregroundColor(ScreenQTheme.cosmicViolet)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(certificate.host):\(certificate.port)")
                                .font(.sqHeadline)
                            Text(certificate.subject.isEmpty ? "Unknown certificate subject" : certificate.subject)
                                .font(.sqCaption)
                                .foregroundColor(.secondary)
                            Text("SHA-256 \(certificate.fingerprintSHA256.prefix(24))…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("Last trusted \(Self.dateFormatter.string(from: certificate.lastTrustedAt))")
                                .font(.sqCaption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        SQDestructiveButton(
                            title: "Forget",
                            systemImage: "trash",
                            isEnabled: true
                        ) {
                            forgetRDPCertificate(certificate)
                        }
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sqHeadline)
                Text(detail)
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var credentialBoundary: some View {
        trustPanel(title: "Credential Boundary", systemImage: "lock.shield", tint: ScreenQTheme.cosmicTeal) {
            Label("RDP, Mac Screen Sharing, and VNC credentials are stored in Keychain only when you choose to remember them.", systemImage: "key")
            Label("Saved credentials can require Touch ID, Face ID, or device passcode before reuse.", systemImage: "touchid")
            Label("Incoming Screen Q file offers require an explicit accept action before any chunks are written to Downloads.", systemImage: "doc.badge.arrow.up")
            Label("Screen Q clipboard sharing is bidirectional only on native sessions when both clipboard permission and the host clipboard setting are enabled.", systemImage: "doc.on.clipboard")
            Label("A VNC password is not a Mac admin/user password. Screen Q labels that fallback separately.", systemImage: "exclamationmark.shield")
            Label("RDP certificate trust is pinned per Windows host and blocks changed identities until reviewed.", systemImage: "checkmark.seal")
        }
        .font(.sqCallout)
    }

    private var auditTrail: some View {
        trustPanel(title: "Recent Audit", systemImage: "list.bullet.clipboard", tint: ScreenQTheme.cosmicIndigo) {
            if app.auditLog.recentEntries.isEmpty {
                SQEmptyState(
                    icon: "list.bullet.clipboard",
                    title: "No audit entries yet",
                    message: "Trust changes, certificate decisions, and security state changes will show up here.",
                    tint: ScreenQTheme.cosmicIndigo,
                    compact: true
                )
            } else {
                ForEach(app.auditLog.recentEntries.suffix(12).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.eventType.rawValue) - \(entry.peerName)")
                            .font(.sqHeadline)
                        Text(entry.detail)
                            .font(.sqCaption)
                            .foregroundColor(.secondary)
                        Text(Self.dateFormatter.string(from: entry.timestamp))
                            .font(.sqCaption)
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
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // `systemImage` retained for source-compatibility with previous
        // call sites; the section header is purely textual now and gets
        // its visual weight from the tinted card chrome.
        _ = systemImage
        return VStack(alignment: .leading, spacing: 12) {
            SQSectionHeader(title)
            content()
        }
        .screenQCard(tint: tint)
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
        case .screenQ: return ScreenQTheme.cosmicMint
        case .macScreenSharing: return ScreenQTheme.cosmicCyan
        case .vnc: return ScreenQTheme.cosmicAmber
        case .rdp: return ScreenQTheme.cosmicViolet
        }
    }

    private func tint(for credentialKind: StoredCredentialMetadata.Kind) -> Color {
        switch credentialKind {
        case .macScreenSharing: return ScreenQTheme.cosmicCyan
        case .vnc: return ScreenQTheme.cosmicAmber
        case .rdp: return ScreenQTheme.cosmicViolet
        }
    }

    private func trustPillStatus(for policy: TrustedPeerAccessPolicy) -> SQStatus {
        switch policy {
        case .askEveryTime: return .info
        case .alwaysAllow:  return .healthy
        case .alwaysDeny:   return .error
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
        SQHaptics.warning()
        app.savedConnections.remove(connection.id)
        app.auditLog.log(
            peerName: connection.displayName,
            event: .securityStateChanged,
            detail: "Removed saved \(connection.resolvedProtocol.displayName) connection \(connection.address)"
        )
        refreshToken = UUID()
    }

    private func forgetCredential(_ credential: StoredCredentialMetadata) {
        SQHaptics.warning()
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
        SQHaptics.warning()
        var next = trustedPeers.filter { $0.id != peer.id || $0.fingerprint != peer.fingerprint }
        next.sort { $0.lastSeen > $1.lastSeen }
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: "ScreenQ.TrustedPeers")
        }
        app.auditLog.log(
            peerName: peer.displayName,
            peerID: peer.id,
            event: .trustChanged,
            detail: "Revoked trusted Screen Q device identity \(peer.fingerprint.prefix(16))…"
        )
        refreshToken = UUID()
    }

    private func updateTrustedPeer(_ peer: TrustedPeer, accessPolicy: TrustedPeerAccessPolicy) {
        SQHaptics.tap()
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
            detail: "Set Screen Q device identity \(peer.fingerprint.prefix(16))… access policy to \(accessPolicy.securityTrustLabel)."
        )
        refreshToken = UUID()
    }

    private func forgetRDPCertificate(_ certificate: RDPTrustedCertificate) {
        SQHaptics.warning()
        RDPCertificateTrustStore.delete(host: certificate.host, port: certificate.port)
        app.auditLog.log(
            peerName: "\(certificate.host):\(certificate.port)",
            event: .certificateDecision,
            detail: "Forgot pinned RDP certificate \(certificate.fingerprintSHA256.prefix(16))…"
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
