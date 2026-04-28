//
//  AuditLog.swift
//  Screen Q
//
//  Persistent, timestamped audit trail for Screen Q sessions. Each entry
//  records who connected, what they did, and when. Writes JSON lines to
//  ~/Library/Logs/ScreenQ/audit.jsonl (macOS) or the app's Documents
//  directory (iOS).
//

import Foundation
import Combine
import CryptoKit

struct AuditEntry: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var sessionID: UUID?
    var peerName: String
    var peerID: UUID?
    var eventType: EventType
    var detail: String
    var previousEntryHash: String?
    var entryHash: String?

    enum EventType: String, Codable, Sendable {
        case sessionStarted
        case sessionEnded
        case pairingRequested
        case pairingApproved
        case pairingRejected
        case trustChanged
        case certificateDecision
        case securityStateChanged
        case controlGranted
        case controlRevoked
        case fileTransferSent
        case fileTransferReceived
        case remoteCommandExecuted
        case systemAction
        case packageInstalled
        case clipboardSync
        case permissionChanged
        case error
    }
}

@MainActor
final class AuditLog: ObservableObject {

    @Published private(set) var recentEntries: [AuditEntry] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxInMemory = 200
    private var lastEntryHash: String?

    init() {
        #if os(macOS)
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ScreenQ", isDirectory: true)
        #else
        let logsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ScreenQLogs", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.fileURL = logsDir.appendingPathComponent("audit.jsonl")
        load()
    }

    func log(_ entry: AuditEntry) {
        var entry = entry
        entry.previousEntryHash = lastEntryHash
        entry.entryHash = hash(entry)
        lastEntryHash = entry.entryHash
        recentEntries.append(entry)
        if recentEntries.count > maxInMemory {
            recentEntries.removeFirst(recentEntries.count - maxInMemory)
        }
        persist(entry)
        Logger.shared.info("Audit: \(entry.eventType.rawValue) — \(entry.peerName) — \(entry.detail)")
    }

    func log(
        sessionID: UUID? = nil,
        peerName: String,
        peerID: UUID? = nil,
        event: AuditEntry.EventType,
        detail: String
    ) {
        let entry = AuditEntry(
            sessionID: sessionID,
            peerName: peerName,
            peerID: peerID,
            eventType: event,
            detail: detail
        )
        log(entry)
    }

    func clearAll() {
        recentEntries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        lastEntryHash = nil
        log(
            peerName: "Local user",
            event: .permissionChanged,
            detail: "Audit log cleared"
        )
    }

    // MARK: - Persistence

    private func persist(_ entry: AuditEntry) {
        guard let data = try? encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)  // newline
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            }
        } else {
            try? line.write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Load last N entries.
        let tail = lines.suffix(maxInMemory)
        for line in tail {
            if let lineData = line.data(using: .utf8),
               let entry = try? decoder.decode(AuditEntry.self, from: lineData) {
                recentEntries.append(entry)
                if let entryHash = entry.entryHash {
                    lastEntryHash = entryHash
                }
            }
        }
    }

    private func hash(_ entry: AuditEntry) -> String? {
        var copy = entry
        copy.entryHash = nil
        guard let data = try? encoder.encode(copy) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
