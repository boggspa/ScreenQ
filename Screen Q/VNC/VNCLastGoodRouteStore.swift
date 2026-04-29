//
//  VNCLastGoodRouteStore.swift
//  Screen Q
//
//  Persists the last successful concrete RFB route for a logical VNC target.
//  This lets a later VNCSession try the last-good LAN/Tailscale/manual host
//  candidate before falling back to normal route discovery.
//

import Foundation

nonisolated enum VNCRouteLabel: String, Codable, Hashable, Sendable, CaseIterable {
    case lan
    case tailscale
    case manual

    static func classify(host: String) -> VNCRouteLabel {
        switch NetworkTrustScope.classify(host: host) {
        case .tailscale:
            return .tailscale
        case .privateLAN, .localOnly:
            return .lan
        case .publicInternet, .hostname, .unknown:
            return .manual
        }
    }

    var displayName: String {
        switch self {
        case .lan: return "LAN"
        case .tailscale: return "Tailscale"
        case .manual: return "Manual"
        }
    }
}

nonisolated struct VNCLastGoodRouteKey: Codable, Hashable, Sendable {
    var host: String
    var port: UInt16
    var profile: RFBConnectionProfile

    init(host: String, port: UInt16 = 5900, profile: RFBConnectionProfile = .genericVNC) {
        self.host = Self.normalizedHost(host)
        self.port = port
        self.profile = profile
    }

    var isValid: Bool {
        !host.isEmpty && port > 0
    }

    static func normalizedHost(_ host: String) -> String {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.last == "." {
            trimmed.removeLast()
        }
        return trimmed.lowercased()
    }
}

nonisolated struct VNCRouteCandidate: Codable, Hashable, Sendable {
    var host: String
    var port: UInt16
    var label: VNCRouteLabel
    var lastSucceededAt: Date

    init(host: String, port: UInt16 = 5900, label: VNCRouteLabel? = nil, lastSucceededAt: Date = Date()) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = trimmedHost
        self.port = port
        self.label = label ?? VNCRouteLabel.classify(host: trimmedHost)
        self.lastSucceededAt = lastSucceededAt
    }

    var isValid: Bool {
        !host.isEmpty && port > 0
    }
}

nonisolated struct VNCLastGoodRouteRecord: Codable, Hashable, Sendable, Identifiable {
    var key: VNCLastGoodRouteKey
    var candidate: VNCRouteCandidate

    var id: VNCLastGoodRouteKey { key }
}

nonisolated struct VNCLastGoodRouteCache: Codable, Hashable, Sendable {
    private(set) var records: [VNCLastGoodRouteRecord]
    var maxRecords: Int

    init(records: [VNCLastGoodRouteRecord] = [], maxRecords: Int = 50) {
        self.records = records
        self.maxRecords = max(1, maxRecords)
        compact()
    }

    func preferredCandidate(
        forHost host: String,
        port: UInt16 = 5900,
        profile: RFBConnectionProfile = .genericVNC
    ) -> VNCRouteCandidate? {
        let key = VNCLastGoodRouteKey(host: host, port: port, profile: profile)
        guard key.isValid else { return nil }
        return records.first { $0.key == key }?.candidate
    }

    mutating func recordSuccess(
        logicalHost: String,
        logicalPort: UInt16 = 5900,
        profile: RFBConnectionProfile = .genericVNC,
        routedHost: String? = nil,
        routedPort: UInt16? = nil,
        label: VNCRouteLabel? = nil,
        at date: Date = Date()
    ) -> VNCLastGoodRouteRecord? {
        let key = VNCLastGoodRouteKey(host: logicalHost, port: logicalPort, profile: profile)
        guard key.isValid else { return nil }

        let candidate = VNCRouteCandidate(
            host: routedHost ?? logicalHost,
            port: routedPort ?? logicalPort,
            label: label,
            lastSucceededAt: date
        )
        guard candidate.isValid else { return nil }

        let record = VNCLastGoodRouteRecord(key: key, candidate: candidate)
        records.removeAll { $0.key == key }
        records.insert(record, at: 0)
        compact()
        return record
    }

    mutating func remove(host: String, port: UInt16 = 5900, profile: RFBConnectionProfile = .genericVNC) {
        let key = VNCLastGoodRouteKey(host: host, port: port, profile: profile)
        records.removeAll { $0.key == key }
    }

    mutating func clear() {
        records.removeAll()
    }

    private mutating func compact() {
        var seen: Set<VNCLastGoodRouteKey> = []
        records = records
            .filter { $0.key.isValid && $0.candidate.isValid }
            .sorted { $0.candidate.lastSucceededAt > $1.candidate.lastSucceededAt }
            .filter { record in
                guard !seen.contains(record.key) else { return false }
                seen.insert(record.key)
                return true
            }
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
    }
}

nonisolated final class VNCLastGoodRouteStore: @unchecked Sendable {
    static let shared = VNCLastGoodRouteStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let maxRecords: Int
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "ScreenQ.VNC.LastGoodRoutes",
        maxRecords: Int = 50
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxRecords = max(1, maxRecords)
    }

    func preferredCandidate(
        forHost host: String,
        port: UInt16 = 5900,
        profile: RFBConnectionProfile = .genericVNC
    ) -> VNCRouteCandidate? {
        lock.withLock {
            loadCache().preferredCandidate(forHost: host, port: port, profile: profile)
        }
    }

    @discardableResult
    func recordSuccess(
        logicalHost: String,
        logicalPort: UInt16 = 5900,
        profile: RFBConnectionProfile = .genericVNC,
        routedHost: String? = nil,
        routedPort: UInt16? = nil,
        label: VNCRouteLabel? = nil,
        at date: Date = Date()
    ) -> VNCLastGoodRouteRecord? {
        lock.withLock {
            var cache = loadCache()
            let record = cache.recordSuccess(
                logicalHost: logicalHost,
                logicalPort: logicalPort,
                profile: profile,
                routedHost: routedHost,
                routedPort: routedPort,
                label: label,
                at: date
            )
            saveCache(cache)
            return record
        }
    }

    func remove(host: String, port: UInt16 = 5900, profile: RFBConnectionProfile = .genericVNC) {
        lock.withLock {
            var cache = loadCache()
            cache.remove(host: host, port: port, profile: profile)
            saveCache(cache)
        }
    }

    func clear() {
        lock.withLock {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func loadCache() -> VNCLastGoodRouteCache {
        guard let data = defaults.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode(VNCLastGoodRouteCache.self, from: data) else {
            return VNCLastGoodRouteCache(maxRecords: maxRecords)
        }
        decoded.maxRecords = maxRecords
        return decoded
    }

    private func saveCache(_ cache: VNCLastGoodRouteCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
