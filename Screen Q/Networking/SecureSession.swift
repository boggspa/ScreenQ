//
//  SecureSession.swift
//  Screen Q
//
//  Optional symmetric encryption for the Screen Q transport. We do an
//  X25519 key agreement during hello/helloAck, derive a session key with
//  HKDF-SHA256, and seal/open each message body with ChaChaPoly using a
//  monotonically increasing nonce counter.
//
//  Constraints:
//   - We never auto-accept unknown peers; encryption alone does not imply
//     authentication. Pairing-code consent is still mandatory.
//   - Failure to seal/open is treated as a session-level error.
//   - Pairing codes, derived keys, and ephemeral secrets are never logged.
//

import Foundation
import CryptoKit

nonisolated struct SecureSessionKeyMaterial {
    let outboundKey: SymmetricKey
    let inboundKey: SymmetricKey
    /// Hex SHA-256 of the peer's public key. Used as a stable fingerprint.
    let peerFingerprint: String
}

nonisolated enum SecureSessionRole: Sendable {
    case viewer
    case host
}

nonisolated final class SecureSessionFactory {

    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    func deriveKey(peerPublicKeyBase64: String, salt: Data, info: Data, role: SecureSessionRole) throws -> SecureSessionKeyMaterial {
        guard let raw = Data(base64Encoded: peerPublicKeyBase64) else {
            throw SecureSessionError.badPublicKey
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let viewerToHost = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info + Data("viewer-to-host".utf8),
            outputByteCount: 32
        )
        let hostToViewer = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info + Data("host-to-viewer".utf8),
            outputByteCount: 32
        )
        let fingerprint = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        switch role {
        case .viewer:
            return SecureSessionKeyMaterial(outboundKey: viewerToHost, inboundKey: hostToViewer, peerFingerprint: fingerprint)
        case .host:
            return SecureSessionKeyMaterial(outboundKey: hostToViewer, inboundKey: viewerToHost, peerFingerprint: fingerprint)
        }
    }
}

nonisolated enum ScreenQSecureSessionTranscript {
    static func salt(viewerID: UUID, hostID: UUID) -> Data {
        Data("ScreenQ secure session v1 salt \(viewerID.uuidString) \(hostID.uuidString)".utf8)
    }

    static func info(viewerPublicKey: String, hostPublicKey: String) -> Data {
        Data("ScreenQ secure session v1 info \(viewerPublicKey) \(hostPublicKey)".utf8)
    }
}

nonisolated enum SecureSessionError: Error, Sendable {
    case badPublicKey
    case sealFailed
    case openFailed
}

/// Per-direction nonce counter. Wraps to avoid reuse.
nonisolated final class NonceCounter {
    private var counter: UInt64 = 0
    func next() -> ChaChaPoly.Nonce {
        counter &+= 1
        var bytes = [UInt8](repeating: 0, count: 12)
        var c = counter.bigEndian
        withUnsafeBytes(of: &c) { raw in
            for i in 0..<8 {
                bytes[4 + i] = raw[i]
            }
        }
        return try! ChaChaPoly.Nonce(data: Data(bytes))
    }
}

nonisolated enum SecureSessionCipher {
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce) throws -> Data {
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        // We send nonce + ciphertext + tag concatenated.
        return sealed.combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: data)
        return try ChaChaPoly.open(box, using: key)
    }
}
