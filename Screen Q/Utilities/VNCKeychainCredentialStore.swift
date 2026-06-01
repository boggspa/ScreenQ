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
    private static let service = BundleIdentity.service("vnc")

    static func load(host: String, port: UInt16, operationPrompt: String? = nil) -> VNCStoredCredential? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        for (key, value) in CredentialKeychainAccess.reuseQueryAttributes(
            operationPrompt: operationPrompt ?? CredentialKeychainAccess.operationPrompt(protocolName: "VNC", host: host)
        ) {
            query[key] = value
        }

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
        CredentialInventoryStore.upsert(
            kind: credential.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .vnc : .macScreenSharing,
            host: host,
            port: port,
            username: credential.username,
            requiresLocalAuthentication: requireLocalAuthentication
        )
    }

    static func delete(host: String, port: UInt16) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port)
        ]
        SecItemDelete(query as CFDictionary)
        CredentialInventoryStore.remove(kind: .macScreenSharing, host: host, port: port)
        CredentialInventoryStore.remove(kind: .vnc, host: host, port: port)
    }

    static func knownCredentialMetadata() -> [StoredCredentialMetadata] {
        CredentialKeychainAccess.genericPasswordAccounts(service: service).compactMap { account in
            guard let endpoint = CredentialKeychainAccess.endpoint(fromNormalizedAccount: account) else {
                return nil
            }
            return StoredCredentialMetadata(
                kind: .vnc,
                host: endpoint.host,
                port: endpoint.port,
                username: nil,
                requiresLocalAuthentication: false,
                lastUpdated: .distantPast
            )
        }
    }

    private static func account(host: String, port: UInt16) -> String {
        CredentialKeychainAccess.normalizedAccount(host: host, port: port)
    }
}
