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
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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

    var systemImage: String {
        switch self {
        case .screenQ: return "display"
        case .macScreenSharing: return "macwindow"
        case .vnc: return "rectangle.connected.to.line.below"
        case .rdp: return "pc"
        }
    }

    var quickConnectScheme: String {
        switch self {
        case .screenQ: return "screenq"
        case .macScreenSharing, .vnc: return "vnc"
        case .rdp: return "rdp"
        }
    }
}

nonisolated enum SavedConnectionSource: String, Codable, Hashable, Sendable {
    case manual
    case nearby
    case tailnet
    case importedRDP
    case quickConnect

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .nearby: return "Nearby"
        case .tailnet: return "Tailnet"
        case .importedRDP: return "RDP import"
        case .quickConnect: return "Quick Connect"
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
    var wakeMACAddress: String?
    var thumbnailData: Data?
    var thumbnailUpdatedAt: Date?
    var notes: String = ""
    var groupIDs: [UUID] = []
    var source: SavedConnectionSource = .manual
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var address: String { "\(host):\(port)" }
    var resolvedProtocol: RemoteConnectionProtocol {
        connectionProtocol ?? (port == RemoteConnectionProtocol.vnc.defaultPort ? .macScreenSharing : .screenQ)
    }

    var quickConnectURLString: String {
        let scheme = resolvedProtocol.quickConnectScheme
        let defaultPort = resolvedProtocol.defaultPort
        let portSuffix = port == defaultPort ? "" : ":\(port)"
        return "\(scheme)://\(host)\(portSuffix)"
    }

    var sourceLabel: String {
        source.displayName
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: UInt16,
        connectionProtocol: RemoteConnectionProtocol? = nil,
        isBookmark: Bool = false,
        lastConnected: Date = Date(),
        peerFingerprint: String? = nil,
        wakeMACAddress: String? = nil,
        thumbnailData: Data? = nil,
        thumbnailUpdatedAt: Date? = nil,
        notes: String = "",
        groupIDs: [UUID] = [],
        source: SavedConnectionSource = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.connectionProtocol = connectionProtocol
        self.isBookmark = isBookmark
        self.lastConnected = lastConnected
        self.peerFingerprint = peerFingerprint
        self.wakeMACAddress = wakeMACAddress
        self.thumbnailData = thumbnailData
        self.thumbnailUpdatedAt = thumbnailUpdatedAt
        self.notes = notes
        self.groupIDs = groupIDs
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case host
        case port
        case connectionProtocol
        case isBookmark
        case lastConnected
        case peerFingerprint
        case wakeMACAddress
        case thumbnailData
        case thumbnailUpdatedAt
        case notes
        case groupIDs
        case source
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected) ?? Date()
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            displayName: try container.decode(String.self, forKey: .displayName),
            host: try container.decode(String.self, forKey: .host),
            port: try container.decode(UInt16.self, forKey: .port),
            connectionProtocol: try container.decodeIfPresent(RemoteConnectionProtocol.self, forKey: .connectionProtocol),
            isBookmark: try container.decodeIfPresent(Bool.self, forKey: .isBookmark) ?? false,
            lastConnected: lastConnected,
            peerFingerprint: try container.decodeIfPresent(String.self, forKey: .peerFingerprint),
            wakeMACAddress: try container.decodeIfPresent(String.self, forKey: .wakeMACAddress),
            thumbnailData: try container.decodeIfPresent(Data.self, forKey: .thumbnailData),
            thumbnailUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .thumbnailUpdatedAt),
            notes: try container.decodeIfPresent(String.self, forKey: .notes) ?? "",
            groupIDs: try container.decodeIfPresent([UUID].self, forKey: .groupIDs) ?? [],
            source: try container.decodeIfPresent(SavedConnectionSource.self, forKey: .source) ?? .manual,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? lastConnected,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? lastConnected
        )
    }
}

nonisolated struct QuickConnectTarget: Equatable, Sendable {
    var displayName: String
    var host: String
    var port: UInt16
    var connectionProtocol: RemoteConnectionProtocol
    var sourceText: String
}

nonisolated enum QuickConnectParser {
    static func parse(_ rawValue: String, defaultProtocol: RemoteConnectionProtocol = .screenQ) -> QuickConnectTarget? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://"),
           let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty {
            guard let connectionProtocol = protocolForScheme(scheme),
                  let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !host.isEmpty else {
                return nil
            }
            let rawPort = url.port ?? Int(connectionProtocol.defaultPort)
            guard rawPort >= 0, rawPort <= Int(UInt16.max) else { return nil }
            return QuickConnectTarget(
                displayName: host,
                host: host,
                port: UInt16(rawPort),
                connectionProtocol: connectionProtocol,
                sourceText: trimmed
            )
        }

        let pieces = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        let host = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else { return nil }
        let port = pieces.count == 2 ? UInt16(pieces[1]) ?? defaultProtocol.defaultPort : defaultProtocol.defaultPort
        return QuickConnectTarget(
            displayName: host,
            host: host,
            port: port,
            connectionProtocol: defaultProtocol,
            sourceText: trimmed
        )
    }

    private static func protocolForScheme(_ scheme: String) -> RemoteConnectionProtocol? {
        switch scheme {
        case "screenq", "sq":
            return .screenQ
        case "screens":
            return .macScreenSharing
        case "vnc":
            return .macScreenSharing
        case "rdp", "ms-rd":
            return .rdp
        default:
            return nil
        }
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

    @discardableResult
    func addOrUpdate(
        host: String,
        port: UInt16,
        displayName: String,
        fingerprint: String? = nil,
        connectionProtocol: RemoteConnectionProtocol? = nil,
        wakeMACAddress: String? = nil,
        source: SavedConnectionSource = .manual,
        isBookmark: Bool? = nil,
        notes: String? = nil,
        groupIDs: [UUID]? = nil
    ) -> SavedConnection {
        let normalizedHost = Self.normalizedHost(host)
        let safeDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = safeDisplayName.isEmpty ? normalizedHost : safeDisplayName
        let normalizedWakeMAC = WakeOnLAN.normalizedMACString(wakeMACAddress)

        // If we already have this host:port, update it.
        if let idx = index(host: normalizedHost, port: port, connectionProtocol: connectionProtocol) {
            connections[idx].displayName = label
            connections[idx].host = normalizedHost
            connections[idx].lastConnected = Date()
            if let connectionProtocol { connections[idx].connectionProtocol = connectionProtocol }
            if let fp = fingerprint { connections[idx].peerFingerprint = fp }
            if let normalizedWakeMAC { connections[idx].wakeMACAddress = normalizedWakeMAC }
            if let isBookmark { connections[idx].isBookmark = isBookmark }
            if let notes { connections[idx].notes = notes }
            if let groupIDs { connections[idx].groupIDs = groupIDs }
            connections[idx].source = source
            connections[idx].updatedAt = Date()
        } else {
            let entry = SavedConnection(
                displayName: label,
                host: normalizedHost,
                port: port,
                connectionProtocol: connectionProtocol,
                isBookmark: isBookmark ?? false,
                lastConnected: Date(),
                peerFingerprint: fingerprint,
                wakeMACAddress: normalizedWakeMAC,
                notes: notes ?? "",
                groupIDs: groupIDs ?? [],
                source: source
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
        return connections.first {
            $0.host.caseInsensitiveCompare(normalizedHost) == .orderedSame &&
            $0.port == port &&
            (connectionProtocol == nil || $0.resolvedProtocol == connectionProtocol)
        } ?? connections[0]
    }

    func update(_ connection: SavedConnection) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        var updated = connection
        updated.host = Self.normalizedHost(updated.host)
        updated.displayName = updated.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.displayName.isEmpty {
            updated.displayName = updated.host
        }
        updated.wakeMACAddress = WakeOnLAN.normalizedMACString(updated.wakeMACAddress)
        updated.updatedAt = Date()
        connections[idx] = updated
        sortAndSave()
    }

    func duplicate(_ id: UUID) {
        guard let existing = connections.first(where: { $0.id == id }) else { return }
        var duplicate = existing
        duplicate.id = UUID()
        duplicate.displayName = "\(existing.displayName) Copy"
        duplicate.createdAt = Date()
        duplicate.updatedAt = Date()
        duplicate.isBookmark = true
        connections.insert(duplicate, at: 0)
        save()
    }

    func wakeMACAddress(host: String, port: UInt16) -> String? {
        connections.first { $0.host == host && $0.port == port }?.wakeMACAddress
    }

    func updateThumbnail(host: String, port: UInt16, displayName: String, connectionProtocol: RemoteConnectionProtocol, image: CGImage?) {
        guard let image,
              let thumbnailData = Self.makeThumbnailData(from: image) else { return }
        guard let idx = connections.firstIndex(where: {
            $0.host == host && $0.port == port && $0.resolvedProtocol == connectionProtocol
        }) ?? connections.firstIndex(where: { $0.host == host && $0.port == port }) else {
            return
        }
        connections[idx].displayName = displayName
        connections[idx].thumbnailData = thumbnailData
        connections[idx].thumbnailUpdatedAt = Date()
        save()
    }

    func toggleBookmark(_ id: UUID) {
        if let idx = connections.firstIndex(where: { $0.id == id }) {
            connections[idx].isBookmark.toggle()
            connections[idx].updatedAt = Date()
            save()
        }
    }

    func setBookmark(_ id: UUID, isBookmark: Bool) {
        if let idx = connections.firstIndex(where: { $0.id == id }) {
            connections[idx].isBookmark = isBookmark
            connections[idx].updatedAt = Date()
            save()
        }
    }

    func assign(_ id: UUID, to groupIDs: [UUID]) {
        if let idx = connections.firstIndex(where: { $0.id == id }) {
            connections[idx].groupIDs = groupIDs
            connections[idx].updatedAt = Date()
            save()
        }
    }

    func connections(in groupID: UUID) -> [SavedConnection] {
        connections.filter { $0.groupIDs.contains(groupID) }
    }

    func removeGroupReferences(_ groupID: UUID) {
        var changed = false
        for idx in connections.indices where connections[idx].groupIDs.contains(groupID) {
            connections[idx].groupIDs.removeAll { $0 == groupID }
            connections[idx].updatedAt = Date()
            changed = true
        }
        if changed { save() }
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

    private func sortAndSave() {
        connections.sort { lhs, rhs in
            if lhs.isBookmark != rhs.isBookmark { return lhs.isBookmark && !rhs.isBookmark }
            return lhs.lastConnected > rhs.lastConnected
        }
        save()
    }

    private func index(host: String, port: UInt16, connectionProtocol: RemoteConnectionProtocol?) -> Int? {
        connections.firstIndex {
            $0.host.caseInsensitiveCompare(host) == .orderedSame &&
            $0.port == port &&
            (connectionProtocol == nil || $0.resolvedProtocol == connectionProtocol)
        } ?? connections.firstIndex {
            $0.host.caseInsensitiveCompare(host) == .orderedSame &&
            $0.port == port
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeThumbnailData(from image: CGImage) -> Data? {
        let maxDimension: CGFloat = 360
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = min(1, maxDimension / max(sourceWidth, sourceHeight))
        let width = max(1, Int((sourceWidth * scale).rounded()))
        let height = max(1, Int((sourceHeight * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.72]
        CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
