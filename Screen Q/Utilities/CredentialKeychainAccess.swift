//
//  CredentialKeychainAccess.swift
//  Screen Q
//
//  Shared Keychain access-control helpers for remembered remote-access
//  credentials. Secrets stay in Keychain; callers choose whether reuse should
//  require local device-owner authentication.
//

import Foundation
import LocalAuthentication
import Security

nonisolated enum CredentialKeychainAccess {
    static func protectionAttributes(requireLocalAuthentication: Bool) -> [String: Any] {
        guard requireLocalAuthentication else {
            return [
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        }

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            Logger.shared.error("Unable to create local-auth Keychain access control: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
            return [
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
        }

        return [
            kSecAttrAccessControl as String: access
        ]
    }

    static func operationPrompt(protocolName: String, host: String) -> String {
        "Authenticate to reuse saved \(protocolName) credentials for \(host)."
    }

    static func reuseQueryAttributes(operationPrompt: String) -> [String: Any] {
        let context = LAContext()
        context.localizedReason = operationPrompt
        return [
            kSecUseAuthenticationContext as String: context
        ]
    }

    static func normalizedAccount(host: String, port: UInt16) -> String {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(normalizedHost):\(port)"
    }

    static func endpoint(fromNormalizedAccount account: String) -> (host: String, port: UInt16)? {
        guard let separator = account.lastIndex(of: ":"),
              let port = UInt16(account[account.index(after: separator)...]) else {
            return nil
        }
        let host = String(account[..<separator])
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    static func genericPasswordAccounts(service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let items = item as? [[String: Any]] else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
