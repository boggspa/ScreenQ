//
//  DeviceRole.swift
//  Screen Q
//

import Foundation

/// The high-level user roles surfaced from the home screen. The role
/// gates which subsystem is started (capture, input injection, viewer, etc.)
/// and is purely a UX construct; it is not transmitted over the wire.
enum DeviceRole: String, CaseIterable, Identifiable, Codable, Sendable {
    /// macOS-only: turn this Mac into a controllable host.
    case hostMac
    /// macOS, iOS, iPadOS: connect to a remote host and view/control.
    case viewer
    /// Legacy iOS/iPadOS ReplayKit experiment. Kept for compatibility, not marketed.
    case iosScreenShare
    /// Any platform: read-only help screen explaining Apple-native alternatives.
    case appleNativeAlternatives

    var id: String { rawValue }

    static var primaryRoles: [DeviceRole] {
        [.hostMac, .viewer, .appleNativeAlternatives]
    }

    var title: String {
        switch self {
        case .hostMac:                  return "Host this Mac"
        case .viewer:                   return "Connect to a remote host"
        case .iosScreenShare:           return "Share this iPhone or iPad screen"
        case .appleNativeAlternatives:  return "Apple-native alternatives"
        }
    }

    var subtitle: String {
        switch self {
        case .hostMac:
            return "Let a paired viewer see and control this Mac after explicit consent."
        case .viewer:
            return "Discover Macs, connect by hostname / Tailscale name, or open Windows RDP."
        case .iosScreenShare:
            return "Legacy ReplayKit experiment. Use Apple-native options for iPhone and iPad."
        case .appleNativeAlternatives:
            return "iPhone Mirroring, FaceTime SharePlay, Universal Control, and Screen Sharing."
        }
    }

    var systemImage: String {
        switch self {
        case .hostMac:                  return "desktopcomputer"
        case .viewer:                   return "rectangle.connected.to.line.below"
        case .iosScreenShare:           return "iphone.gen3.radiowaves.left.and.right"
        case .appleNativeAlternatives:  return "sparkles.tv"
        }
    }

    /// True if the current platform can fulfill this role.
    var isSupportedOnCurrentPlatform: Bool {
        switch self {
        case .hostMac:
            #if os(macOS)
            return true
            #else
            return false
            #endif
        case .viewer:
            return true
        case .iosScreenShare:
            return false
        case .appleNativeAlternatives:
            return true
        }
    }
}
