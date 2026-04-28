//
//  SessionState.swift
//  Screen Q
//

import Foundation

/// Lifecycle of an active Screen Q session as observed from either side
/// (host or viewer). Both sides use this so UI affordances mirror exactly.
nonisolated enum SessionState: Equatable, Sendable {
    case idle
    case advertising                // host is advertising via Bonjour
    case browsing                   // viewer is browsing for hosts
    case connecting(host: String)   // viewer dialing TCP/Bonjour endpoint
    case handshake                  // hello/helloAck in flight
    case awaitingPairingCode        // viewer side, waiting for user to enter pair code
    case awaitingHostApproval       // pairingRequest sent, waiting host
    case approved                   // approval received, ready for video
    case streaming                  // video flowing
    case viewOnly                   // streaming but control disabled
    case ended(reason: String)      // session closed
    case failed(reason: String)

    var isActive: Bool {
        switch self {
        case .idle, .ended, .failed: return false
        default: return true
        }
    }

    var allowsInputInjection: Bool {
        switch self {
        case .streaming, .approved: return true
        default: return false
        }
    }

    var humanDescription: String {
        switch self {
        case .idle:                  return "Idle"
        case .advertising:           return "Advertising on local network"
        case .browsing:              return "Looking for nearby hosts"
        case .connecting(let host):  return "Connecting to \(host)"
        case .handshake:             return "Negotiating session"
        case .awaitingPairingCode:   return "Enter the 6-digit code shown on the host"
        case .awaitingHostApproval:  return "Waiting for host approval"
        case .approved:              return "Approved"
        case .streaming:             return "Streaming"
        case .viewOnly:              return "Streaming (view only)"
        case .ended(let reason):     return "Ended: \(reason)"
        case .failed(let reason):    return "Failed: \(reason)"
        }
    }
}

/// Pairing request as it appears on the host.
nonisolated struct PairingRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let viewer: PeerDevice
    let receivedAt: Date
    /// The code the viewer claims to have read off the host screen.
    let claimedCode: String
    /// Verified fingerprint of the viewer's long-lived signing identity.
    let identityFingerprint: String?
    /// True when the host already trusts this device identity and only needs
    /// local approval for the new session/permission grant.
    let trustedReconnect: Bool
}
