//
//  CredentialKeychainAccess.swift
//  Screen Q
//
//  Shared Keychain access-control helpers for remembered remote-access
//  credentials. Secrets stay in Keychain; callers choose whether reuse should
//  require local device-owner authentication.
//

import Foundation
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

    static func normalizedAccount(host: String, port: UInt16) -> String {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(normalizedHost):\(port)"
    }
}
