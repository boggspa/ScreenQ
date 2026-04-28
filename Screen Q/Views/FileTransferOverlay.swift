//
//  FileTransferOverlay.swift
//  Screen Q
//
//  Overlay UI for file transfers: shows incoming/outgoing progress,
//  accept/reject buttons for incoming offers, and a drop zone indicator.
//  Also provides a macOS drop target for dragging files into the viewer.
//

import SwiftUI
import UniformTypeIdentifiers

struct FileTransferOverlay: View {

    @ObservedObject var service: FileTransferService
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if !service.incomingTransfers.isEmpty || !service.outgoingTransfers.isEmpty {
                transferList
            }
        }
        .overlay(dropTargetIndicator)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Drop target indicator

    @ViewBuilder
    private var dropTargetIndicator: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [12, 6]))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.1))
                )
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.accentColor)
                        Text("Drop files to send")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    }
                )
                .padding(20)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Transfer list

    private var transferList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(service.incomingTransfers) { transfer in
                transferRow(transfer, direction: "Receiving")
            }
            ForEach(service.outgoingTransfers) { transfer in
                transferRow(transfer, direction: "Sending")
            }
        }
        .padding(12)
        .frame(maxWidth: 320)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(12)
    }

    @ViewBuilder
    private func transferRow(_ transfer: FileTransferService.FileTransfer, direction: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon(for: transfer.mimeType))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.fileName)
                    .font(.caption.bold())
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(direction)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(stateLabel(transfer.state))
                        .font(.caption2)
                        .foregroundColor(stateColor(transfer.state))
                }
            }
            Spacer()
            if transfer.state == .receiving || transfer.state == .accepted || transfer.state == .offered {
                ProgressView(value: transfer.progress)
                    .frame(width: 60)
            } else if case .completed = transfer.state {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if case .failed = transfer.state {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            } else if case .rejected = transfer.state {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let urlData = data as? Data,
                      let url = URL(dataRepresentation: urlData, relativeTo: nil) else { return }
                Task { @MainActor in
                    service.offerFile(at: url)
                }
            }
        }
    }

    // MARK: - Helpers

    private func fileIcon(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("text/") { return "doc.text" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("zip") || mime.contains("archive") { return "doc.zipper" }
        return "doc"
    }

    private func stateLabel(_ state: FileTransferService.TransferState) -> String {
        switch state {
        case .offered:        return "Waiting…"
        case .accepted:       return "Sending…"
        case .receiving:      return "Receiving…"
        case .completed:      return "Done"
        case .rejected(let r): return "Rejected: \(r)"
        case .failed(let e):  return "Failed: \(e)"
        }
    }

    private func stateColor(_ state: FileTransferService.TransferState) -> Color {
        switch state {
        case .completed:  return .green
        case .rejected:   return .orange
        case .failed:     return .red
        default:          return .secondary
        }
    }
}
