//
//  VNCKeychainCredentialStore.swift
//  Screen Q
//
//  Stores optional VNC credentials in the platform Keychain. Secrets must not
//  be persisted in SavedConnections/UserDefaults.
//

import Foundation
import Security

nonisolated struct VNCStoredCredential: Codable, Equatable, Sendable {
    var username: String
    var password: String
}

nonisolated enum VNCKeychainCredentialStore {
    private static let service = "com.chrisizatt.ScreenQ.vnc"

    static func load(host: String, port: UInt16, operationPrompt: String? = nil) -> VNCStoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: operationPrompt ?? CredentialKeychainAccess.operationPrompt(protocolName: "VNC", host: host)
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(VNCStoredCredential.self, from: data)
    }

    static func save(
        _ credential: VNCStoredCredential,
        host: String,
        port: UInt16,
        requireLocalAuthentication: Bool = false
    ) {
        guard !credential.password.isEmpty,
              let data = try? JSONEncoder().encode(credential) else {
            return
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port)
        ]

        var updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]
        for (key, value) in CredentialKeychainAccess.protectionAttributes(requireLocalAuthentication: requireLocalAuthentication) {
            updateAttributes[key] = value
        }

        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        for (key, value) in updateAttributes {
            addQuery[key] = value
        }
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func delete(host: String, port: UInt16) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port)
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func account(host: String, port: UInt16) -> String {
        CredentialKeychainAccess.normalizedAccount(host: host, port: port)
    }
}
