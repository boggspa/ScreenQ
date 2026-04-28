//
//  TailnetDevice.swift
//  Screen Q
//
//  UI-facing representation of devices returned by Tailscale's tailnet API.
//  Tailnet discovery gives us reachability hints; the selected remote protocol
//  still performs its own authentication and security checks.
//

import Foundation

nonisolated struct TailnetDevice: Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var hostname: String?
    var os: String?
    var addresses: [String]
    var isOnline: Bool?
    var lastSeen: Date?
    var tags: [String]
    var isExternal: Bool

    var primaryAddress: String? {
        addresses.first(where: { $0.hasPrefix("100.") })
            ?? addresses.first(where: { $0.contains(".") })
            ?? addresses.first
    }

    var platform: PeerPlatform {
        let lowered = (os ?? "").lowercased()
        if lowered.contains("windows") { return .windows }
        if lowered.contains("mac") || lowered.contains("darwin") { return .macOS }
        if lowered.contains("ios") { return .iOS }
        return .unknown
    }

    var recommendedProtocol: RemoteConnectionProtocol {
        switch platform {
        case .windows:
            return .rdp
        case .macOS:
            return .macScreenSharing
        default:
            return .screenQ
        }
    }

    var recommendedPort: UInt16 {
        recommendedProtocol.defaultPort
    }

    var connectionHost: String? {
        primaryAddress ?? hostname
    }

    var statusText: String {
        if let isOnline {
            return isOnline ? "Online" : "Offline"
        }
        if lastSeen != nil {
            return "Seen recently"
        }
        return "Tailnet device"
    }

    var symbolName: String {
        switch platform {
        case .windows: return "pc"
        case .macOS: return "desktopcomputer"
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        case .visionOS: return "visionpro"
        case .unknown: return "network"
        }
    }
}

nonisolated enum TailnetDiscoveryPhase: Equatable, Sendable {
    case signedOut
    case idle
    case loading
    case loaded(count: Int)
    case failed(String)
}

nonisolated struct TailnetDiscoveryStatus: Equatable, Sendable {
    var phase: TailnetDiscoveryPhase = .signedOut

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var summary: String {
        switch phase {
        case .signedOut:
            return "Connect Tailscale to list tailnet devices here."
        case .idle:
            return "Tailnet discovery is ready."
        case .loading:
            return "Loading tailnet devices..."
        case .loaded(let count):
            return "Found \(count) tailnet device\(count == 1 ? "" : "s")"
        case .failed(let message):
            return message
        }
    }
}
