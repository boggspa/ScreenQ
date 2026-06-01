//
//  CredentialInventoryStore.swift
//  Screen Q
//
//  Non-secret metadata for remote-access credentials stored in Keychain. The
//  password remains only in Keychain; this inventory lets the app show and
//  revoke remembered credentials from Security & Trust without reading them.
//

import Foundation

nonisolated struct StoredCredentialMetadata: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case macScreenSharing
        case vnc
        case rdp

        var displayName: String {
            switch self {
            case .macScreenSharing: return "Mac Screen Sharing"
            case .vnc: return "Generic VNC"
            case .rdp: return "RDP"
            }
        }

        var systemImage: String {
            switch self {
            case .macScreenSharing: return "macwindow"
            case .vnc: return "rectangle.connected.to.line.below"
            case .rdp: return "pc"
            }
        }
    }

    var kind: Kind
    var host: String
    var port: UInt16
    var username: String?
    var requiresLocalAuthentication: Bool
    var lastUpdated: Date

    var id: String {
        "\(kind.rawValue):\(CredentialKeychainAccess.normalizedAccount(host: host, port: port))"
    }

    var address: String { "\(host):\(port)" }
}

nonisolated enum CredentialInventoryStore {
    private static let storeKey = "ScreenQ.CredentialInventory"

    static func all() -> [StoredCredentialMetadata] {
        records().values.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.address.localizedStandardCompare($1.address) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    static func upsert(
        kind: StoredCredentialMetadata.Kind,
        host: String,
        port: UInt16,
        username: String?,
        requiresLocalAuthentication: Bool,
        now: Date = Date()
    ) {
        let cleanedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedHost.isEmpty else { return }

        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedUsername = trimmedUsername?.isEmpty == true ? nil : trimmedUsername

        let metadata = StoredCredentialMetadata(
            kind: kind,
            host: cleanedHost,
            port: port,
            username: cleanedUsername,
            requiresLocalAuthentication: requiresLocalAuthentication,
            lastUpdated: now
        )

        var all = records()
        all[metadata.id] = metadata
        saveRecords(all)
    }

    static func remove(kind: StoredCredentialMetadata.Kind, host: String, port: UInt16) {
        var all = records()
        let id = "\(kind.rawValue):\(CredentialKeychainAccess.normalizedAccount(host: host, port: port))"
        all.removeValue(forKey: id)
        saveRecords(all)
    }

    private static func records() -> [String: StoredCredentialMetadata] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: StoredCredentialMetadata].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveRecords(_ records: [String: StoredCredentialMetadata]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
