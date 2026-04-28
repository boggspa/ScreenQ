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
    var isRFB: Bool { source == .rfb }
}

/// A peer the user has previously approved for control. Stored locally only.
nonisolated struct TrustedPeer: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var fingerprint: String   // hex-encoded hash of long-lived public key
    var lastSeen: Date
}
