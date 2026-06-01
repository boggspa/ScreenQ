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
    private static let service = BundleIdentity.service("rdp")

    static func load(host: String, port: UInt16, operationPrompt: String? = nil) -> RDPCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host, port: port),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        for (key, value) in CredentialKeychainAccess.reuseQueryAttributes(
            operationPrompt: operationPrompt ?? CredentialKeychainAccess.operationPrompt(protocolName: "RDP", host: host)
        ) {
            query[key] = value
        }

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
        CredentialInventoryStore.upsert(
            kind: .rdp,
            host: host,
            port: port,
            username: credentials.normalizedUsername,
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
        CredentialInventoryStore.remove(kind: .rdp, host: host, port: port)
    }

    static func knownCredentialMetadata() -> [StoredCredentialMetadata] {
        CredentialKeychainAccess.genericPasswordAccounts(service: service).compactMap { account in
            guard let endpoint = CredentialKeychainAccess.endpoint(fromNormalizedAccount: account) else {
                return nil
            }
            return StoredCredentialMetadata(
                kind: .rdp,
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
