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
    @Published var autoAcceptIncoming: Bool = false

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
    var downloadDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory

    // MARK: - Callbacks (set by the session that owns us)

    var sendMessage: ((MessageType, any Encodable) -> Void)?

    // MARK: - Internal state

    private var receiveBuffers: [UUID: Data] = [:]
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
        let transfer = FileTransfer(
            id: offer.transferID,
            fileName: offer.fileName,
            fileSize: offer.fileSize,
            mimeType: offer.mimeType,
            state: .offered,
            progress: 0,
            localURL: nil
        )
        incomingTransfers.append(transfer)
        receiveBuffers[offer.transferID] = Data()

        if autoAcceptIncoming {
            acceptTransfer(offer.transferID)
        }
    }

    /// Accept an incoming file offer.
    func acceptTransfer(_ transferID: UUID) {
        acceptedIncomingTransfers.insert(transferID)
        if let idx = incomingTransfers.firstIndex(where: { $0.id == transferID }) {
            incomingTransfers[idx].state = .receiving
        }
        sendMessage?(.fileAccept, FileAcceptMessage(transferID: transferID))
    }

    /// Reject an incoming file offer.
    func rejectTransfer(_ transferID: UUID, reason: String = "User declined") {
        sendMessage?(.fileReject, FileRejectMessage(transferID: transferID, reason: reason))
        incomingTransfers.removeAll { $0.id == transferID }
        receiveBuffers.removeValue(forKey: transferID)
        acceptedIncomingTransfers.remove(transferID)
    }

    // MARK: - Chunk handling (receiving side)

    func handleChunk(_ chunk: FileChunkMessage) {
        guard acceptedIncomingTransfers.contains(chunk.transferID) else { return }
        guard var buffer = receiveBuffers[chunk.transferID] else { return }
        guard let chunkData = Data(base64Encoded: chunk.base64Data) else { return }
        buffer.append(chunkData)
        receiveBuffers[chunk.transferID] = buffer

        // Update progress.
        if let idx = incomingTransfers.firstIndex(where: { $0.id == chunk.transferID }) {
            let total = incomingTransfers[idx].fileSize
            if total > 0 {
                incomingTransfers[idx].progress = Double(buffer.count) / Double(total)
            }
        }

        if chunk.isLast {
            finaliseReceive(chunk.transferID)
        }
    }

    private func finaliseReceive(_ transferID: UUID) {
        guard let buffer = receiveBuffers.removeValue(forKey: transferID),
              let idx = incomingTransfers.firstIndex(where: { $0.id == transferID }) else { return }
        acceptedIncomingTransfers.remove(transferID)

        let fileName = incomingTransfers[idx].fileName
        let destURL = uniqueDestination(for: fileName)

        do {
            try buffer.write(to: destURL)
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

    private func uniqueDestination(for fileName: String) -> URL {
        var dest = downloadDirectory.appendingPathComponent(fileName)
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
