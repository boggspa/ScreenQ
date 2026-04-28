//
//  DeviceRole.swift
//  Screen Q
//

import Foundation

/// The four high-level user roles surfaced from the home screen. The role
/// gates which subsystem is started (capture, input injection, viewer, etc.)
/// and is purely a UX construct; it is not transmitted over the wire.
enum DeviceRole: String, CaseIterable, Identifiable, Codable {
    /// macOS-only: turn this Mac into a controllable host.
    case hostMac
    /// macOS, iOS, iPadOS, visionOS: connect to a Screen Q host and view/control.
    case viewer
    /// iOS, iPadOS only: share this device's screen view-only via ReplayKit.
    case iosScreenShare
    /// Any platform: read-only help screen explaining Apple-native alternatives.
    case appleNativeAlternatives

    var id: String { rawValue }

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
            return "Discover hosts on your network or connect by hostname / Tailscale name."
        case .iosScreenShare:
            return "View-only screen sharing using ReplayKit. Touch control is not possible."
        case .appleNativeAlternatives:
            return "FaceTime SharePlay, iPhone Mirroring, Universal Control, and Screen Sharing."
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
            #if os(iOS)
            return true
            #else
            return false
            #endif
        case .appleNativeAlternatives:
            return true
        }
    }
}
