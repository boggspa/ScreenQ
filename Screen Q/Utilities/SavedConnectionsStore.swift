//
//  SavedConnectionsStore.swift
//  Screen Q
//
//  Persists recent and bookmarked connections using UserDefaults. Each entry
//  stores the host address, port, display name, and whether it was manually
//  bookmarked. Recent connections are capped at 20 entries (FIFO).
//

import Foundation
import Combine

nonisolated enum RemoteConnectionProtocol: String, Codable, Hashable, Sendable, CaseIterable {
    case screenQ
    case macScreenSharing
    case vnc
    case rdp

    var displayName: String {
        switch self {
        case .screenQ: return "Screen Q"
        case .macScreenSharing: return "Mac Screen Sharing"
        case .vnc: return "VNC"
        case .rdp: return "RDP"
        }
    }

    var defaultPort: UInt16 {
        switch self {
        case .screenQ: return ScreenQProtocol.defaultPort
        case .macScreenSharing: return 5900
        case .vnc: return 5900
        case .rdp: return 3389
        }
    }

    var isAvailable: Bool {
        switch self {
        case .screenQ, .macScreenSharing, .vnc, .rdp: return true
        }
    }

    var connectionKind: ConnectionKind {
        switch self {
        case .screenQ: return .screenQ
        case .macScreenSharing: return .macScreenSharing
        case .vnc: return .vnc
        case .rdp: return .rdpReserved
        }
    }
}

struct SavedConnection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var displayName: String
    var host: String
    var port: UInt16
    var connectionProtocol: RemoteConnectionProtocol?
    var isBookmark: Bool = false
    var lastConnected: Date = Date()
    var peerFingerprint: String?  // optional encryption fingerprint for trust

    var address: String { "\(host):\(port)" }
    var resolvedProtocol: RemoteConnectionProtocol {
        connectionProtocol ?? (port == RemoteConnectionProtocol.vnc.defaultPort ? .macScreenSharing : .screenQ)
    }
}

@MainActor
final class SavedConnectionsStore: ObservableObject {

    @Published private(set) var connections: [SavedConnection] = []

    private let key = "ScreenQ.SavedConnections"
    private let maxRecent = 20

    init() {
        load()
    }

    func addOrUpdate(host: String, port: UInt16, displayName: String, fingerprint: String? = nil, connectionProtocol: RemoteConnectionProtocol? = nil) {
        // If we already have this host:port, update it.
        if let idx = connections.firstIndex(where: { $0.host == host && $0.port == port }) {
            connections[idx].displayName = displayName
            connections[idx].lastConnected = Date()
            if let connectionProtocol { connections[idx].connectionProtocol = connectionProtocol }
            if let fp = fingerprint { connections[idx].peerFingerprint = fp }
        } else {
            let entry = SavedConnection(
                displayName: displayName,
                host: host,
                port: port,
                connectionProtocol: connectionProtocol,
                lastConnected: Date(),
                peerFingerprint: fingerprint
            )
            connections.insert(entry, at: 0)
        }

        // Trim non-bookmarked entries beyond max.
        let bookmarks = connections.filter { $0.isBookmark }
        var recents = connections.filter { !$0.isBookmark }
        if recents.count > maxRecent {
            recents = Array(recents.prefix(maxRecent))
        }
        connections = (bookmarks + recents).sorted { $0.lastConnected > $1.lastConnected }

        save()
    }

    func toggleBookmark(_ id: UUID) {
        if let idx = connections.firstIndex(where: { $0.id == id }) {
            connections[idx].isBookmark.toggle()
            save()
        }
    }

    func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        save()
    }

    func clearRecents() {
        connections.removeAll { !$0.isBookmark }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return
        }
        connections = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
