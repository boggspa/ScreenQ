//
//  RFBProtocol.swift
//  Screen Q
//
//  Wire format constants and types for the RFB (Remote Framebuffer) protocol
//  as defined in RFC 6143. Used by the native VNC client to connect to hosts
//  running Apple Screen Sharing or any standard VNC server.
//

import Foundation

nonisolated enum RFBConnectionProfile: String, Codable, Hashable, Sendable {
    case macScreenSharing
    case genericVNC

    var displayName: String {
        switch self {
        case .macScreenSharing: return "Mac Screen Sharing"
        case .genericVNC: return "Generic VNC"
        }
    }

    var securityIntro: String {
        switch self {
        case .macScreenSharing:
            return "Screen Q will prefer macOS account credentials when Apple Screen Sharing authentication is offered."
        case .genericVNC:
            return "Screen Q will use standard VNC authentication."
        }
    }
}

nonisolated enum RFBSecurityPreference: Sendable {
    case macAccountFirst
    case vncPasswordFirst
    case vncPasswordOnly
}

nonisolated struct RFBConnectionTimeouts: Sendable, Equatable {
    var tcpConnect: TimeInterval?
    var versionHandshake: TimeInterval?
    var securityNegotiation: TimeInterval?
    var serverInitialization: TimeInterval?

    static let `default` = RFBConnectionTimeouts(
        tcpConnect: 2.0,
        versionHandshake: 2.5,
        securityNegotiation: 3.0,
        serverInitialization: 3.0
    )
}

nonisolated enum RFBSecurityNegotiationPolicy {
    static func isModernAppleSecurityType(_ type: UInt8) -> Bool {
        type == RFBSecurityType.appleModern35.rawValue ||
            type == RFBSecurityType.appleModern36.rawValue
    }

    static func chooseSecurityType(
        offered types: [UInt8],
        hasUsername: Bool,
        preference: RFBSecurityPreference
    ) -> UInt8 {
        switch preference {
        case .macAccountFirst:
            if hasUsername, types.contains(RFBSecurityType.appleDH.rawValue) { return RFBSecurityType.appleDH.rawValue }
            if hasUsername, types.contains(RFBSecurityType.appleScreenSharing.rawValue) { return RFBSecurityType.appleScreenSharing.rawValue }
            if types.contains(RFBSecurityType.vncAuth.rawValue) { return RFBSecurityType.vncAuth.rawValue }
        case .vncPasswordFirst:
            if hasUsername, types.contains(RFBSecurityType.appleDH.rawValue) { return RFBSecurityType.appleDH.rawValue }
            if hasUsername, types.contains(RFBSecurityType.appleScreenSharing.rawValue) { return RFBSecurityType.appleScreenSharing.rawValue }
            if types.contains(RFBSecurityType.vncAuth.rawValue) { return RFBSecurityType.vncAuth.rawValue }
        case .vncPasswordOnly:
            if types.contains(RFBSecurityType.vncAuth.rawValue) { return RFBSecurityType.vncAuth.rawValue }
        }
        if types.contains(RFBSecurityType.none.rawValue) { return RFBSecurityType.none.rawValue }
        if types.contains(RFBSecurityType.appleScreenSharing.rawValue) { return RFBSecurityType.appleScreenSharing.rawValue }
        if types.contains(RFBSecurityType.appleDH.rawValue) { return RFBSecurityType.appleDH.rawValue }
        return types.first ?? RFBSecurityType.invalid.rawValue
    }

    static func chooseAppleWrappedSecurityType(
        offered types: [UInt8],
        hasUsername: Bool,
        preference: RFBSecurityPreference
    ) -> UInt8 {
        switch preference {
        case .macAccountFirst:
            if types.contains(RFBSecurityType.appleDH.rawValue) { return RFBSecurityType.appleDH.rawValue }
            if types.contains(RFBSecurityType.vncAuth.rawValue) { return RFBSecurityType.vncAuth.rawValue }
            if types.contains(RFBSecurityType.appleModern36.rawValue) { return RFBSecurityType.appleModern36.rawValue }
            if types.contains(RFBSecurityType.appleModern35.rawValue) { return RFBSecurityType.appleModern35.rawValue }
        case .vncPasswordFirst:
            if hasUsername, types.contains(RFBSecurityType.appleDH.rawValue) { return RFBSecurityType.appleDH.rawValue }
            if types.contains(RFBSecurityType.vncAuth.rawValue) { return RFBSecurityType.vncAuth.rawValue }
            if hasUsername, types.contains(RFBSecurityType.appleModern36.rawValue) { return RFBSecurityType.appleModern36.rawValue }
            if hasUsername, types.contains(RFBSecurityType.appleModern35.rawValue) { return RFBSecurityType.appleModern35.rawValue }
        case .vncPasswordOnly:
            if types.contains(RFBSecurityType.vncAuth.rawValue) { return RFBSecurityType.vncAuth.rawValue }
        }
        return RFBSecurityType.invalid.rawValue
    }
}

// MARK: - Security Types

nonisolated enum RFBSecurityType: UInt8, Sendable {
    case invalid  = 0
    case none     = 1
    case vncAuth  = 2
    // Apple-specific (macOS Screen Sharing)
    case appleDH            = 30
    case appleScreenSharing = 33
    case appleModern35      = 35
    case appleModern36      = 36
}

nonisolated enum RFBSecurityMode: String, Codable, Hashable, Sendable {
    case none
    case vncAuth
    case appleDH
    case appleScreenSharing
    case appleModern35
    case appleModern36
    case unknown

    init(type: UInt8?) {
        switch type {
        case RFBSecurityType.none.rawValue:
            self = .none
        case RFBSecurityType.vncAuth.rawValue:
            self = .vncAuth
        case RFBSecurityType.appleDH.rawValue:
            self = .appleDH
        case RFBSecurityType.appleScreenSharing.rawValue:
            self = .appleScreenSharing
        case RFBSecurityType.appleModern35.rawValue:
            self = .appleModern35
        case RFBSecurityType.appleModern36.rawValue:
            self = .appleModern36
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .vncAuth: return "VNC Auth"
        case .appleDH: return "Apple DH"
        case .appleScreenSharing: return "Apple Screen Sharing"
        case .appleModern35: return "Apple Screen Sharing 35"
        case .appleModern36: return "Apple Screen Sharing 36"
        case .unknown: return "Unknown"
        }
    }

    var securityDescription: String {
        switch self {
        case .none:
            return "The server did not require VNC authentication and RFB traffic is not encrypted by VNC"
        case .vncAuth:
            return "VNC password authentication is legacy challenge-response auth; RFB traffic is not encrypted by VNC"
        case .appleDH:
            return "Apple DH protects the credential exchange, but the RFB session itself is not end-to-end encrypted by Screen Q"
        case .appleScreenSharing:
            return "Apple Screen Sharing authentication was negotiated; Screen Q has not verified end-to-end RFB transport encryption for this path"
        case .appleModern35, .appleModern36:
            return "This Mac offered a newer private Apple Screen Sharing authentication dialect that Screen Q does not yet complete"
        case .unknown:
            return "Screen Q could not determine the negotiated VNC security mode"
        }
    }

    var isModernAppleAccountAuth: Bool {
        self == .appleModern35 || self == .appleModern36
    }
}

nonisolated struct RFBSecurityReport: Codable, Hashable, Sendable {
    var mode: RFBSecurityMode
    var offeredModes: [RFBSecurityMode]

    var offeredModesDescription: String? {
        let names = offeredModes.map(\.displayName)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    var unsupportedModernAppleModes: [RFBSecurityMode] {
        offeredModes.filter(\.isModernAppleAccountAuth)
    }

    var hasSupportedCredentialFallback: Bool {
        offeredModes.contains(.appleDH) || offeredModes.contains(.vncAuth) || offeredModes.contains(.none)
    }

    var requiresUnsupportedModernAppleAuth: Bool {
        mode.isModernAppleAccountAuth && !hasSupportedCredentialFallback
    }
}

// MARK: - Encoding Types

nonisolated enum RFBEncoding: Int32, Sendable {
    case raw         = 0
    case copyRect    = 1
    case rre         = 2
    case hextile     = 5
    case tight       = 7
    case zrle        = 16
    // Pseudo-encodings
    case cursor              = -239
    case tightPNG            = -260
    case lastRect            = -224
    case desktopSize         = -223
    case extendedDesktopSize = -308
    case qemuExtendedKeyEvent = -258
}

// MARK: - Client → Server Message Types

nonisolated enum RFBClientMessageType: UInt8, Sendable {
    case setPixelFormat            = 0
    case setEncodings              = 2
    case framebufferUpdateRequest  = 3
    case keyEvent                  = 4
    case pointerEvent              = 5
    case clientCutText             = 6
    case setDesktopSize            = 251
    case qemuClientMessage         = 255
}

nonisolated enum RFBQemuSubMessage: UInt8, Sendable {
    case extendedKeyEvent = 0
}

// MARK: - Server → Client Message Types

nonisolated enum RFBServerMessageType: UInt8, Sendable {
    case framebufferUpdate    = 0
    case setColourMapEntries  = 1
    case bell                 = 2
    case serverCutText        = 3
}

// MARK: - Pixel Format

nonisolated struct RFBPixelFormat: Sendable {
    var bitsPerPixel: UInt8 = 32
    var depth: UInt8 = 24
    var bigEndian: UInt8 = 0
    var trueColour: UInt8 = 1
    var redMax: UInt16 = 255
    var greenMax: UInt16 = 255
    var blueMax: UInt16 = 255
    var redShift: UInt8 = 16
    var greenShift: UInt8 = 8
    var blueShift: UInt8 = 0

    var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    func encode() -> Data {
        var d = Data(count: 16)
        d[0] = bitsPerPixel
        d[1] = depth
        d[2] = bigEndian
        d[3] = trueColour
        d[4] = UInt8(redMax >> 8); d[5] = UInt8(redMax & 0xFF)
        d[6] = UInt8(greenMax >> 8); d[7] = UInt8(greenMax & 0xFF)
        d[8] = UInt8(blueMax >> 8); d[9] = UInt8(blueMax & 0xFF)
        d[10] = redShift
        d[11] = greenShift
        d[12] = blueShift
        d[13] = 0; d[14] = 0; d[15] = 0
        return d
    }

    static func decode(from data: Data) -> RFBPixelFormat {
        var pf = RFBPixelFormat()
        guard data.count >= 16 else { return pf }
        pf.bitsPerPixel = data[0]
        pf.depth = data[1]
        pf.bigEndian = data[2]
        pf.trueColour = data[3]
        pf.redMax = UInt16(data[4]) << 8 | UInt16(data[5])
        pf.greenMax = UInt16(data[6]) << 8 | UInt16(data[7])
        pf.blueMax = UInt16(data[8]) << 8 | UInt16(data[9])
        pf.redShift = data[10]
        pf.greenShift = data[11]
        pf.blueShift = data[12]
        return pf
    }

    /// 32bpp XRGB little-endian — matches CGBitmapContext noneSkipFirst + byteOrder32Little.
    static let xrgb32: RFBPixelFormat = {
        var pf = RFBPixelFormat()
        pf.bitsPerPixel = 32
        pf.depth = 24
        pf.bigEndian = 0
        pf.trueColour = 1
        pf.redMax = 255; pf.greenMax = 255; pf.blueMax = 255
        pf.redShift = 16; pf.greenShift = 8; pf.blueShift = 0
        return pf
    }()
}

// MARK: - Server Init

nonisolated struct RFBServerInit: Sendable {
    var width: UInt16
    var height: UInt16
    var pixelFormat: RFBPixelFormat
    var name: String
}

// MARK: - Framebuffer Update Rectangle

nonisolated struct RFBRect: Sendable {
    var x: UInt16
    var y: UInt16
    var width: UInt16
    var height: UInt16
    var encoding: Int32
    var data: Data
}

// MARK: - Errors

nonisolated enum RFBError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case protocolError(String)
    case timeout(stage: String)
    case authFailed(String)
    case authRequired            // VNC password only (type 2)
    case credentialsRequired     // macOS username + password (Apple DH type 30)
    case unsupportedSecurity(UInt8)
    case unsupportedEncoding(Int32)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return "VNC connection failed: \(s)"
        case .protocolError(let s):    return "RFB protocol error: \(s)"
        case .timeout(let stage):       return "Timed out during \(stage)"
        case .authFailed(let s):       return "Authentication failed: \(s)"
        case .authRequired:            return "VNC password required"
        case .credentialsRequired:     return "macOS username and password required"
        case .unsupportedSecurity(let t):
            switch t {
            case RFBSecurityType.appleModern35.rawValue, RFBSecurityType.appleModern36.rawValue:
                return "Unsupported Apple Screen Sharing security type \(t): this server requires Apple's newer private RSA/SRP account-auth dialect"
            case RFBSecurityType.appleScreenSharing.rawValue:
                return "Unsupported Apple Screen Sharing security wrapper"
            default:
                return "Unsupported security type: \(t)"
            }
        case .unsupportedEncoding(let e): return "Unsupported framebuffer encoding: \(e)"
        case .disconnected:            return "VNC server disconnected"
        }
    }
}
