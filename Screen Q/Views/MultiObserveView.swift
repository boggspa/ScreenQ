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
                    Text("Add computers from the fleet sidebar to observe them.")
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
