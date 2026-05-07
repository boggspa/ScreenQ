//
//  ComputerList.swift
//  Screen Q
//
//  Named groups of computers for personal/studio connection organization.
//  Persisted in UserDefaults. The historical "Fleet" keys stay for
//  compatibility with existing local data.
//

import Foundation
import Combine

nonisolated struct ComputerEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var displayName: String
    var host: String
    var port: UInt16 = 38745
    var macAddress: String?  // for WOL
    var lastSeen: Date?
    var lastStatus: MachineStatus = .unknown
    var tags: [String] = []
    var notes: String = ""

    enum MachineStatus: String, Codable, Sendable {
        case online
        case offline
        case sleeping
        case unknown
    }
}

nonisolated struct ComputerGroup: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var icon: String = "folder"
    var computerIDs: [UUID] = []
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder",
        computerIDs: [UUID] = [],
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.computerIDs = computerIDs
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case computerIDs
        case sortOrder
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decode(String.self, forKey: .name),
            icon: try container.decodeIfPresent(String.self, forKey: .icon) ?? "folder",
            computerIDs: try container.decodeIfPresent([UUID].self, forKey: .computerIDs) ?? [],
            sortOrder: try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
        )
    }
}

@MainActor
final class ComputerListStore: ObservableObject {

    @Published var computers: [ComputerEntry] = []
    @Published var groups: [ComputerGroup] = []

    private let computersKey = "ScreenQ.Fleet.Computers"
    private let groupsKey = "ScreenQ.Fleet.Groups"
    private let deletedGroupsKey = "ScreenQ.Fleet.Groups.Deleted"
    private var deletedGroupTombstones: [UUID: Date] = [:]

    init() {
        load()
    }

    // MARK: - Computers

    func addComputer(_ entry: ComputerEntry) {
        if !computers.contains(where: { $0.host == entry.host && $0.port == entry.port }) {
            computers.append(entry)
            save()
        }
    }

    func updateComputer(_ entry: ComputerEntry) {
        if let idx = computers.firstIndex(where: { $0.id == entry.id }) {
            computers[idx] = entry
            save()
        }
    }

    func removeComputer(_ id: UUID) {
        computers.removeAll { $0.id == id }
        // Also remove from all groups.
        for i in groups.indices {
            groups[i].computerIDs.removeAll { $0 == id }
        }
        save()
    }

    func computer(byID id: UUID) -> ComputerEntry? {
        computers.first { $0.id == id }
    }

    func updateStatus(_ id: UUID, status: ComputerEntry.MachineStatus) {
        if let idx = computers.firstIndex(where: { $0.id == id }) {
            computers[idx].lastStatus = status
            computers[idx].lastSeen = Date()
            save()
        }
    }

    // MARK: - Groups

    func addGroup(name: String, icon: String = "folder") {
        let group = ComputerGroup(name: name, icon: icon, sortOrder: groups.count)
        groups.append(group)
        deletedGroupTombstones.removeValue(forKey: group.id)
        saveDeletedGroupTombstones()
        save()
    }

    func updateGroup(_ group: ComputerGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = group
        updated.createdAt = groups[idx].createdAt
        if updated.computerIDs.isEmpty {
            updated.computerIDs = groups[idx].computerIDs
        }
        updated.updatedAt = Date()
        groups[idx] = updated
        deletedGroupTombstones.removeValue(forKey: updated.id)
        saveDeletedGroupTombstones()
        save()
    }

    func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        deletedGroupTombstones[id] = Date()
        saveDeletedGroupTombstones()
        save()
    }

    func addToGroup(computerID: UUID, groupID: UUID) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            if !groups[idx].computerIDs.contains(computerID) {
                groups[idx].computerIDs.append(computerID)
                groups[idx].updatedAt = Date()
                save()
            }
        }
    }

    func removeFromGroup(computerID: UUID, groupID: UUID) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].computerIDs.removeAll { $0 == computerID }
            groups[idx].updatedAt = Date()
            save()
        }
    }

    func computers(in group: ComputerGroup) -> [ComputerEntry] {
        group.computerIDs.compactMap { id in computers.first { $0.id == id } }
    }

    // MARK: - IP Range Scan

    func scanIPRange(base: String, start: Int, end: Int, port: UInt16 = 38745) async {
        for i in start...end {
            let ip = "\(base).\(i)"
            let reachable = await probeHost(ip, port: port)
            if reachable {
                let entry = ComputerEntry(
                    displayName: ip,
                    host: ip,
                    port: port,
                    lastSeen: Date(),
                    lastStatus: .online
                )
                addComputer(entry)
            }
        }
    }

    private func probeHost(_ host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { cont in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 2)
            timer.setEventHandler {
                connection.cancel()
                cont.resume(returning: false)
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                timer.cancel()
                switch state {
                case .ready:
                    connection.cancel()
                    cont.resume(returning: true)
                case .failed, .cancelled:
                    connection.cancel()
                    cont.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    // MARK: - Persistence

    private func load() {
        loadDeletedGroupTombstones()
        if let data = UserDefaults.standard.data(forKey: computersKey),
           let decoded = try? JSONDecoder().decode([ComputerEntry].self, from: data) {
            computers = decoded
        }
        if let data = UserDefaults.standard.data(forKey: groupsKey),
           let decoded = try? JSONDecoder().decode([ComputerGroup].self, from: data) {
            groups = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(computers) {
            UserDefaults.standard.set(data, forKey: computersKey)
        }
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        }
    }

    func iCloudGroupRecords() -> [ICloudComputerGroupRecord] {
        groups
            .map(ICloudComputerGroupRecord.init)
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.updatedAt > $1.updatedAt
            }
    }

    func iCloudDeletedGroupRecords() -> [ICloudTombstone] {
        deletedGroupTombstones.map { ICloudTombstone(id: $0.key, deletedAt: $0.value) }
            .sorted {
                if $0.deletedAt == $1.deletedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.deletedAt > $1.deletedAt
            }
    }

    @discardableResult
    func mergeICloudGroups(
        _ records: [ICloudComputerGroupRecord],
        deleted tombstones: [ICloudTombstone]
    ) -> [UUID] {
        var changed = false
        var removedIDs: [UUID] = []
        let remoteTombstones = Dictionary(
            tombstones.map { ($0.id, $0.deletedAt) },
            uniquingKeysWith: max
        )

        for (id, deletedAt) in remoteTombstones {
            let previous = deletedGroupTombstones[id] ?? Date(timeIntervalSince1970: 0)
            if deletedAt > previous {
                deletedGroupTombstones[id] = deletedAt
                changed = true
            }
            if let idx = groups.firstIndex(where: { $0.id == id }),
               groups[idx].updatedAt <= deletedAt {
                groups.remove(at: idx)
                removedIDs.append(id)
                changed = true
            }
        }

        for record in records {
            let deletedAt = deletedGroupTombstones[record.id] ?? Date(timeIntervalSince1970: 0)
            guard record.updatedAt > deletedAt else { continue }

            if let idx = groups.firstIndex(where: { $0.id == record.id }) {
                if record.updatedAt > groups[idx].updatedAt {
                    groups[idx] = record.computerGroup()
                    changed = true
                }
                if deletedGroupTombstones.removeValue(forKey: record.id) != nil {
                    changed = true
                }
            } else {
                groups.append(record.computerGroup())
                changed = true
            }
        }

        if changed {
            groups.sort { $0.sortOrder < $1.sortOrder }
            saveDeletedGroupTombstones()
            save()
        }
        return removedIDs
    }

    private func loadDeletedGroupTombstones() {
        guard let data = UserDefaults.standard.data(forKey: deletedGroupsKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return
        }
        deletedGroupTombstones = decoded.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
    }

    private func saveDeletedGroupTombstones() {
        let encoded = Dictionary(
            uniqueKeysWithValues: deletedGroupTombstones.map { ($0.key.uuidString, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: deletedGroupsKey)
    }
}

import Network
