//
//  TailscaleCredentialStore.swift
//  Screen Q
//
//  Stores optional Tailscale credentials used for tailnet device discovery.
//  Secrets are never written to UserDefaults or saved connection metadata.
//

import Foundation
import Security

nonisolated enum TailscaleCredentialStore {
    private static let service = "com.chrisizatt.ScreenQ.tailscale"
    private static let apiTokenAccount = "tailnet-devices-api-token"
    private static let oauthClientIDAccount = "tailnet-devices-oauth-client-id"
    private static let oauthClientSecretAccount = "tailnet-devices-oauth-client-secret"

    enum CredentialKind: Equatable, Sendable {
        case apiToken
        case oauthClient
    }

    enum Credentials: Equatable, Sendable {
        case apiToken(String)
        case oauthClient(id: String, secret: String)
    }

    static var hasAPIToken: Bool {
        loadAPIToken() != nil
    }

    static var hasOAuthClient: Bool {
        loadOAuthClientCredentials() != nil
    }

    static var hasCredentials: Bool {
        loadCredentials() != nil
    }

    static var configuredKind: CredentialKind? {
        if hasOAuthClient { return .oauthClient }
        if hasAPIToken { return .apiToken }
        return nil
    }

    static func loadCredentials() -> Credentials? {
        if let oauth = loadOAuthClientCredentials() {
            return .oauthClient(id: oauth.id, secret: oauth.secret)
        }
        if let token = loadAPIToken() {
            return .apiToken(token)
        }
        return nil
    }

    static func loadAPIToken() -> String? {
        loadString(account: apiTokenAccount, operationPrompt: "Allow Screen Q to refresh Tailscale tailnet devices.")
    }

    static func loadOAuthClientCredentials() -> (id: String, secret: String)? {
        guard let id = loadString(
            account: oauthClientIDAccount,
            operationPrompt: "Allow Screen Q to read the saved Tailscale OAuth client ID."
        ),
        let secret = loadString(
            account: oauthClientSecretAccount,
            operationPrompt: "Allow Screen Q to mint a Tailscale device-listing access token."
        ) else {
            return nil
        }
        return (id, secret)
    }

    static func saveAPIToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deleteOAuthClientCredentials()
        saveString(trimmed, account: apiTokenAccount)
    }

    static func saveOAuthClientCredentials(id: String, secret: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedSecret.isEmpty else { return }
        deleteAPIToken()
        saveString(trimmedID, account: oauthClientIDAccount)
        saveString(trimmedSecret, account: oauthClientSecretAccount)
    }

    static func deleteAPIToken() {
        deleteString(account: apiTokenAccount)
    }

    static func deleteOAuthClientCredentials() {
        deleteString(account: oauthClientIDAccount)
        deleteString(account: oauthClientSecretAccount)
    }

    static func deleteCredentials() {
        deleteAPIToken()
        deleteOAuthClientCredentials()
    }

    private static func loadString(account: String, operationPrompt: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: operationPrompt
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return token
    }

    private static func saveString(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func deleteString(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
