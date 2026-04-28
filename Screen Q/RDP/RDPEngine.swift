//
//  RDPEngine.swift
//  Screen Q
//
//  Narrow boundary between SwiftUI session state and a future native RDP
//  implementation. The FreeRDP bridge should conform here and emit frames,
//  security updates, credential prompts, and disconnect events.
//

import Foundation
import CoreGraphics

nonisolated struct RDPCredentials: Codable, Hashable, Sendable {
    var domain: String?
    var username: String
    var password: String

    static func fromUserInput(domain: String?, username: String, password: String) -> RDPCredentials {
        let cleanedDomain = nilIfEmpty(domain)
        let cleanedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        if let separator = cleanedUsername.firstIndex(of: "\\") {
            let prefix = nilIfEmpty(String(cleanedUsername[..<separator]))
            let suffix = nilIfEmpty(String(cleanedUsername[cleanedUsername.index(after: separator)...]))
            if let prefix, let suffix {
                return RDPCredentials(domain: prefix, username: suffix, password: password)
            }
        }

        return RDPCredentials(domain: cleanedDomain, username: cleanedUsername, password: password)
    }

    var normalizedUsername: String {
        guard let domain, !domain.isEmpty else { return username }
        return "\(domain)\\\(username)"
    }

    private static func nilIfEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct RDPCredentialPrompt: Codable, Hashable, Sendable {
    var suggestedDomain: String?
    var suggestedUsername: String?
    var message: String

    static func initial(for profile: RDPConnectionProfile) -> RDPCredentialPrompt {
        RDPCredentialPrompt(
            suggestedDomain: profile.domain,
            suggestedUsername: profile.username,
            message: "Enter the Windows account allowed to use Remote Desktop on \(profile.host)."
        )
    }
}

nonisolated struct RDPCertificateInfo: Codable, Hashable, Identifiable, Sendable {
    var subject: String
    var issuer: String
    var fingerprintSHA256: String
    var validFrom: Date?
    var validUntil: Date?
    var host: String

    var id: String { fingerprintSHA256 }

    var commonName: String? {
        Self.extractCommonName(from: subject)
    }

    private static func extractCommonName(from subject: String) -> String? {
        let patterns = ["CN = ", "CN=", "cn = ", "cn="]
        for pattern in patterns {
            guard let range = subject.range(of: pattern) else { continue }
            let remainder = subject[range.upperBound...]
            let value = remainder
                .split { character in
                    character == "," || character == "/" || character == "\n" || character == "\r"
                }
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

nonisolated enum RDPCertificateTrustDecision: Codable, Hashable, Sendable {
    case trustOnce
    case trustAlways
    case reject
}

nonisolated struct RDPSecurityReport: Codable, Hashable, Sendable {
    var tlsProtocol: String?
    var nlaSucceeded: Bool
    var isTransportEncrypted: Bool
    var isAuthenticated: Bool
    var certificate: RDPCertificateInfo?
    var serverIdentityVerified: Bool
}

nonisolated enum RDPPixelFormat: String, Codable, Hashable, Sendable {
    /// 32-bit little-endian BGRA, matching the common FreeRDP bitmap output.
    case bgra8888
}

nonisolated struct RDPEngineFrame: Sendable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixelFormat: RDPPixelFormat
    var data: Data
    var timestamp: Date

    init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: RDPPixelFormat = .bgra8888,
        data: Data,
        timestamp: Date = Date()
    ) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.data = data
        self.timestamp = timestamp
    }

    func makeCGImage() -> CGImage? {
        guard width > 0,
              height > 0,
              bytesPerRow >= width * 4,
              data.count >= bytesPerRow * height,
              pixelFormat == .bgra8888,
              let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

nonisolated enum RDPEngineAvailability: Equatable, Sendable {
    case available
    case unavailable(detail: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var unavailableDetail: String? {
        if case .unavailable(let detail) = self { return detail }
        return nil
    }
}

nonisolated enum RDPEngineEvent: Sendable {
    case connecting
    case credentialsRequired(RDPCredentialPrompt)
    case certificateTrustRequired(RDPCertificateInfo)
    case securityNegotiated(RDPSecurityReport)
    case connected(width: Int, height: Int)
    case frame(RDPEngineFrame)
    case disconnected(reason: String?)
}

nonisolated enum RDPEngineError: LocalizedError, Sendable {
    case engineUnavailable(detail: String)
    case credentialsRejected(String)
    case certificateRejected
    case connectionFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let detail):
            return detail
        case .credentialsRejected(let detail):
            return detail
        case .certificateRejected:
            return "The RDP certificate was not trusted."
        case .connectionFailed(let detail):
            return detail
        case .unsupported(let detail):
            return detail
        }
    }
}

nonisolated enum RDPFailureClassifier {
    private static let freeRDPConnectErrorClass: UInt32 = 2

    static func isCredentialOrAccountFailure(statusCode: Int32, message: String?) -> Bool {
        if let connectErrorType = freeRDPConnectErrorType(statusCode),
           isCredentialOrAccountFailure(connectErrorType: connectErrorType) {
            return true
        }

        guard let message else { return false }
        let normalized = message.lowercased()
        return normalized.contains("authentication failure")
            || normalized.contains("logon failed")
            || normalized.contains("wrong password")
            || normalized.contains("credentials invalid")
            || normalized.contains("credentials are required")
            || normalized.contains("credentials invalid or missing")
            || normalized.contains("logon type not granted")
            || normalized.contains("insufficient privileges")
            || normalized.contains("account disabled")
            || normalized.contains("account locked")
            || normalized.contains("account expired")
            || normalized.contains("password has expired")
            || normalized.contains("password must be changed")
    }

    static func credentialRetryMessage(statusCode: Int32, message: String?) -> String {
        let detail = cleanFreeRDPDetail(message)
        switch freeRDPConnectErrorType(statusCode) {
        case 0x15:
            return "Windows rejected the password. Saved RDP credentials for this host were cleared so you can try again."
        case 0x14, 0x1B, 0x09:
            return "Windows rejected these RDP credentials. Saved credentials for this host were cleared so you can try another Windows account."
        case 0x16, 0x0A:
            return "Windows denied this RDP login. Try an administrator account or add the user to Remote Desktop Users on the PC."
        case 0x1A:
            return "Windows rejected this account for Remote Desktop logon. The account may not be allowed to sign in through RDP."
        case 0x18:
            return "This Windows account is locked out. Saved RDP credentials for this host were cleared."
        case 0x12:
            return "This Windows account is disabled. Saved RDP credentials for this host were cleared."
        case 0x19:
            return "This Windows account has expired. Saved RDP credentials for this host were cleared."
        case 0x0E, 0x0F, 0x13:
            return "Windows says this password must be changed before RDP can continue. Saved RDP credentials for this host were cleared."
        default:
            if let detail {
                return "\(detail) Saved RDP credentials for this host were cleared so you can try again."
            }
            return "Windows rejected this RDP login. Saved credentials for this host were cleared so you can try again."
        }
    }

    private static func freeRDPConnectErrorType(_ statusCode: Int32) -> UInt32? {
        let code = UInt32(bitPattern: statusCode)
        guard ((code >> 16) & 0xFFFF) == freeRDPConnectErrorClass else {
            return nil
        }
        return code & 0xFFFF
    }

    private static func isCredentialOrAccountFailure(connectErrorType: UInt32) -> Bool {
        switch connectErrorType {
        case 0x09, // authentication failed
             0x0A, // insufficient privileges
             0x0E, // password expired
             0x0F, // password certainly expired
             0x12, // account disabled
             0x13, // password must change
             0x14, // logon failure
             0x15, // wrong password
             0x16, // access denied
             0x17, // account restriction
             0x18, // account locked out
             0x19, // account expired
             0x1A, // logon type not granted
             0x1B: // no or missing credentials
            return true
        default:
            return false
        }
    }

    private static func cleanFreeRDPDetail(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefix = "FreeRDP failed to connect: "
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed
    }
}

@MainActor
protocol RDPEngine: AnyObject {
    var availability: RDPEngineAvailability { get }

    func connect(
        profile: RDPConnectionProfile,
        credentials: RDPCredentials,
        trustDecision: RDPCertificateTrustDecision?,
        trustedCertificateFingerprintSHA256: String?
    ) -> AsyncThrowingStream<RDPEngineEvent, Error>

    func disconnect() async
    func sendInput(_ event: RemoteInputEvent) async throws
    func resize(width: Int, height: Int, scale: Double) async throws
}

@MainActor
enum RDPEngineFactory {
    static func makeEngine() -> RDPEngine {
        FreeRDPEngine()
    }
}

@MainActor
final class UnavailableRDPEngine: RDPEngine {
    let availability: RDPEngineAvailability = .unavailable(
        detail: "The native FreeRDP bridge is not linked into this build. Screen Q can import and preflight RDP connections, but cannot negotiate TLS/NLA, render Windows frames, or send RDP input until that bridge is added."
    )

    func connect(
        profile: RDPConnectionProfile,
        credentials: RDPCredentials,
        trustDecision: RDPCertificateTrustDecision?,
        trustedCertificateFingerprintSHA256: String?
    ) -> AsyncThrowingStream<RDPEngineEvent, Error> {
        let detail = availability.unavailableDetail ?? "The RDP engine is unavailable."
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: RDPEngineError.engineUnavailable(detail: detail))
        }
    }

    func disconnect() async {}

    func sendInput(_ event: RemoteInputEvent) async throws {
        throw RDPEngineError.engineUnavailable(detail: availability.unavailableDetail ?? "The RDP engine is unavailable.")
    }

    func resize(width: Int, height: Int, scale: Double) async throws {
        throw RDPEngineError.engineUnavailable(detail: availability.unavailableDetail ?? "The RDP engine is unavailable.")
    }
}
