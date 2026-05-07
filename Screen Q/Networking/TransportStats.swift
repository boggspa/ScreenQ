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
    @Published private(set) var frameLatencyMillis: Double = 0
    @Published private(set) var peakFrameLatencyMillis: Double = 0
    @Published private(set) var droppedFrames: Int = 0
    @Published private(set) var lastFrameSize: Int = 0
    @Published private(set) var totalBytes: Int = 0

    private var lastFrameTimestamps: [Date] = []
    private var byteSamples: [(Date, Int)] = []
    private var frameLatencySamples: [(Date, Double)] = []

    func recordFrame(byteCount: Int, latencyMillis: Double? = nil) {
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
        if let latencyMillis {
            recordFrameLatency(latencyMillis, now: now)
        }
        recompute()
    }

    func recordDiscardedFrame(byteCount: Int, latencyMillis: Double? = nil) {
        let now = Date()
        droppedFrames += 1
        if let latencyMillis {
            recordFrameLatency(latencyMillis, now: now)
        }
        recompute()
    }

    func recordDropped() {
        droppedFrames += 1
    }

    func recordRoundTrip(millis: Double) {
        guard millis.isFinite else { return }
        let safe = max(0, min(10_000, millis))
        roundTripMillis = roundTripMillis > 0 ? (roundTripMillis * 0.7 + safe * 0.3) : safe
    }

    func clearFrameLatency() {
        frameLatencyMillis = 0
        peakFrameLatencyMillis = 0
        frameLatencySamples.removeAll()
    }

    func snapshotMessage() -> StatsMessage {
        StatsMessage(
            fps: fps,
            bytesPerSecond: bytesPerSecond,
            droppedFrames: droppedFrames,
            roundTripMillis: roundTripMillis,
            frameLatencyMillis: frameLatencyMillis,
            peakFrameLatencyMillis: peakFrameLatencyMillis
        )
    }

    func applyRemoteStats(_ message: StatsMessage) {
        fps = message.fps.isFinite ? max(0, message.fps) : 0
        bytesPerSecond = message.bytesPerSecond.isFinite ? max(0, message.bytesPerSecond) : 0
        droppedFrames = max(0, message.droppedFrames)
        if message.roundTripMillis.isFinite {
            roundTripMillis = max(0, min(10_000, message.roundTripMillis))
        }
        if let frameLatencyMillis = message.frameLatencyMillis, frameLatencyMillis.isFinite {
            self.frameLatencyMillis = max(0, min(10_000, frameLatencyMillis))
        }
        if let peakFrameLatencyMillis = message.peakFrameLatencyMillis, peakFrameLatencyMillis.isFinite {
            self.peakFrameLatencyMillis = max(0, min(10_000, peakFrameLatencyMillis))
        }
    }

    func reset() {
        fps = 0
        bytesPerSecond = 0
        roundTripMillis = 0
        frameLatencyMillis = 0
        peakFrameLatencyMillis = 0
        droppedFrames = 0
        lastFrameSize = 0
        totalBytes = 0
        lastFrameTimestamps.removeAll()
        byteSamples.removeAll()
        frameLatencySamples.removeAll()
    }

    private func recordFrameLatency(_ millis: Double, now: Date) {
        guard millis.isFinite else { return }
        let safe = max(0, min(10_000, millis))
        frameLatencyMillis = frameLatencyMillis > 0 ? (frameLatencyMillis * 0.75 + safe * 0.25) : safe
        frameLatencySamples.append((now, safe))
        if frameLatencySamples.count > 240 {
            frameLatencySamples.removeFirst(frameLatencySamples.count - 240)
        }
    }

    private func recompute() {
        let now = Date()
        let oneSecondAgo = now.addingTimeInterval(-1)
        let recentFrames = lastFrameTimestamps.filter { $0 >= oneSecondAgo }
        fps = Double(recentFrames.count)
        let recentBytes = byteSamples.filter { $0.0 >= oneSecondAgo }.reduce(0) { $0 + $1.1 }
        bytesPerSecond = Double(recentBytes)
        let fiveSecondsAgo = now.addingTimeInterval(-5)
        frameLatencySamples = frameLatencySamples.filter { $0.0 >= fiveSecondsAgo }
        peakFrameLatencyMillis = frameLatencySamples.map(\.1).max() ?? 0
    }
}
