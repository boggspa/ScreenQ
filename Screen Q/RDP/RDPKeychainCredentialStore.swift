//
//  RDPKeychainCredentialStore.swift
//  Screen Q
//
//  Stores optional Windows/RDP credentials in Keychain. Passwords must never
//  be written into .rdp profiles, saved connections, or logs.
//

import Foundation
import Security

nonisolated enum RDPKeychainCredentialStore {
    private static let service = "com.chrisizatt.ScreenQ.rdp"

    static func load(host: String, port: UInt16, operationPrompt: String? = nil) -> RDPCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: operationPrompt ?? CredentialKeychainAccess.operationPrompt(protocolName: "RDP", host: host)
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(RDPCredentials.self, from: data)
    }

    static func save(
        _ credentials: RDPCredentials,
        host: String,
        port: UInt16,
        requireLocalAuthentication: Bool = false
    ) {
        guard !credentials.username.isEmpty,
              !credentials.password.isEmpty,
              let data = try? JSONEncoder().encode(credentials) else {
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
