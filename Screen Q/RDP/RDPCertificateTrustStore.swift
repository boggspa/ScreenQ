//
//  RDPCertificateTrustStore.swift
//  Screen Q
//
//  Stores user-approved RDP certificate pins. The fingerprint is not secret,
//  but keeping it app-owned avoids relying on FreeRDP's ~/.config known-hosts.
//

import Foundation

nonisolated struct RDPTrustedCertificate: Codable, Hashable, Identifiable, Sendable {
    var host: String
    var port: UInt16
    var subject: String
    var issuer: String
    var fingerprintSHA256: String
    var firstTrustedAt: Date
    var lastTrustedAt: Date

    var id: String { Self.account(host: host, port: port) }

    static func account(host: String, port: UInt16) -> String {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(normalizedHost):\(port)"
    }
}

nonisolated enum RDPCertificateTrustStore {
    private static let storeKey = "ScreenQ.RDP.TrustedCertificates"

    static func load(host: String, port: UInt16) -> RDPTrustedCertificate? {
        records()[RDPTrustedCertificate.account(host: host, port: port)]
    }

    static func all() -> [RDPTrustedCertificate] {
        records().values.sorted { $0.lastTrustedAt > $1.lastTrustedAt }
    }

    static func save(_ certificate: RDPCertificateInfo, host: String, port: UInt16, now: Date = Date()) {
        let fingerprint = certificate.fingerprintSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { return }

        var all = records()
        let account = RDPTrustedCertificate.account(host: host, port: port)
        let firstTrustedAt = all[account]?.firstTrustedAt ?? now
        all[account] = RDPTrustedCertificate(
            host: host,
            port: port,
            subject: certificate.subject,
            issuer: certificate.issuer,
            fingerprintSHA256: fingerprint,
            firstTrustedAt: firstTrustedAt,
            lastTrustedAt: now
        )
        saveRecords(all)
    }

    static func delete(host: String, port: UInt16) {
        var all = records()
        all.removeValue(forKey: RDPTrustedCertificate.account(host: host, port: port))
        saveRecords(all)
    }

    private static func records() -> [String: RDPTrustedCertificate] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: RDPTrustedCertificate].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveRecords(_ records: [String: RDPTrustedCertificate]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
