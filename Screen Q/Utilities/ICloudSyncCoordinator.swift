//
//  ICloudSyncCoordinator.swift
//  Screen Q
//
//  Cross-device sync for non-secret library metadata and viewer preferences.
//  Credentials, thumbnails, trust fingerprints, certificate pins, and live
//  device status deliberately stay out of this payload.
//

import Foundation
import Combine

nonisolated enum ICloudSyncPhase: String, Codable, Hashable, Sendable {
    case disabled
    case unavailable
    case idle
    case syncing
    case error
}

nonisolated struct ICloudSyncStatus: Equatable, Sendable {
    var phase: ICloudSyncPhase
    var message: String
    var lastSyncedAt: Date?

    static let disabled = ICloudSyncStatus(
        phase: .disabled,
        message: "iCloud sync is off.",
        lastSyncedAt: nil
    )

    static let unavailable = ICloudSyncStatus(
        phase: .unavailable,
        message: "Sign in to iCloud to sync this library.",
        lastSyncedAt: nil
    )

    static func syncing(_ message: String = "Syncing with iCloud...") -> ICloudSyncStatus {
        ICloudSyncStatus(phase: .syncing, message: message, lastSyncedAt: nil)
    }

    static func idle(_ date: Date) -> ICloudSyncStatus {
        ICloudSyncStatus(phase: .idle, message: "Synced with iCloud.", lastSyncedAt: date)
    }

    static func error(_ message: String) -> ICloudSyncStatus {
        ICloudSyncStatus(phase: .error, message: message, lastSyncedAt: nil)
    }
}

nonisolated struct ICloudTombstone: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var deletedAt: Date
}

nonisolated struct ICloudSavedConnectionRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var host: String
    var port: UInt16
    var connectionProtocol: RemoteConnectionProtocol?
    var isBookmark: Bool
    var lastConnected: Date
    var wakeMACAddress: String?
    var notes: String
    var groupIDs: [UUID]
    var source: SavedConnectionSource
    var createdAt: Date
    var updatedAt: Date

    init(connection: SavedConnection) {
        id = connection.id
        displayName = connection.displayName
        host = connection.host
        port = connection.port
        connectionProtocol = connection.connectionProtocol
        isBookmark = connection.isBookmark
        lastConnected = connection.lastConnected
        wakeMACAddress = connection.wakeMACAddress
        notes = connection.notes
        groupIDs = connection.groupIDs
        source = connection.source
        createdAt = connection.createdAt
        updatedAt = connection.updatedAt
    }

    var resolvedProtocol: RemoteConnectionProtocol {
        connectionProtocol ?? (port == RemoteConnectionProtocol.vnc.defaultPort ? .macScreenSharing : .screenQ)
    }

    var endpointKey: String {
        "\(resolvedProtocol.rawValue)|\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(port)"
    }

    func savedConnection(preserving existing: SavedConnection?) -> SavedConnection {
        SavedConnection(
            id: id,
            displayName: displayName,
            host: host,
            port: port,
            connectionProtocol: connectionProtocol,
            isBookmark: isBookmark,
            lastConnected: lastConnected,
            peerFingerprint: existing?.peerFingerprint,
            wakeMACAddress: wakeMACAddress,
            thumbnailData: existing?.thumbnailData,
            thumbnailUpdatedAt: existing?.thumbnailUpdatedAt,
            notes: notes,
            groupIDs: groupIDs,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

nonisolated struct ICloudComputerGroupRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var icon: String
    var computerIDs: [UUID]
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(group: ComputerGroup) {
        id = group.id
        name = group.name
        icon = group.icon
        computerIDs = group.computerIDs
        sortOrder = group.sortOrder
        createdAt = group.createdAt
        updatedAt = group.updatedAt
    }

    func computerGroup() -> ComputerGroup {
        ComputerGroup(
            id: id,
            name: name,
            icon: icon,
            computerIDs: computerIDs,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

nonisolated enum ICloudPreferenceValue: Codable, Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case data(Data)
    case stringArray([String])

    init?(propertyListValue value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as Float:
            self = .double(Double(value))
        case let value as Data:
            self = .data(value)
        case let value as [String]:
            self = .stringArray(value)
        default:
            return nil
        }
    }

    var propertyListValue: Any {
        switch self {
        case .string(let value):
            return value
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .data(let value):
            return value
        case .stringArray(let value):
            return value
        }
    }
}

nonisolated struct ICloudPreferenceRecord: Codable, Hashable, Identifiable, Sendable {
    var key: String
    var value: ICloudPreferenceValue
    var updatedAt: Date

    var id: String { key }
}

nonisolated struct ICloudSyncPayload: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var originDeviceID: UUID
    var updatedAt: Date
    var savedConnections: [ICloudSavedConnectionRecord]
    var deletedSavedConnections: [ICloudTombstone]
    var groups: [ICloudComputerGroupRecord]
    var deletedGroups: [ICloudTombstone]
    var viewerPreferences: [ICloudPreferenceRecord]
}

nonisolated enum ICloudPreferenceStore {
    private static let mirrorKey = "ScreenQ.ICloudSync.ViewerPreferenceMirror"
    private static let syncedPrefixes = ["viewer.controls."]

    static func isSyncedPreferenceKey(_ key: String) -> Bool {
        syncedPrefixes.contains { key.hasPrefix($0) }
    }

    static func hasLocalPreferenceDelta(defaults: UserDefaults = .standard) -> Bool {
        let current = currentValues(defaults: defaults)
        let mirror = loadMirror(defaults: defaults)
        guard current.count == mirror.count else { return true }
        return current.contains { key, value in
            mirror[key]?.value != value
        }
    }

    @discardableResult
    static func records(markChangedAt now: Date? = nil, defaults: UserDefaults = .standard) -> [ICloudPreferenceRecord] {
        let current = currentValues(defaults: defaults)
        var mirror = loadMirror(defaults: defaults)
        var changed = false

        if let now {
            for (key, value) in current where mirror[key]?.value != value {
                mirror[key] = ICloudPreferenceRecord(key: key, value: value, updatedAt: now)
                changed = true
            }
            for key in mirror.keys where current[key] == nil {
                mirror.removeValue(forKey: key)
                changed = true
            }
            if changed {
                saveMirror(mirror, defaults: defaults)
            }
        }

        return current.keys.sorted().compactMap { key in
            if let record = mirror[key] {
                return record
            }
            guard let value = current[key] else { return nil }
            return ICloudPreferenceRecord(key: key, value: value, updatedAt: Date(timeIntervalSince1970: 0))
        }
    }

    @discardableResult
    static func merge(_ records: [ICloudPreferenceRecord], defaults: UserDefaults = .standard) -> Bool {
        var mirror = loadMirror(defaults: defaults)
        var changed = false

        for record in records where isSyncedPreferenceKey(record.key) {
            let localUpdatedAt = mirror[record.key]?.updatedAt ?? Date(timeIntervalSince1970: 0)
            guard record.updatedAt > localUpdatedAt else { continue }

            let currentValue = currentValues(defaults: defaults)[record.key]
            if currentValue != record.value {
                defaults.set(record.value.propertyListValue, forKey: record.key)
                changed = true
            }
            mirror[record.key] = record
        }

        if changed {
            saveMirror(mirror, defaults: defaults)
        } else {
            let previous = loadMirror(defaults: defaults)
            if previous != mirror {
                saveMirror(mirror, defaults: defaults)
            }
        }

        return changed
    }

    private static func currentValues(defaults: UserDefaults) -> [String: ICloudPreferenceValue] {
        defaults.dictionaryRepresentation().reduce(into: [:]) { result, pair in
            guard isSyncedPreferenceKey(pair.key),
                  let value = ICloudPreferenceValue(propertyListValue: pair.value) else {
                return
            }
            result[pair.key] = value
        }
    }

    private static func loadMirror(defaults: UserDefaults) -> [String: ICloudPreferenceRecord] {
        guard let data = defaults.data(forKey: mirrorKey),
              let records = try? JSONDecoder().decode([ICloudPreferenceRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
    }

    private static func saveMirror(_ mirror: [String: ICloudPreferenceRecord], defaults: UserDefaults) {
        let records = mirror.values.sorted { $0.key < $1.key }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: mirrorKey)
    }
}

@MainActor
final class ICloudSyncCoordinator: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            guard oldValue != isEnabled else { return }
            if isEnabled {
                syncNow(markPreferencesChanged: true)
            } else {
                pendingPush?.cancel()
                status = .disabled
            }
        }
    }

    @Published private(set) var status: ICloudSyncStatus

    private let keyValueStore: NSUbiquitousKeyValueStore
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cancellables: Set<AnyCancellable> = []
    private var pendingPush: Task<Void, Never>?
    private var pendingPreferenceScan = false
    private var isApplyingRemote = false
    private weak var savedConnections: SavedConnectionsStore?
    private weak var computerList: ComputerListStore?
    private var localDeviceID: UUID?
    private var isConfigured = false

    private static let enabledKey = "ScreenQ.ICloudSync.Enabled"
    private static let payloadKey = "ScreenQ.iCloudSync.Payload.v1"
    private static let maxPayloadBytes = 900_000

    init(
        keyValueStore: NSUbiquitousKeyValueStore = .default,
        defaults: UserDefaults = .standard
    ) {
        self.keyValueStore = keyValueStore
        self.defaults = defaults
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.isEnabled = enabled
        self.status = enabled ? .unavailable : .disabled
    }

    func configure(
        savedConnections: SavedConnectionsStore,
        computerList: ComputerListStore,
        localDeviceID: UUID
    ) {
        guard !isConfigured else { return }
        isConfigured = true
        self.savedConnections = savedConnections
        self.computerList = computerList
        self.localDeviceID = localDeviceID

        savedConnections.$connections
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.schedulePush(markPreferencesChanged: false)
            }
            .store(in: &cancellables)

        computerList.$groups
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.schedulePush(markPreferencesChanged: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      !self.isApplyingRemote,
                      ICloudPreferenceStore.hasLocalPreferenceDelta(defaults: self.defaults) else {
                    return
                }
                self.schedulePush(markPreferencesChanged: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: keyValueStore
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.handleRemoteChange()
        }
        .store(in: &cancellables)

        keyValueStore.synchronize()
        if isEnabled {
            syncNow(markPreferencesChanged: true)
        }
    }

    func syncNow(markPreferencesChanged: Bool = false) {
        guard isEnabled else {
            status = .disabled
            return
        }
        guard isICloudAvailable else {
            status = .unavailable
            return
        }
        status = .syncing()
        keyValueStore.synchronize()
        applyRemotePayloadIfPresent(rebroadcastMergedState: false)
        pushLocalPayload(markPreferencesChanged: markPreferencesChanged)
    }

    private var isICloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    private func schedulePush(markPreferencesChanged: Bool) {
        guard isEnabled, !isApplyingRemote else { return }
        pendingPreferenceScan = pendingPreferenceScan || markPreferencesChanged
        pendingPush?.cancel()
        pendingPush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                guard let self else { return }
                let shouldMarkPreferences = self.pendingPreferenceScan
                self.pendingPreferenceScan = false
                self.pushLocalPayload(markPreferencesChanged: shouldMarkPreferences)
            }
        }
    }

    private func handleRemoteChange() {
        guard isEnabled, !isApplyingRemote else { return }
        guard isICloudAvailable else {
            status = .unavailable
            return
        }
        status = .syncing("Applying iCloud changes...")
        keyValueStore.synchronize()
        applyRemotePayloadIfPresent(rebroadcastMergedState: true)
    }

    private func applyRemotePayloadIfPresent(rebroadcastMergedState: Bool) {
        guard let data = keyValueStore.data(forKey: Self.payloadKey) else { return }
        do {
            let payload = try decoder.decode(ICloudSyncPayload.self, from: data)
            guard payload.schemaVersion == ICloudSyncPayload.currentSchemaVersion else {
                status = .error("This iCloud payload uses a newer sync format.")
                return
            }
            apply(payload)
            if rebroadcastMergedState {
                pushLocalPayload(markPreferencesChanged: false)
            }
        } catch {
            status = .error("Unable to read iCloud sync data.")
            Logger.shared.error("Unable to decode iCloud sync payload: \(error.localizedDescription)")
        }
    }

    private func apply(_ payload: ICloudSyncPayload) {
        guard let savedConnections, let computerList else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        let removedGroupIDs = computerList.mergeICloudGroups(
            payload.groups,
            deleted: payload.deletedGroups
        )
        if !removedGroupIDs.isEmpty {
            savedConnections.removeGroupReferencesFromICloud(removedGroupIDs)
        }

        _ = savedConnections.mergeICloudRecords(
            payload.savedConnections,
            deleted: payload.deletedSavedConnections
        )
        _ = ICloudPreferenceStore.merge(payload.viewerPreferences, defaults: defaults)
    }

    private func pushLocalPayload(markPreferencesChanged: Bool) {
        guard isEnabled else {
            status = .disabled
            return
        }
        guard isICloudAvailable else {
            status = .unavailable
            return
        }
        guard let savedConnections, let computerList, let localDeviceID else { return }

        let now = Date()
        let payload = ICloudSyncPayload(
            originDeviceID: localDeviceID,
            updatedAt: now,
            savedConnections: savedConnections.iCloudRecords(),
            deletedSavedConnections: savedConnections.iCloudDeletedRecords(),
            groups: computerList.iCloudGroupRecords(),
            deletedGroups: computerList.iCloudDeletedGroupRecords(),
            viewerPreferences: ICloudPreferenceStore.records(
                markChangedAt: markPreferencesChanged ? now : nil,
                defaults: defaults
            )
        )

        do {
            let data = try encoder.encode(payload)
            guard data.count <= Self.maxPayloadBytes else {
                status = .error("The iCloud sync payload is too large.")
                Logger.shared.error("iCloud sync payload exceeded \(Self.maxPayloadBytes) bytes: \(data.count)")
                return
            }

            keyValueStore.set(data, forKey: Self.payloadKey)
            let synchronized = keyValueStore.synchronize()
            if synchronized {
                status = .idle(now)
            } else {
                status = .error("iCloud did not accept the latest sync request.")
            }
        } catch {
            status = .error("Unable to prepare iCloud sync data.")
            Logger.shared.error("Unable to encode iCloud sync payload: \(error.localizedDescription)")
        }
    }
}
