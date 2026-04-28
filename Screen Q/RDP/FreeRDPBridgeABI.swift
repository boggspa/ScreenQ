//
//  FreeRDPBridgeABI.swift
//  Screen Q
//
//  Swift mirror of the runtime-loaded ScreenQFreeRDPBridge ABI. Keep this in
//  sync with ScreenQFreeRDPBridgeABI.h.
//

import Foundation

typealias SQFreeRDPEventCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void

nonisolated enum SQFreeRDPCertificateTrust: Int32 {
    case none = 0
    case trustOnce = 1
    case trustAlways = 2
    case reject = 3
}

nonisolated enum SQFreeRDPEventKind: Int32 {
    case connecting = 1
    case credentialsRequired = 2
    case certificateTrustRequired = 3
    case securityNegotiated = 4
    case connected = 5
    case frame = 6
    case disconnected = 7
    case error = 8
}

nonisolated enum SQFreeRDPInputKind: Int32 {
    case pointerMove = 1
    case pointerDown = 2
    case pointerUp = 3
    case scroll = 4
    case keyDown = 5
    case keyUp = 6
    case textInput = 7
}

nonisolated struct SQFreeRDPConfig {
    var host: UnsafePointer<CChar>?
    var port: UInt16
    var username: UnsafePointer<CChar>?
    var password: UnsafePointer<CChar>?
    var domain: UnsafePointer<CChar>?
    var gatewayHost: UnsafePointer<CChar>?
    var gatewayUsername: UnsafePointer<CChar>?
    var desktopWidth: Int32
    var desktopHeight: Int32
    var dynamicResolution: Int32
    var administrativeSession: Int32
    var connectToConsole: Int32
    var redirectClipboard: Int32
    var redirectAudio: Int32
    var allowFontSmoothing: Int32
    var certificateTrust: Int32
    var trustedCertificateFingerprintSHA256: UnsafePointer<CChar>?
}

nonisolated struct SQFreeRDPInputEvent {
    var kind: Int32
    var x: Double
    var y: Double
    var button: Int32
    var deltaX: Double
    var deltaY: Double
    var keyName: UnsafePointer<CChar>?
    var text: UnsafePointer<CChar>?
    var modifiers: UInt32
}

nonisolated struct SQFreeRDPEvent {
    var kind: Int32
    var statusCode: Int32
    var message: UnsafePointer<CChar>?
    var host: UnsafePointer<CChar>?
    var username: UnsafePointer<CChar>?
    var domain: UnsafePointer<CChar>?

    var width: Int32
    var height: Int32
    var bytesPerRow: Int32
    var frameData: UnsafeRawPointer?
    var frameDataLength: Int

    var tlsProtocol: UnsafePointer<CChar>?
    var nlaSucceeded: Int32
    var transportEncrypted: Int32
    var authenticated: Int32
    var identityVerified: Int32

    var certificateSubject: UnsafePointer<CChar>?
    var certificateIssuer: UnsafePointer<CChar>?
    var certificateFingerprintSHA256: UnsafePointer<CChar>?
    var certificateHost: UnsafePointer<CChar>?
    var certificateValidFromUnix: Double
    var certificateValidUntilUnix: Double
}
