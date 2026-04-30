//
//  PeerDevice.swift
//  Screen Q
//

import Foundation

/// Light, UI-friendly description of a peer Screen Q device. Used in
/// discovery lists and for the connecting handshake.
nonisolated struct PeerDevice: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var platform: PeerPlatform
    var appVersion: String
    var capabilities: Capabilities

    static var unknown: PeerDevice {
        PeerDevice(
            id: UUID(),
            displayName: "Unknown peer",
            platform: .unknown,
            appVersion: "?",
            capabilities: .viewerOnly
        )
    }
}

nonisolated enum PeerPlatform: String, Codable, Sendable {
    case macOS
    case iOS
    case iPadOS
    case visionOS
    case windows
    case unknown

    var human: String {
        switch self {
        case .macOS:    return "Mac"
        case .iOS:      return "iPhone"
        case .iPadOS:   return "iPad"
        case .visionOS: return "Vision"
        case .windows:  return "Windows PC"
        case .unknown:  return "Device"
        }
    }
}

/// How was this host discovered?
nonisolated enum DiscoverySource: String, Codable, Sendable, Hashable {
    case screenQ   // _screenq._tcp — runs Screen Q
    case rfb       // _rfb._tcp — Apple Screen Sharing / VNC
}

/// Bonjour-discovered host before pairing. Has no negotiated identity yet.
nonisolated struct DiscoveredHost: Identifiable, Hashable, Sendable {
    let id: String           // Bonjour endpoint identity (name)
    let displayName: String
    let txtRecord: [String: String]
    let endpointDescription: String
    var source: DiscoverySource = .screenQ
    /// The Bonjour service name (for resolving to vnc:// URL).
    var serviceName: String? = nil

    var advertisedAppVersion: String? { txtRecord["version"] }
    var advertisedPlatform: String?   { txtRecord["platform"] }
    var advertisesControl: Bool       { txtRecord["supportsControl"] == "true" }
    var advertisesVideo: Bool         { txtRecord["supportsVideo"] == "true" }
    var advertisedDeviceID: String?   { txtRecord[ScreenQProtocol.TXT.deviceID] }
    var advertisedPresence: String?   { txtRecord[ScreenQProtocol.TXT.presence] }
    var advertisedStatus: String?     { txtRecord[ScreenQProtocol.TXT.status] }
    var supportsReplayKit: Bool       { txtRecord[ScreenQProtocol.TXT.supportsReplayKit] == "true" }
    var acceptsScreenQConnection: Bool {
        txtRecord[ScreenQProtocol.TXT.acceptsScreenQ] != "false"
    }
    var isAppleMobilePlatform: Bool {
        advertisedPlatform == "iOS" || advertisedPlatform == "iPadOS"
    }
    var isIOSShareOnlyPresence: Bool {
        source == .screenQ && isAppleMobilePlatform && supportsReplayKit && !acceptsScreenQConnection
    }
    var isRFB: Bool { source == .rfb }
}

nonisolated enum PendingViewerConnection: Identifiable, Equatable, Sendable {
    case screenQ(DiscoveredHost)
    case macScreenSharing(DiscoveredHost)
    case manual(host: String, port: UInt16, displayName: String, connectionProtocol: RemoteConnectionProtocol)

    var id: String {
        switch self {
        case .screenQ(let host):
            return "screenq:\(host.id)"
        case .macScreenSharing(let host):
            return "rfb:\(host.id)"
        case .manual(let host, let port, _, let connectionProtocol):
            return "manual:\(connectionProtocol.rawValue):\(host):\(port)"
        }
    }

    var displayName: String {
        switch self {
        case .screenQ(let host), .macScreenSharing(let host):
            return host.displayName
        case .manual(_, _, let displayName, _):
            return displayName
        }
    }
}

/// A peer the user has previously approved for control. Stored locally only.
nonisolated struct TrustedPeer: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var fingerprint: String   // hex-encoded hash of long-lived public key
    var lastSeen: Date
    var accessPolicy: TrustedPeerAccessPolicy

    init(
        id: UUID,
        displayName: String,
        fingerprint: String,
        lastSeen: Date,
        accessPolicy: TrustedPeerAccessPolicy = .askEveryTime
    ) {
        self.id = id
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.lastSeen = lastSeen
        self.accessPolicy = accessPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case fingerprint
        case lastSeen
        case accessPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        accessPolicy = try container.decodeIfPresent(TrustedPeerAccessPolicy.self, forKey: .accessPolicy) ?? .askEveryTime
    }
}

nonisolated enum TrustedPeerAccessPolicy: String, Codable, Hashable, Sendable {
    case askEveryTime
    case alwaysAllow
    case alwaysDeny
}
