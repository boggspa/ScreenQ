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
    var isTransferEnabled: Bool = true
    var disabledReason: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if !service.incomingTransfers.isEmpty || !service.outgoingTransfers.isEmpty {
                transferList
            } else if !isTransferEnabled, let disabledReason {
                disabledStatus(reason: disabledReason)
            }
        }
        .overlay(dropTargetIndicator)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard isTransferEnabled else { return false }
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Drop target indicator

    @ViewBuilder
    private var dropTargetIndicator: some View {
        if isDropTargeted && isTransferEnabled {
            RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(ScreenQTheme.cosmicCyan, style: StrokeStyle(lineWidth: 3, dash: [12, 6]))
                .background(
                    RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous)
                        .fill(ScreenQTheme.cosmicCyan.opacity(0.10))
                )
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 40))
                            .foregroundColor(ScreenQTheme.cosmicCyan)
                            .accessibilityHidden(true)
                        Text("Drop files to send")
                            .font(.sqHeadline)
                            .foregroundColor(ScreenQTheme.cosmicCyan)
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
                transferRow(transfer, direction: "Incoming", isIncoming: true)
            }
            ForEach(service.outgoingTransfers) { transfer in
                transferRow(transfer, direction: "Outgoing", isIncoming: false)
            }
        }
        .padding(12)
        .frame(maxWidth: 320)
        .screenQGlass(cornerRadius: ScreenQTheme.panelCornerRadius)
        .padding(12)
    }

    @ViewBuilder
    private func transferRow(_ transfer: FileTransferService.FileTransfer, direction: String, isIncoming: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon(for: transfer.mimeType))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.fileName)
                    .font(.sqCallout)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(direction)
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                    SQPill(text: stateLabel(transfer.state), status: stateStatus(transfer.state), compact: true)
                }
                Text(ByteFormatting.human(Int(min(transfer.fileSize, Int64(Int.max)))))
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isIncoming && transfer.state == .offered {
                HStack(spacing: 6) {
                    Button("Decline") {
                        SQHaptics.tap()
                        service.rejectTransfer(transfer.id)
                    }
                    .buttonStyle(.bordered)
                    Button("Accept") {
                        SQHaptics.success()
                        service.acceptTransfer(transfer.id)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.mini)
            } else if transfer.state == .receiving || transfer.state == .accepted || (!isIncoming && transfer.state == .offered) {
                HStack(spacing: 6) {
                    ProgressView(value: transfer.progress)
                        .accentColor(ScreenQTheme.cosmicCyan)
                        .frame(width: 60)
                    Button {
                        SQHaptics.warning()
                        service.rejectTransfer(transfer.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(ScreenQTheme.cosmicRose)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel transfer")
                }
            } else if case .completed = transfer.state {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(ScreenQTheme.cosmicMint)
                    .accessibilityLabel("Completed")
            } else if case .failed = transfer.state {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(ScreenQTheme.cosmicRose)
                    .accessibilityLabel("Failed")
            } else if case .rejected = transfer.state {
                Image(systemName: "xmark.circle")
                    .foregroundColor(ScreenQTheme.cosmicAmber)
                    .accessibilityLabel("Rejected")
            }
        }
        .screenQCard(padding: 10)
        .accessibilityElement(children: .contain)
    }

    private func disabledStatus(reason: String) -> some View {
        Label(reason, systemImage: "doc.badge.arrow.up")
            .font(.sqCaption)
            .foregroundColor(.secondary)
            .padding(10)
            .screenQGlass(cornerRadius: ScreenQTheme.pillCornerRadius)
            .padding(12)
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
        case .offered:        return "Needs approval"
        case .accepted:       return "Sending…"
        case .receiving:      return "Receiving…"
        case .completed:      return "Done"
        case .rejected(let r): return "Rejected: \(r)"
        case .failed(let e):  return "Failed: \(e)"
        }
    }

    private func stateStatus(_ state: FileTransferService.TransferState) -> SQStatus {
        switch state {
        case .offered:    return .attention
        case .accepted:   return .info
        case .receiving:  return .info
        case .completed:  return .healthy
        case .rejected:   return .attention
        case .failed:     return .error
        }
    }
}
