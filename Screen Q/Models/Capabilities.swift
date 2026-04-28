//
//  Capabilities.swift
//  Screen Q
//

import Foundation

/// What this peer can do. Sent over the wire in the hello message so the
/// other side can adapt its UI (for example: hide control buttons when the
/// host is iOS/iPadOS and only supports view-only ReplayKit sharing).
nonisolated struct Capabilities: Codable, Hashable, Sendable {
    var supportsVideo: Bool
    var supportsControl: Bool
    var supportsAudio: Bool
    var supportsClipboard: Bool
    var maxDisplays: Int
    var encodings: [VideoEncoding]

    static var viewerOnly: Capabilities {
        Capabilities(
            supportsVideo: false,
            supportsControl: false,
            supportsAudio: false,
            supportsClipboard: false,
            maxDisplays: 0,
            encodings: []
        )
    }

    static var macHostDefault: Capabilities {
        Capabilities(
            supportsVideo: true,
            supportsControl: true,
            supportsAudio: false,
            supportsClipboard: false,
            maxDisplays: 1,
            encodings: [.jpeg, .h264]
        )
    }

    static var iosViewOnlyHost: Capabilities {
        Capabilities(
            supportsVideo: true,
            supportsControl: false,   // iOS / iPadOS cannot accept input from third-party apps
            supportsAudio: false,
            supportsClipboard: false,
            maxDisplays: 1,
            encodings: [.jpeg]
        )
    }
}

nonisolated enum VideoEncoding: String, Codable, Hashable, Sendable {
    case jpeg
    case h264
}
