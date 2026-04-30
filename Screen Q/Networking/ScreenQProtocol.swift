//
//  ScreenQProtocol.swift
//  Screen Q
//
//  Wire format for the Screen Q LAN/Tailscale protocol. We use a small
//  length-prefixed binary frame that wraps either:
//   - a JSON control message, or
//   - an opaque binary payload (e.g. JPEG / H.264).
//
//  Header (24 bytes, big-endian):
//
//    UInt32 magic       0x53513031 ("SQ01")
//    UInt16 version     1
//    UInt16 type        MessageType raw value
//    UInt16 flags       reserved
//    UInt16 reserved    0
//    UInt64 sequence    monotonically increasing per-direction
//    UInt32 bodyLength  bytes that follow this header
//
//  Body layout per type:
//   - JSON messages: UTF-8 JSON of the typed Codable struct
//   - videoFrame: JSON header (VideoFrameMeta) prefixed with UInt32 length
//                 followed by raw payload bytes
//

import Foundation

nonisolated enum ScreenQProtocol {
    static let magic: UInt32 = 0x53513031   // "SQ01"
    static let version: UInt16 = 1
    static let headerSize: Int = 24
    /// Default LAN/Tailscale port. Avoids 5900 (VNC/RFB).
    static let defaultPort: UInt16 = 38745
    /// Bonjour service type for Screen Q hosts.
    static let bonjourServiceType: String = "_screenq._tcp"
    /// Apple Mac Screen Sharing/VNC discovery hint, optional.
    static let rfbServiceType: String = "_rfb._tcp"
    /// TXT keys.
    enum TXT {
        static let app = "app"
        static let version = "version"
        static let platform = "platform"
        static let supportsControl = "supportsControl"
        static let supportsVideo = "supportsVideo"
        static let deviceName = "deviceName"
        static let deviceID = "deviceID"
        static let presence = "presence"
        static let supportsReplayKit = "supportsReplayKit"
        static let acceptsScreenQ = "acceptsScreenQ"
        static let status = "status"
    }

    enum Flags {
        /// Body bytes are ChaChaPoly sealed. The frame header stays clear so
        /// the stream decoder can preserve message boundaries.
        static let encryptedBody: UInt16 = 1 << 0
    }
}

nonisolated enum MessageType: UInt16, Codable, Sendable {
    case hello             = 1
    case helloAck          = 2
    case pairingRequest    = 3
    case pairingChallenge  = 4
    case pairingResponse   = 5
    case pairingApproved   = 6
    case pairingRejected   = 7
    case videoFormat       = 10
    case videoFrame        = 11
    case cursorUpdate      = 12
    case inputEvent        = 20
    case clipboardOffer    = 30
    case clipboardRequest  = 31
    case clipboardData     = 32
    case audioFormat       = 35
    case audioFrame        = 36
    case displayList       = 37
    case displaySwitch     = 38
    case reconnectToken    = 39
    case stats             = 40
    case fileOffer         = 41
    case fileAccept        = 42
    case fileReject        = 43
    case fileChunk         = 44
    case fileComplete      = 45
    case remoteCommand     = 46
    case commandOutput     = 47
    case systemAction      = 48
    case systemActionResult = 49
    case ping              = 50
    case pong              = 51
    case systemReportRequest = 55
    case systemReport      = 56
    case packageInstallReq = 57
    case packageInstallResult = 58
    case streamQuality    = 59
    case error             = 60
    case viewerViewport    = 61
    case endSession        = 99
}

nonisolated struct ScreenQHeader: Sendable, Equatable {
    var magic: UInt32 = ScreenQProtocol.magic
    var version: UInt16 = ScreenQProtocol.version
    var type: MessageType
    var flags: UInt16 = 0
    var reserved: UInt16 = 0
    var sequence: UInt64
    var bodyLength: UInt32
}

// MARK: - Control Messages

/// Sent by the connecting side (typically viewer) right after TCP connect.
nonisolated struct HelloMessage: Codable, Sendable {
    var peerID: UUID
    var displayName: String
    var platform: PeerPlatform
    var appVersion: String
    var capabilities: Capabilities
    /// Caller's ephemeral X25519 public key (raw 32 bytes, base64), if encryption negotiated.
    var ephemeralPublicKey: String?
    /// Long-lived signing identity public key (raw base64). Used only for
    /// trusted-peer pinning; it is not a secret.
    var identityPublicKey: String?
    /// Signature binding this hello to the ephemeral key and device identity.
    var identitySignature: String?
}

/// Sent by the listening side (typically host) in response.
nonisolated struct HelloAckMessage: Codable, Sendable {
    var peerID: UUID
    var displayName: String
    var platform: PeerPlatform
    var appVersion: String
    var capabilities: Capabilities
    var ephemeralPublicKey: String?
    var identityPublicKey: String?
    var identitySignature: String?
    /// True once host has chosen an encryption mode and required body bytes
    /// to be encrypted with the derived symmetric key.
    var encryptionEnabled: Bool
    /// True when the host recognises this viewer as a previously trusted peer.
    /// The viewer can skip showing the pairing code UI and wait for auto-approval.
    var trustedByHost: Bool?
}

/// Pairing request from viewer to host. Includes the 6-digit code the user
/// is reading off the host's screen.
nonisolated struct PairingRequestMessage: Codable, Sendable {
    var viewerID: UUID
    var displayName: String
    var claimedCode: String
}

/// Optional follow-up for a more elaborate challenge/response. Reserved.
nonisolated struct PairingChallengeMessage: Codable, Sendable {
    var nonce: String
}

nonisolated struct PairingResponseMessage: Codable, Sendable {
    var nonce: String
    var signature: String
}

nonisolated struct PairingApprovedMessage: Codable, Sendable {
    var sessionID: UUID
    var hostCapabilities: Capabilities
    /// True only if the user explicitly enabled control on the host.
    var controlEnabled: Bool
    /// Granular permission flags. If nil, falls back to controlEnabled boolean.
    var permissions: PermissionSet?
}

nonisolated struct PairingRejectedMessage: Codable, Sendable {
    var reason: String
}

nonisolated struct ErrorMessage: Codable, Sendable {
    var code: String
    var message: String
}

nonisolated struct PingMessage: Codable, Sendable {
    var clientTimestamp: TimeInterval
}

nonisolated struct PongMessage: Codable, Sendable {
    var clientTimestamp: TimeInterval
    var serverTimestamp: TimeInterval
}

nonisolated struct StatsMessage: Codable, Sendable {
    var fps: Double
    var bytesPerSecond: Double
    var droppedFrames: Int
    var roundTripMillis: Double
}

nonisolated struct EndSessionMessage: Codable, Sendable {
    var reason: String
}

// MARK: - Cursor

nonisolated struct CursorUpdateMessage: Codable, Sendable {
    var x: Double           // normalised 0..1
    var y: Double           // normalised 0..1
    var visible: Bool
    var cursorType: String  // "arrow", "iBeam", "pointingHand", etc.
    var imageData: String?  // base64-encoded PNG of the actual cursor bitmap (optional)
    var hotSpotX: Double?   // cursor hot spot normalised to image size
    var hotSpotY: Double?
}

// MARK: - Clipboard

nonisolated struct ClipboardOfferMessage: Codable, Sendable {
    var changeCount: Int
    var availableTypes: [String]  // UTI strings
}

nonisolated struct ClipboardRequestMessage: Codable, Sendable {
    var requestedType: String  // UTI
}

nonisolated struct ClipboardDataMessage: Codable, Sendable {
    var type: String  // UTI
    var base64Data: String
}

// MARK: - Audio

nonisolated struct AudioFormatMessage: Codable, Sendable {
    var sampleRate: Double
    var channels: Int
    var codec: String  // "aac", "opus", "pcm"
    var bitsPerSample: Int
}

// MARK: - Multi-display

nonisolated struct DisplayInfo: Codable, Sendable, Identifiable {
    var id: UInt32
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
    var isMain: Bool
}

nonisolated struct DisplayListMessage: Codable, Sendable {
    var displays: [DisplayInfo]
    var activeDisplayID: UInt32
}

nonisolated struct DisplaySwitchMessage: Codable, Sendable {
    var displayID: UInt32
}

/// Viewer-side local viewport hint for native Screen Q adaptive streaming.
/// The host keeps input coordinates mapped to the full display; this is only
/// used to choose a sharper capture scale when the viewer zooms in.
nonisolated struct ViewerViewportMessage: Codable, Hashable, Sendable {
    var displayID: UInt32?
    var zoomScale: Double
    var visibleRect: NormalisedRect
    var canvasPixelWidth: Int
    var canvasPixelHeight: Int
    var adaptiveEnabled: Bool
    var timestamp: TimeInterval
}

// MARK: - Reconnect

nonisolated struct ReconnectTokenMessage: Codable, Sendable {
    var token: String
    var validUntil: TimeInterval  // epoch
}

// MARK: - File Transfer

/// Sent to offer a file to the remote side.
nonisolated struct FileOfferMessage: Codable, Sendable {
    var transferID: UUID
    var fileName: String
    var fileSize: Int64
    var mimeType: String
    var chunkSize: Int  // bytes per chunk
}

/// Sent to accept an incoming file offer.
nonisolated struct FileAcceptMessage: Codable, Sendable {
    var transferID: UUID
}

/// Sent to reject an incoming file offer.
nonisolated struct FileRejectMessage: Codable, Sendable {
    var transferID: UUID
    var reason: String
}

/// A single chunk of file data. Chunks are base64-encoded for JSON transport.
nonisolated struct FileChunkMessage: Codable, Sendable {
    var transferID: UUID
    var chunkIndex: Int
    var base64Data: String
    var isLast: Bool
}

/// Confirmation that the full file was received and written.
nonisolated struct FileCompleteMessage: Codable, Sendable {
    var transferID: UUID
    var success: Bool
    var savedPath: String?
}

// MARK: - Remote Command

/// Request to execute a shell command on the host.
nonisolated struct RemoteCommandMessage: Codable, Sendable {
    var commandID: UUID
    var command: String      // e.g. "/bin/bash"
    var arguments: [String]  // e.g. ["-c", "ls -la /tmp"]
    var workingDirectory: String?
    var environment: [String: String]?
    var timeout: TimeInterval?  // seconds; nil = no timeout
}

/// Streamed output from a running remote command.
nonisolated struct CommandOutputMessage: Codable, Sendable {
    var commandID: UUID
    var stream: OutputStream  // stdout or stderr
    var base64Data: String
    var isComplete: Bool
    var exitCode: Int32?

    enum OutputStream: String, Codable, Sendable {
        case stdout
        case stderr
    }
}

// MARK: - System Actions

/// Request to perform a system action on the host.
nonisolated struct SystemActionMessage: Codable, Sendable {
    var actionID: UUID
    var action: SystemAction

    enum SystemAction: String, Codable, Sendable {
        case restart
        case shutdown
        case sleep
        case wake
        case logOut
        case lockScreen
    }
}

/// Result of a system action.
nonisolated struct SystemActionResultMessage: Codable, Sendable {
    var actionID: UUID
    var success: Bool
    var message: String?
}

// MARK: - System Report

/// Request the host to send a system report.
nonisolated struct SystemReportRequestMessage: Codable, Sendable {
    var requestID: UUID
}

/// Comprehensive system information from the host.
nonisolated struct SystemReportMessage: Codable, Sendable {
    var requestID: UUID
    var hostname: String
    var macOSVersion: String
    var buildNumber: String
    var hardwareModel: String
    var serialNumber: String?
    var cpuType: String
    var cpuCoreCount: Int
    var memoryGB: Double
    var diskTotalGB: Double
    var diskFreeGB: Double
    var uptimeSeconds: TimeInterval
    var ipAddresses: [String]
    var installedApps: [InstalledApp]

    struct InstalledApp: Codable, Sendable {
        var name: String
        var version: String?
        var bundleID: String?
    }
}

// MARK: - Package Install

/// Request to install a package on the host. The .pkg must already have
/// been transferred via FileTransferService.
nonisolated struct PackageInstallRequestMessage: Codable, Sendable {
    var installID: UUID
    var fileName: String      // name of the file in the downloads directory
    var targetVolume: String   // e.g. "/"
}

nonisolated struct PackageInstallResultMessage: Codable, Sendable {
    var installID: UUID
    var success: Bool
    var output: String
}
