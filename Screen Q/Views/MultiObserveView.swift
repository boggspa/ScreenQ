//
//  MultiObserveView.swift
//  Screen Q
//
//  Tiles multiple live screen thumbnails from connected hosts, similar to
//  ARD's multi-observe mode. Each tile is a downscaled live view with
//  the host's name overlaid. Tapping a tile opens a full session.
//

import SwiftUI
import Combine

@MainActor
final class MultiObserveStore: ObservableObject {

    struct ObserveTile: Identifiable {
        let id = UUID()
        let label: String
        let connection: ScreenQConnection
        let renderer: RemoteScreenRenderer
    }

    @Published var tiles: [ObserveTile] = []

    func addTile(label: String, connection: ScreenQConnection) {
        let renderer = RemoteScreenRenderer()
        let tile = ObserveTile(label: label, connection: connection, renderer: renderer)
        tiles.append(tile)

        Task {
            // Send a view-only hello and begin receiving frames.
            for await message in await connection.inboundMessages() {
                switch message {
                case .videoFormat(let format):
                    renderer.updateFormat(format)
                case .videoFrame(let meta, let payload):
                    renderer.ingest(meta: meta, payload: payload, stats: nil)
                default:
                    break
                }
            }
            // Connection ended — remove tile.
            tiles.removeAll { $0.id == tile.id }
        }
    }

    func removeTile(_ id: UUID) {
        if let tile = tiles.first(where: { $0.id == id }) {
            Task { await tile.connection.stop() }
        }
        tiles.removeAll { $0.id == id }
    }

    func removeAll() {
        for tile in tiles {
            Task { await tile.connection.stop() }
        }
        tiles.removeAll()
    }
}

struct MultiObserveView: View {

    @ObservedObject var store: MultiObserveStore
    var onSelectTile: ((MultiObserveStore.ObserveTile) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 12)
    ]

    var body: some View {
        Group {
            if store.tiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No observed machines")
                        .font(.headline)
                    Text("Open two or more sessions, then use the multi-observe button.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.tiles) { tile in
                            tileView(tile)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Multi-Observe (\(store.tiles.count))")
    }

    @ViewBuilder
    private func tileView(_ tile: MultiObserveStore.ObserveTile) -> some View {
        ObserveTileView(tile: tile, onSelect: {
            onSelectTile?(tile)
        }, onRemove: {
            store.removeTile(tile.id)
        })
    }
}

private struct ObserveTileView: View {
    let tile: MultiObserveStore.ObserveTile
    @ObservedObject var renderer: RemoteScreenRenderer
    var onSelect: () -> Void
    var onRemove: () -> Void

    init(
        tile: MultiObserveStore.ObserveTile,
        onSelect: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.tile = tile
        self.renderer = tile.renderer
        self.onSelect = onSelect
        self.onRemove = onRemove
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let img = renderer.currentImage {
                    Image(decorative: img, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .foregroundColor(.white)
                }
            }
            .aspectRatio(16/10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                onSelect()
            }

            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text(tile.label)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MultiObserveSessionGrid: View {
    @ObservedObject var store: ViewerSessionStore
    var onSelectSession: (UUID) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 460), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Multi-Observe", systemImage: "rectangle.3.group")
                    .font(.headline)
                Text("\(store.sessions.count) live")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.sessions) { slot in
                        LiveSessionObserveTile(
                            slot: slot,
                            onSelect: { onSelectSession(slot.id) },
                            onClose: {
                                Task { await store.closeSession(id: slot.id) }
                            }
                        )
                    }
                }
                .padding(16)
            }
            .background(Color.black)
        }
    }
}

private struct LiveSessionObserveTile: View {
    let slot: ViewerSessionSlot
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        switch slot.kind {
        case .screenQ(let session):
            ScreenQObserveSessionTile(
                label: slot.label,
                session: session,
                onSelect: onSelect,
                onClose: onClose
            )
        case .vnc(let session):
            VNCObserveSessionTile(
                label: slot.label,
                session: session,
                onSelect: onSelect,
                onClose: onClose
            )
        case .rdp(let session):
            RDPObserveSessionTile(
                label: slot.label,
                session: session,
                onSelect: onSelect,
                onClose: onClose
            )
        }
    }
}

private struct ScreenQObserveSessionTile: View {
    let label: String
    @ObservedObject var session: ViewerSession
    @ObservedObject private var renderer: RemoteScreenRenderer
    var onSelect: () -> Void
    var onClose: () -> Void

    init(label: String, session: ViewerSession, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.label = label
        self.session = session
        self._renderer = ObservedObject(wrappedValue: session.renderer)
        self.onSelect = onSelect
        self.onClose = onClose
    }

    var body: some View {
        ObserveSessionTileChrome(
            label: label,
            detail: session.phase.humanDescription,
            systemImage: "display",
            statusColor: session.phase.isActive ? .green : .secondary,
            onSelect: onSelect,
            onClose: onClose
        ) {
            if let image = renderer.currentImage {
                observeImage(image)
            } else if let region = renderer.currentRegionFrame {
                observeImage(region.image)
            } else {
                tilePlaceholder("Waiting for frames")
            }
        }
    }
}

private struct VNCObserveSessionTile: View {
    let label: String
    @ObservedObject var session: VNCSession
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        ObserveSessionTileChrome(
            label: label,
            detail: vncStatus,
            systemImage: "rectangle.on.rectangle",
            statusColor: vncStatusColor,
            onSelect: onSelect,
            onClose: onClose
        ) {
            if let image = session.currentImage {
                observeImage(image)
            } else {
                tilePlaceholder("Waiting for framebuffer")
            }
        }
    }

    private var vncStatus: String {
        switch session.phase {
        case .connecting: return "Connecting"
        case .authenticating: return "Authenticating"
        case .connected: return session.serverWidth > 0 ? "\(session.serverWidth)x\(session.serverHeight)" : "Connected"
        case .reconnecting(let attempt): return "Reconnecting \(attempt)"
        case .failed: return "Failed"
        case .ended: return "Ended"
        }
    }

    private var vncStatusColor: Color {
        switch session.phase {
        case .connected: return .green
        case .failed: return .red
        case .reconnecting: return .orange
        default: return .secondary
        }
    }
}

private struct RDPObserveSessionTile: View {
    let label: String
    @ObservedObject var session: RDPSession
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        ObserveSessionTileChrome(
            label: label,
            detail: rdpStatus,
            systemImage: "pc",
            statusColor: rdpStatusColor,
            onSelect: onSelect,
            onClose: onClose
        ) {
            if let image = session.currentImage {
                observeImage(image)
            } else {
                tilePlaceholder("Waiting for RDP frames")
            }
        }
    }

    private var rdpStatus: String {
        switch session.phase {
        case .preflighting: return "Preflighting"
        case .credentialsRequired: return "Credentials required"
        case .connecting: return "Connecting"
        case .certificateTrustRequired: return "Certificate review"
        case .connected: return session.remoteWidth > 0 ? "\(session.remoteWidth)x\(session.remoteHeight)" : "Connected"
        case .engineUnavailable: return "Engine unavailable"
        case .failed: return "Failed"
        case .ended: return "Ended"
        }
    }

    private var rdpStatusColor: Color {
        switch session.phase {
        case .connected: return .green
        case .failed, .engineUnavailable: return .red
        case .certificateTrustRequired, .credentialsRequired: return .orange
        default: return .secondary
        }
    }
}

private struct ObserveSessionTileChrome<FrameContent: View>: View {
    let label: String
    let detail: String
    let systemImage: String
    let statusColor: Color
    var onSelect: () -> Void
    var onClose: () -> Void
    @ViewBuilder var frameContent: () -> FrameContent

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                frameContent()
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Close \(label)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.gray.opacity(0.14))
        }
        .background(Color.gray.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .contextMenu {
            Button("Open") { onSelect() }
            Button("Close") { onClose() }
        }
    }
}

private func observeImage(_ image: CGImage) -> some View {
    Image(decorative: image, scale: 1.0)
        .resizable()
        .interpolation(.medium)
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private func tilePlaceholder(_ text: String) -> some View {
    VStack(spacing: 8) {
        ProgressView()
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
