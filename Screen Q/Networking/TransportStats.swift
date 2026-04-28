//
//  TransportStats.swift
//  Screen Q
//
//  UI-friendly transport metrics. Updated by the host capture loop and
//  the viewer receive loop, observed by DiagnosticsView and RemoteScreenView.
//

import Foundation
import Combine

@MainActor
final class TransportStats: ObservableObject {

    @Published private(set) var fps: Double = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var roundTripMillis: Double = 0
    @Published private(set) var droppedFrames: Int = 0
    @Published private(set) var lastFrameSize: Int = 0
    @Published private(set) var totalBytes: Int = 0

    private var lastFrameTimestamps: [Date] = []
    private var byteSamples: [(Date, Int)] = []

    func recordFrame(byteCount: Int) {
        let now = Date()
        lastFrameTimestamps.append(now)
        if lastFrameTimestamps.count > 60 {
            lastFrameTimestamps.removeFirst(lastFrameTimestamps.count - 60)
        }
        byteSamples.append((now, byteCount))
        if byteSamples.count > 120 {
            byteSamples.removeFirst(byteSamples.count - 120)
        }
        lastFrameSize = byteCount
        totalBytes += byteCount
        recompute()
    }

    func recordDropped() {
        droppedFrames += 1
    }

    func recordRoundTrip(millis: Double) {
        roundTripMillis = millis
    }

    func reset() {
        fps = 0
        bytesPerSecond = 0
        roundTripMillis = 0
        droppedFrames = 0
        lastFrameSize = 0
        totalBytes = 0
        lastFrameTimestamps.removeAll()
        byteSamples.removeAll()
    }

    private func recompute() {
        let now = Date()
        let oneSecondAgo = now.addingTimeInterval(-1)
        let recentFrames = lastFrameTimestamps.filter { $0 >= oneSecondAgo }
        fps = Double(recentFrames.count)
        let recentBytes = byteSamples.filter { $0.0 >= oneSecondAgo }.reduce(0) { $0 + $1.1 }
        bytesPerSecond = Double(recentBytes)
    }
}
