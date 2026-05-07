//
//  ComputerList.swift
//  Screen Q
//
//  Named groups of computers for fleet management, similar to ARD's
//  computer lists. Persisted in UserDefaults.
//

import Foundation
import Combine

struct ComputerEntry: Codable, Identifiable, Hashable, Sendable {
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

struct ComputerGroup: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var icon: String = "folder"
    var computerIDs: [UUID] = []
    var sortOrder: Int = 0
}

@MainActor
final class ComputerListStore: ObservableObject {

    @Published var computers: [ComputerEntry] = []
    @Published var groups: [ComputerGroup] = []

    private let computersKey = "ScreenQ.Fleet.Computers"
    private let groupsKey = "ScreenQ.Fleet.Groups"

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
        save()
    }

    func updateGroup(_ group: ComputerGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
        save()
    }

    func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    func addToGroup(computerID: UUID, groupID: UUID) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            if !groups[idx].computerIDs.contains(computerID) {
                groups[idx].computerIDs.append(computerID)
                save()
            }
        }
    }

    func removeFromGroup(computerID: UUID, groupID: UUID) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].computerIDs.removeAll { $0 == computerID }
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
}

import Network
