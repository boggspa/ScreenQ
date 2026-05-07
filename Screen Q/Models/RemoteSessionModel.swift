//
//  RemoteSessionModel.swift
//  Screen Q
//
//  Shared connection/session descriptors. These sit above individual
//  transports (Screen Q native, VNC, future Windows host/RDP) so the UI can
//  reason about capabilities and security without flattening each protocol.
//

import Foundation

nonisolated enum ConnectionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case screenQ
    case macScreenSharing
    case vnc
    case rdpReserved

    var displayName: String {
        switch self {
        case .screenQ: return "Screen Q"
        case .macScreenSharing: return "Mac Screen Sharing"
        case .vnc: return "VNC"
        case .rdpReserved: return "RDP"
        }
    }
}

nonisolated struct RemoteCapabilities: Codable, Hashable, Sendable {
    var supportsVideo: Bool
    var supportsControl: Bool
    var supportsClipboard: Bool
    var supportsFileTransfer: Bool
    var supportsAudio: Bool
    var platform: PeerPlatform
    var notes: [String]

    static let screenQUnknown = RemoteCapabilities(
        supportsVideo: true,
        supportsControl: true,
        supportsClipboard: true,
        supportsFileTransfer: true,
        supportsAudio: false,
        platform: .unknown,
        notes: []
    )

    static let vncCompatibility = RemoteCapabilities(
        supportsVideo: true,
        supportsControl: true,
        supportsClipboard: false,
        supportsFileTransfer: false,
        supportsAudio: false,
        platform: .unknown,
        notes: [
            "VNC compatibility path",
            "Session encryption depends on the surrounding network"
        ]
    )

    static let macScreenSharing = RemoteCapabilities(
        supportsVideo: true,
        supportsControl: true,
        supportsClipboard: false,
        supportsFileTransfer: false,
        supportsAudio: false,
        platform: .macOS,
        notes: [
            "Apple Screen Sharing / Remote Management compatibility path",
            "macOS account credentials are preferred when the server offers Apple authentication"
        ]
    )

    static let rdpPreview = RemoteCapabilities(
        supportsVideo: true,
        supportsControl: true,
        supportsClipboard: true,
        supportsFileTransfer: false,
        supportsAudio: true,
        platform: .windows,
        notes: [
            "RDP route",
            "Uses the bundled FreeRDP bridge when available"
        ]
    )
}

nonisolated enum RemoteSecurityLevel: String, Codable, Hashable, Sendable {
    case encrypted
    case networkProtected
    case legacyAuth
    case unprotected
    case unknown
}

nonisolated struct RemoteSecurityStatus: Codable, Hashable, Sendable {
    var level: RemoteSecurityLevel
    var title: String
    var detail: String
    var isTransportEncrypted: Bool
    var isAuthenticated: Bool
    var recommendedAction: String?
    var protocolName: String? = nil
    var authMethod: String? = nil
    var credentialStorage: String? = nil
    var identityVerification: String? = nil
    var warnings: [String] = []

    static let unknown = RemoteSecurityStatus(
        level: .unknown,
        title: "Security unknown",
        detail: "The connection has not negotiated security details yet.",
        isTransportEncrypted: false,
        isAuthenticated: false,
        recommendedAction: nil
    )

    static func vncConnecting(scope: NetworkTrustScope, profile: RFBConnectionProfile = .genericVNC) -> RemoteSecurityStatus {
        RemoteSecurityStatus(
            level: scope.isTrustedPrivateScope ? .networkProtected : .unknown,
            title: profile == .macScreenSharing ? "Checking Mac Screen Sharing security" : "Checking VNC security",
            detail: "\(profile.securityIntro) \(scope.connectionHint)",
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: scope.publicNetworkWarning,
            protocolName: profile.displayName,
            credentialStorage: "Keychain"
        )
    }

    static func vnc(report: RFBSecurityReport, scope: NetworkTrustScope, profile: RFBConnectionProfile = .genericVNC) -> RemoteSecurityStatus {
        let baseTitle: String
        let authenticated: Bool
        let authMethod: String

        switch report.mode {
        case .none:
            baseTitle = profile == .macScreenSharing ? "Mac Screen Sharing: no password" : "VNC: no server password"
            authenticated = false
            authMethod = "None"
        case .vncAuth:
            baseTitle = profile == .macScreenSharing ? "Mac Screen Sharing fallback: VNC password" : "VNC password auth"
            authenticated = true
            authMethod = "Legacy VNC password"
        case .appleDH:
            baseTitle = "Mac account auth"
            authenticated = true
            authMethod = "Apple Screen Sharing account credentials"
        case .appleScreenSharing, .appleModern35, .appleModern36:
            baseTitle = "Mac account auth"
            authenticated = true
            authMethod = "Apple Screen Sharing account credentials"
        case .unknown:
            baseTitle = "VNC security unknown"
            authenticated = false
            authMethod = "Unknown"
        }

        let level: RemoteSecurityLevel
        if scope.isTrustedPrivateScope {
            level = authenticated ? .networkProtected : .unprotected
        } else {
            level = authenticated ? .legacyAuth : .unprotected
        }

        var detail = "\(report.mode.securityDescription). \(scope.connectionHint)"
        if profile == .macScreenSharing && report.mode == .vncAuth {
            detail += " This is the legacy VNC-password fallback, not your Mac admin/user login."
        }
        if let offered = report.offeredModesDescription, !offered.isEmpty {
            detail += " Server offered: \(offered)."
        }

        var warnings: [String] = []
        if let warning = scope.publicNetworkWarning {
            warnings.append(warning)
        }
        if report.mode == .vncAuth || report.mode == .none {
            warnings.append("RFB traffic is not encrypted by Screen Q; use a private network, VPN, or Tailscale.")
        }

        return RemoteSecurityStatus(
            level: level,
            title: baseTitle,
            detail: detail,
            isTransportEncrypted: false,
            isAuthenticated: authenticated,
            recommendedAction: scope.publicNetworkWarning,
            protocolName: profile.displayName,
            authMethod: authMethod,
            credentialStorage: authenticated ? "Keychain" : nil,
            identityVerification: profile == .macScreenSharing ? "macOS sharing permissions" : nil,
            warnings: warnings
        )
    }

    static func rdpPreflight(scope: NetworkTrustScope) -> RemoteSecurityStatus {
        RemoteSecurityStatus(
            level: scope.isTrustedPrivateScope ? .networkProtected : .unknown,
            title: "RDP security pending",
            detail: "RDP normally negotiates TLS plus Network Level Authentication before the Windows session starts. Screen Q has not linked the RDP engine yet, so no RDP security handshake has run. \(scope.connectionHint)",
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: scope.publicNetworkWarning,
            protocolName: "RDP",
            credentialStorage: "Keychain"
        )
    }

    static func rdpEngineMissing(scope: NetworkTrustScope) -> RemoteSecurityStatus {
        RemoteSecurityStatus(
            level: scope.isTrustedPrivateScope ? .networkProtected : .unknown,
            title: "RDP endpoint reachable",
            detail: "The TCP endpoint is reachable, but Screen Q still needs the RDP engine bridge before it can negotiate TLS, NLA, graphics, and input channels.",
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: scope.publicNetworkWarning,
            protocolName: "RDP",
            credentialStorage: "Keychain"
        )
    }

    static func rdpNegotiating(scope: NetworkTrustScope) -> RemoteSecurityStatus {
        RemoteSecurityStatus(
            level: .unknown,
            title: "Negotiating RDP security",
            detail: "Screen Q is starting the RDP security handshake. The connection should report TLS and Network Level Authentication before credentials are accepted. \(scope.connectionHint)",
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: scope.publicNetworkWarning,
            protocolName: "RDP",
            credentialStorage: "Keychain"
        )
    }

    static func rdpCertificatePending(_ certificate: RDPCertificateInfo, scope: NetworkTrustScope) -> RemoteSecurityStatus {
        RemoteSecurityStatus(
            level: .unknown,
            title: "RDP certificate needs review",
            detail: "The Windows host presented a certificate for \(certificate.host). Review the fingerprint before trusting this server.",
            isTransportEncrypted: false,
            isAuthenticated: false,
            recommendedAction: scope.publicNetworkWarning ?? "Only continue if this fingerprint matches the Windows PC you expect.",
            protocolName: "RDP",
            credentialStorage: "Keychain",
            identityVerification: "Certificate fingerprint pending",
            warnings: ["Credentials are not sent until this certificate decision is made."]
        )
    }

    static func rdp(report: RDPSecurityReport, scope: NetworkTrustScope) -> RemoteSecurityStatus {
        let protocolName = report.tlsProtocol ?? "TLS"
        let nlaText = report.nlaSucceeded ? "Network Level Authentication succeeded." : "Network Level Authentication was not confirmed."
        let identityText = report.serverIdentityVerified ? "Server identity was verified." : "Server identity was not fully verified."

        let level: RemoteSecurityLevel
        if report.isTransportEncrypted && report.isAuthenticated && report.nlaSucceeded {
            level = .encrypted
        } else if scope.isTrustedPrivateScope && report.isAuthenticated {
            level = .networkProtected
        } else {
            level = .unknown
        }

        var warnings: [String] = []
        if !report.nlaSucceeded {
            warnings.append("Network Level Authentication was not confirmed.")
        }
        if !report.serverIdentityVerified {
            warnings.append("RDP certificate identity was not fully verified.")
        }
        if let warning = scope.publicNetworkWarning {
            warnings.append(warning)
        }

        return RemoteSecurityStatus(
            level: level,
            title: report.isTransportEncrypted ? "RDP secured" : "RDP security incomplete",
            detail: "\(protocolName) negotiated. \(nlaText) \(identityText)",
            isTransportEncrypted: report.isTransportEncrypted,
            isAuthenticated: report.isAuthenticated,
            recommendedAction: level == .encrypted ? nil : (scope.publicNetworkWarning ?? "Do not continue unless you understand this RDP server's security posture."),
            protocolName: "RDP",
            authMethod: report.nlaSucceeded ? "Windows credentials via NLA" : "Windows credentials",
            credentialStorage: "Keychain",
            identityVerification: report.serverIdentityVerified ? "Pinned or verified RDP certificate" : "Certificate identity not fully verified",
            warnings: warnings
        )
    }
}

typealias RemoteAccessSecurityStatus = RemoteSecurityStatus

nonisolated struct RemoteSessionDescriptor: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: ConnectionKind
    var label: String
    var host: String?
    var port: UInt16?
    var platform: PeerPlatform
}

@MainActor
protocol RemoteSession: AnyObject {
    var remoteSessionDescriptor: RemoteSessionDescriptor { get }
    var remoteCapabilities: RemoteCapabilities { get }
    var securityStatus: RemoteSecurityStatus { get }
    func disconnect() async
}

nonisolated enum NetworkTrustScope: Codable, Hashable, Sendable {
    case tailscale
    case privateLAN
    case localOnly
    case publicInternet
    case hostname
    case unknown

    static func classify(host: String) -> NetworkTrustScope {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.hasSuffix(".local") {
            return .privateLAN
        }
        if lowercased.contains(".ts.net") || lowercased.contains("tailscale") || lowercased.contains("tailnet") {
            return .tailscale
        }

        if let ipv4 = IPv4Address(lowercased) {
            if ipv4.isLoopback || ipv4.isLinkLocal {
                return .localOnly
            }
            if ipv4.isTailscaleRange {
                return .tailscale
            }
            if ipv4.isRFC1918 {
                return .privateLAN
            }
            return .publicInternet
        }

        if lowercased.contains(":") {
            if lowercased.hasPrefix("fe80:") || lowercased.hasPrefix("fc") || lowercased.hasPrefix("fd") || lowercased == "::1" {
                return .privateLAN
            }
            return .publicInternet
        }

        return lowercased.isEmpty ? .unknown : .hostname
    }

    var isTrustedPrivateScope: Bool {
        switch self {
        case .tailscale, .privateLAN, .localOnly:
            return true
        case .publicInternet, .hostname, .unknown:
            return false
        }
    }

    var connectionHint: String {
        switch self {
        case .tailscale:
            return "Traffic appears to be routed through Tailscale or its 100.64.0.0/10 address space."
        case .privateLAN:
            return "Traffic appears to be on a private LAN."
        case .localOnly:
            return "Traffic is local to this device or link-local network."
        case .publicInternet:
            return "This looks like a public address."
        case .hostname:
            return "This hostname cannot be classified; prefer Tailscale, VPN, or a private LAN."
        case .unknown:
            return "The network scope is unknown."
        }
    }

    var publicNetworkWarning: String? {
        switch self {
        case .publicInternet:
            return "Do not expose remote desktop services directly to the internet. Use Tailscale, VPN, or a private LAN."
        case .hostname, .unknown:
            return "Verify this host resolves inside Tailscale, VPN, or a private LAN before sending credentials."
        case .tailscale, .privateLAN, .localOnly:
            return nil
        }
    }
}

private nonisolated struct IPv4Address {
    let octets: [UInt8]

    init?(_ raw: String) {
        let parts = raw.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var values: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            values.append(value)
        }
        octets = values
    }

    var isLoopback: Bool {
        octets[0] == 127
    }

    var isLinkLocal: Bool {
        octets[0] == 169 && octets[1] == 254
    }

    var isTailscaleRange: Bool {
        octets[0] == 100 && (64...127).contains(octets[1])
    }

    var isRFC1918: Bool {
        octets[0] == 10 ||
        (octets[0] == 172 && (16...31).contains(octets[1])) ||
        (octets[0] == 192 && octets[1] == 168)
    }
}
