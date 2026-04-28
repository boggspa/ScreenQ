//
//  DeviceIdentityStore.swift
//  Screen Q
//
//  Long-lived local signing identity for trusted-peer pinning. The private
//  key is device-only Keychain data; peers only see the public key and a
//  signature binding it to the current encrypted transport handshake.
//

import Foundation
import CryptoKit
import Security

nonisolated struct DeviceIdentityProof: Codable, Hashable, Sendable {
    var publicKeyBase64: String
    var signatureBase64: String
    var fingerprint: String
}

nonisolated enum DeviceIdentityStore {
    private static let service = "ScreenQ.DeviceIdentity"
    private static let account = "local-signing-key-v1"

    static func proof(peerID: UUID, displayName: String, ephemeralPublicKey: String) -> DeviceIdentityProof? {
        do {
            let key = try loadOrCreatePrivateKey()
            let publicData = key.publicKey.rawRepresentation
            let payload = signingPayload(peerID: peerID, displayName: displayName, ephemeralPublicKey: ephemeralPublicKey, publicKey: publicData)
            let signature = try key.signature(for: payload)
            return DeviceIdentityProof(
                publicKeyBase64: publicData.base64EncodedString(),
                signatureBase64: signature.base64EncodedString(),
                fingerprint: fingerprint(publicKey: publicData)
            )
        } catch {
            Logger.shared.error("Unable to create device identity proof: \(error.localizedDescription)")
            return nil
        }
    }

    static func verify(
        publicKeyBase64: String?,
        signatureBase64: String?,
        peerID: UUID,
        displayName: String,
        ephemeralPublicKey: String?
    ) -> String? {
        guard let publicKeyBase64,
              let signatureBase64,
              let ephemeralPublicKey,
              let publicData = Data(base64Encoded: publicKeyBase64),
              let signature = Data(base64Encoded: signatureBase64) else {
            return nil
        }

        do {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
            let payload = signingPayload(peerID: peerID, displayName: displayName, ephemeralPublicKey: ephemeralPublicKey, publicKey: publicData)
            guard key.isValidSignature(signature, for: payload) else { return nil }
            return fingerprint(publicKey: publicData)
        } catch {
            Logger.shared.error("Unable to verify device identity proof: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = loadRawPrivateKey() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        saveRawPrivateKey(key.rawRepresentation)
        return key
    }

    private static func loadRawPrivateKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func saveRawPrivateKey(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.shared.error("Unable to save device identity key: \(status)")
        }
    }

    private static func signingPayload(peerID: UUID, displayName: String, ephemeralPublicKey: String, publicKey: Data) -> Data {
        var data = Data("ScreenQ device identity proof v1\n".utf8)
        data.append(Data(peerID.uuidString.utf8))
        data.append(0x0A)
        data.append(Data(displayName.utf8))
        data.append(0x0A)
        data.append(Data(ephemeralPublicKey.utf8))
        data.append(0x0A)
        data.append(publicKey)
        return data
    }

    private static func fingerprint(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }
}
