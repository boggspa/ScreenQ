//
//  FileTransferService.swift
//  Screen Q
//
//  Manages chunked file transfers between host and viewer. Supports both
//  sending local files to the remote peer and receiving files from it.
//  Files are split into chunks (default 64 KB) and sent as FileChunkMessages
//  over the existing Screen Q protocol.
//

import Foundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class FileTransferService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var outgoingTransfers: [FileTransfer] = []
    @Published private(set) var incomingTransfers: [FileTransfer] = []

    struct FileTransfer: Identifiable {
        let id: UUID
        let fileName: String
        let fileSize: Int64
        let mimeType: String
        var state: TransferState
        var progress: Double  // 0.0 – 1.0
        var localURL: URL?
    }

    enum TransferState: Equatable {
        case offered      // outgoing: waiting for remote accept
        case accepted     // outgoing: sending chunks
        case receiving    // incoming: chunks arriving
        case completed
        case rejected(String)
        case failed(String)
    }

    // MARK: - Configuration

    var chunkSize: Int = 64 * 1024  // 64 KB
    static let maximumTransferBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumChunkBytes: Int = 2 * 1024 * 1024
    var downloadDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory

    // MARK: - Callbacks (set by the session that owns us)

    var sendMessage: ((MessageType, any Encodable) -> Void)?

    // MARK: - Internal state

    private struct ReceiveState {
        let fileName: String
        let fileSize: Int64
        let mimeType: String
        var tempURL: URL?
        var fileHandle: FileHandle?
        var receivedBytes: Int64 = 0
        var expectedChunkIndex: Int = 0
    }

    private var receiveStates: [UUID: ReceiveState] = [:]
    private var acceptedIncomingTransfers: Set<UUID> = []
    private var sendStreams: [UUID: FileReadStream] = [:]

    // MARK: - Sending

    /// Offer a local file to the remote peer.
    func offerFile(at url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            Logger.shared.error("FileTransfer: cannot read file at \(url.path)")
            return
        }

        let transferID = UUID()
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        let transfer = FileTransfer(
            id: transferID,
            fileName: url.lastPathComponent,
            fileSize: size,
            mimeType: mimeType,
            state: .offered,
            progress: 0,
            localURL: url
        )
        outgoingTransfers.append(transfer)

        let offer = FileOfferMessage(
            transferID: transferID,
            fileName: url.lastPathComponent,
            fileSize: size,
            mimeType: mimeType,
            chunkSize: chunkSize
        )
        sendMessage?(.fileOffer, offer)
        Logger.shared.info("FileTransfer: offered \(url.lastPathComponent) (\(size) bytes)")
    }

    /// Offer multiple files (e.g. from a drag-and-drop).
    func offerFiles(at urls: [URL]) {
        for url in urls {
            offerFile(at: url)
        }
    }

    // MARK: - Receiving

    /// Handle an incoming file offer from the remote peer.
    func handleOffer(_ offer: FileOfferMessage) {
        guard let safeFileName = Self.sanitizedFileName(offer.fileName) else {
            rejectIncomingOffer(offer.transferID, fileName: "Rejected file", reason: "Invalid file name")
            Logger.shared.warn("FileTransfer: rejected offer with unsafe file name \(offer.fileName)")
            return
        }
        guard offer.fileSize >= 0, offer.fileSize <= Self.maximumTransferBytes else {
            rejectIncomingOffer(offer.transferID, fileName: safeFileName, reason: "File exceeds the \(ByteFormatting.human(Int(Self.maximumTransferBytes))) transfer limit")
            Logger.shared.warn("FileTransfer: rejected \(safeFileName), invalid size \(offer.fileSize)")
            return
        }
        guard offer.chunkSize > 0, offer.chunkSize <= Self.maximumChunkBytes else {
            rejectIncomingOffer(offer.transferID, fileName: safeFileName, reason: "Invalid transfer chunk size")
            Logger.shared.warn("FileTransfer: rejected \(safeFileName), invalid chunk size \(offer.chunkSize)")
            return
        }
        guard receiveStates[offer.transferID] == nil else {
            rejectIncomingOffer(offer.transferID, fileName: safeFileName, reason: "Duplicate transfer ID")
            Logger.shared.warn("FileTransfer: rejected duplicate transfer \(offer.transferID)")
            return
        }

        let transfer = FileTransfer(
            id: offer.transferID,
            fileName: safeFileName,
            fileSize: offer.fileSize,
            mimeType: offer.mimeType,
            state: .offered,
            progress: 0,
            localURL: nil
        )
        incomingTransfers.append(transfer)
        receiveStates[offer.transferID] = ReceiveState(
            fileName: safeFileName,
            fileSize: offer.fileSize,
            mimeType: offer.mimeType
        )
        Logger.shared.info("FileTransfer: incoming offer \(safeFileName) (\(offer.fileSize) bytes) awaiting user approval")
    }

    /// Accept an incoming file offer.
    func acceptTransfer(_ transferID: UUID) {
        guard let idx = incomingTransfers.firstIndex(where: { $0.id == transferID }),
              incomingTransfers[idx].state == .offered,
              var state = receiveStates[transferID] else { return }

        do {
            let tempURL = try makeReceiveTempURL(transferID: transferID, fileName: state.fileName)
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            state.tempURL = tempURL
            state.fileHandle = handle
            state.receivedBytes = 0
            state.expectedChunkIndex = 0
            receiveStates[transferID] = state
            incomingTransfers[idx].state = .receiving
            acceptedIncomingTransfers.insert(transferID)
            sendMessage?(.fileAccept, FileAcceptMessage(transferID: transferID))
        } catch {
            incomingTransfers[idx].state = .failed("Could not prepare download: \(error.localizedDescription)")
            receiveStates.removeValue(forKey: transferID)
            sendMessage?(.fileReject, FileRejectMessage(transferID: transferID, reason: "Could not prepare download"))
            Logger.shared.error("FileTransfer: failed to prepare incoming transfer \(transferID): \(error)")
        }
    }

    /// Reject an incoming file offer.
    func rejectTransfer(_ transferID: UUID, reason: String = "User declined") {
        sendMessage?(.fileReject, FileRejectMessage(transferID: transferID, reason: reason))
        if let idx = incomingTransfers.firstIndex(where: { $0.id == transferID }) {
            incomingTransfers[idx].state = .rejected(reason)
        }
        cleanupReceiveState(transferID)
        acceptedIncomingTransfers.remove(transferID)
    }

    // MARK: - Chunk handling (receiving side)

    func handleChunk(_ chunk: FileChunkMessage) {
        guard acceptedIncomingTransfers.contains(chunk.transferID) else { return }
        guard var state = receiveStates[chunk.transferID],
              let handle = state.fileHandle else { return }
        guard chunk.chunkIndex == state.expectedChunkIndex else {
            failReceive(chunk.transferID, reason: "Received chunk \(chunk.chunkIndex) out of order")
            return
        }
        guard let chunkData = Data(base64Encoded: chunk.base64Data) else {
            failReceive(chunk.transferID, reason: "Received invalid chunk data")
            return
        }
        guard state.receivedBytes + Int64(chunkData.count) <= state.fileSize else {
            failReceive(chunk.transferID, reason: "Received more data than the offered file size")
            return
        }

        do {
            try handle.write(contentsOf: chunkData)
        } catch {
            failReceive(chunk.transferID, reason: "Could not write incoming file: \(error.localizedDescription)")
            return
        }

        state.receivedBytes += Int64(chunkData.count)
        state.expectedChunkIndex += 1
        receiveStates[chunk.transferID] = state

        // Update progress.
        if let idx = incomingTransfers.firstIndex(where: { $0.id == chunk.transferID }) {
            let total = incomingTransfers[idx].fileSize
            if total > 0 {
                incomingTransfers[idx].progress = min(1, Double(state.receivedBytes) / Double(total))
            } else if chunk.isLast {
                incomingTransfers[idx].progress = 1
            }
        }

        if chunk.isLast {
            guard state.receivedBytes == state.fileSize else {
                failReceive(chunk.transferID, reason: "Transfer ended before all bytes arrived")
                return
            }
            finaliseReceive(chunk.transferID)
        }
    }

    private func finaliseReceive(_ transferID: UUID) {
        guard var state = receiveStates.removeValue(forKey: transferID),
              let tempURL = state.tempURL,
              let idx = incomingTransfers.firstIndex(where: { $0.id == transferID }) else { return }
        acceptedIncomingTransfers.remove(transferID)
        try? state.fileHandle?.close()
        state.fileHandle = nil

        let fileName = state.fileName
        let destURL = uniqueDestination(for: fileName)

        do {
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            incomingTransfers[idx].state = .completed
            incomingTransfers[idx].progress = 1.0
            incomingTransfers[idx].localURL = destURL
            Logger.shared.info("FileTransfer: received \(fileName) → \(destURL.path)")

            sendMessage?(.fileComplete, FileCompleteMessage(
                transferID: transferID,
                success: true,
                savedPath: destURL.lastPathComponent
            ))
        } catch {
            incomingTransfers[idx].state = .failed(error.localizedDescription)
            try? FileManager.default.removeItem(at: tempURL)
            Logger.shared.error("FileTransfer: failed to write \(fileName): \(error)")

            sendMessage?(.fileComplete, FileCompleteMessage(
                transferID: transferID,
                success: false,
                savedPath: nil
            ))
        }
    }

    // MARK: - Chunk sending (sending side)

    /// Called when the remote peer accepts our file offer.
    func handleAccept(_ accept: FileAcceptMessage) {
        guard let idx = outgoingTransfers.firstIndex(where: { $0.id == accept.transferID }),
              let url = outgoingTransfers[idx].localURL else { return }

        outgoingTransfers[idx].state = .accepted

        Task {
            await sendFileChunks(transferID: accept.transferID, fileURL: url)
        }
    }

    /// Called when the remote peer rejects our file offer.
    func handleReject(_ reject: FileRejectMessage) {
        if let idx = outgoingTransfers.firstIndex(where: { $0.id == reject.transferID }) {
            outgoingTransfers[idx].state = .rejected(reject.reason)
        }
    }

    /// Called when the remote peer confirms receipt.
    func handleComplete(_ complete: FileCompleteMessage) {
        if let idx = outgoingTransfers.firstIndex(where: { $0.id == complete.transferID }) {
            outgoingTransfers[idx].state = complete.success ? .completed : .failed("Remote write failed")
            outgoingTransfers[idx].progress = 1.0
        }
    }

    private func sendFileChunks(transferID: UUID, fileURL: URL) async {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            if let idx = outgoingTransfers.firstIndex(where: { $0.id == transferID }) {
                outgoingTransfers[idx].state = .failed("Cannot read file")
            }
            return
        }
        defer { try? handle.close() }

        let fileSize = outgoingTransfers.first(where: { $0.id == transferID })?.fileSize ?? 0
        var chunkIndex = 0
        var totalSent: Int64 = 0

        if fileSize == 0 {
            let chunk = FileChunkMessage(
                transferID: transferID,
                chunkIndex: 0,
                base64Data: "",
                isLast: true
            )
            sendMessage?(.fileChunk, chunk)
            if let idx = outgoingTransfers.firstIndex(where: { $0.id == transferID }) {
                outgoingTransfers[idx].progress = 1
            }
            Logger.shared.info("FileTransfer: sent empty file \(fileURL.lastPathComponent)")
            return
        }

        while true {
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else {
                break
            }
            totalSent += Int64(data.count)
            let isLast = totalSent >= fileSize

            let chunk = FileChunkMessage(
                transferID: transferID,
                chunkIndex: chunkIndex,
                base64Data: data.base64EncodedString(),
                isLast: isLast
            )
            sendMessage?(.fileChunk, chunk)

            if let idx = outgoingTransfers.firstIndex(where: { $0.id == transferID }) {
                outgoingTransfers[idx].progress = fileSize > 0 ? Double(totalSent) / Double(fileSize) : 1.0
            }

            chunkIndex += 1

            // Yield to avoid blocking the main actor on large files.
            if chunkIndex % 10 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms throttle every 10 chunks
            }
        }

        Logger.shared.info("FileTransfer: sent \(chunkIndex) chunks for \(fileURL.lastPathComponent)")
    }

    // MARK: - Helpers

    nonisolated static func sanitizedFileName(_ rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed == (trimmed as NSString).lastPathComponent else { return nil }
        guard !trimmed.contains("/") && !trimmed.contains("\\") && !trimmed.contains(":") else { return nil }
        guard trimmed != "." && trimmed != ".." else { return nil }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }

    private func rejectIncomingOffer(_ transferID: UUID, fileName: String, reason: String) {
        sendMessage?(.fileReject, FileRejectMessage(transferID: transferID, reason: reason))
        incomingTransfers.append(FileTransfer(
            id: transferID,
            fileName: fileName,
            fileSize: 0,
            mimeType: "application/octet-stream",
            state: .rejected(reason),
            progress: 0,
            localURL: nil
        ))
    }

    private func failReceive(_ transferID: UUID, reason: String) {
        cleanupReceiveState(transferID)
        acceptedIncomingTransfers.remove(transferID)
        if let idx = incomingTransfers.firstIndex(where: { $0.id == transferID }) {
            incomingTransfers[idx].state = .failed(reason)
        }
        sendMessage?(.fileComplete, FileCompleteMessage(
            transferID: transferID,
            success: false,
            savedPath: nil
        ))
        Logger.shared.error("FileTransfer: failed incoming transfer \(transferID): \(reason)")
    }

    private func cleanupReceiveState(_ transferID: UUID) {
        guard var state = receiveStates.removeValue(forKey: transferID) else { return }
        try? state.fileHandle?.close()
        state.fileHandle = nil
        if let tempURL = state.tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func makeReceiveTempURL(transferID: UUID, fileName: String) throws -> URL {
        let tempDir = downloadDirectory.appendingPathComponent(".screenq-incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir.appendingPathComponent("\(transferID.uuidString)-\(fileName)")
    }

    private func uniqueDestination(for fileName: String) -> URL {
        let safeFileName = Self.sanitizedFileName(fileName) ?? "ScreenQ Transfer"
        var dest = downloadDirectory.appendingPathComponent(safeFileName)
        var counter = 1
        let name = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            dest = downloadDirectory.appendingPathComponent(newName)
            counter += 1
        }
        return dest
    }
}

/// Placeholder for streaming file reads (unused for now — we read in chunks via FileHandle).
private struct FileReadStream {
    let url: URL
    let handle: FileHandle
}
