//
//  AdaptiveBitrateController.swift
//  Screen Q
//
//  Monitors transport stats (RTT, dropped frames, bandwidth) and dynamically
//  adjusts the H.264 encoder bitrate and capture FPS to maintain smooth
//  streaming under varying network conditions.
//

import Foundation
import Combine

@MainActor
final class AdaptiveBitrateController: ObservableObject {

    struct Config: Sendable {
        var minBitrate: Int = 500_000       // 500 kbps floor
        var maxBitrate: Int = 16_000_000    // 16 Mbps ceiling
        var minFPS: Int = 5
        var maxFPS: Int = 60
        var rttThresholdUp: Double = 30     // ms — if RTT < this, increase quality
        var rttThresholdDown: Double = 100  // ms — if RTT > this, decrease quality
        var frameLatencyThresholdUp: Double = 120
        var frameLatencyThresholdDown: Double = 280
        var severeFrameLatencyThreshold: Double = 1_000
        var dropThreshold: Int = 3          // dropped frames in window → decrease
        var adjustIntervalSeconds: TimeInterval = 2.0

        nonisolated init(
            minBitrate: Int = 500_000,
            maxBitrate: Int = 16_000_000,
            minFPS: Int = 5,
            maxFPS: Int = 60,
            rttThresholdUp: Double = 30,
            rttThresholdDown: Double = 100,
            frameLatencyThresholdUp: Double = 120,
            frameLatencyThresholdDown: Double = 280,
            severeFrameLatencyThreshold: Double = 1_000,
            dropThreshold: Int = 3,
            adjustIntervalSeconds: TimeInterval = 2.0
        ) {
            self.minBitrate = minBitrate
            self.maxBitrate = maxBitrate
            self.minFPS = minFPS
            self.maxFPS = maxFPS
            self.rttThresholdUp = rttThresholdUp
            self.rttThresholdDown = rttThresholdDown
            self.frameLatencyThresholdUp = frameLatencyThresholdUp
            self.frameLatencyThresholdDown = frameLatencyThresholdDown
            self.severeFrameLatencyThreshold = severeFrameLatencyThreshold
            self.dropThreshold = dropThreshold
            self.adjustIntervalSeconds = adjustIntervalSeconds
        }
    }

    @Published private(set) var currentBitrate: Int
    @Published private(set) var currentFPS: Int
    @Published private(set) var trend: Trend = .stable

    enum Trend: String { case up, down, stable }

    var config: Config
    private var lastAdjust = Date.distantPast
    private var prevDropped: Int = 0

    init(config: Config = Config()) {
        self.config = config
        self.currentBitrate = config.maxBitrate / 2  // start at 50%
        self.currentFPS = 30
    }

    func setUserCeiling(bitrate: Int, fps: Int) {
        config.maxBitrate = max(config.minBitrate, bitrate)
        config.maxFPS = max(config.minFPS, fps)
        currentBitrate = min(currentBitrate, config.maxBitrate)
        currentFPS = min(currentFPS, config.maxFPS)
    }

    /// Called periodically with current transport stats. Returns true if settings changed.
    @discardableResult
    func evaluate(stats: TransportStats) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastAdjust) >= config.adjustIntervalSeconds else { return false }
        lastAdjust = now
        guard stats.totalBytes > 0 ||
                stats.roundTripMillis > 0 ||
                stats.frameLatencyMillis > 0 ||
                stats.peakFrameLatencyMillis > 0 ||
                stats.droppedFrames > 0 else {
            trend = .stable
            return false
        }

        let rtt = stats.roundTripMillis
        let frameLatency = stats.frameLatencyMillis
        let peakFrameLatency = stats.peakFrameLatencyMillis
        let worstFrameLatency = max(frameLatency, peakFrameLatency)
        let newDrops = stats.droppedFrames - prevDropped
        prevDropped = stats.droppedFrames

        var changed = false

        if worstFrameLatency > config.severeFrameLatencyThreshold {
            let newBitrate = max(config.minBitrate, currentBitrate * 45 / 100)
            let newFPS = max(config.minFPS, currentFPS - 10)
            if newBitrate != currentBitrate || newFPS != currentFPS {
                currentBitrate = newBitrate
                currentFPS = newFPS
                trend = .down
                changed = true
                Logger.shared.debug("ABR ↓↓ bitrate=\(currentBitrate/1000)kbps fps=\(currentFPS) (frameLatency=\(Int(worstFrameLatency))ms)")
            }
        } else if rtt > config.rttThresholdDown ||
                    worstFrameLatency > config.frameLatencyThresholdDown ||
                    newDrops >= config.dropThreshold {
            let newBitrate = max(config.minBitrate, currentBitrate * 70 / 100)
            let newFPS = max(config.minFPS, currentFPS - 5)
            if newBitrate != currentBitrate || newFPS != currentFPS {
                currentBitrate = newBitrate
                currentFPS = newFPS
                trend = .down
                changed = true
                Logger.shared.debug("ABR ↓ bitrate=\(currentBitrate/1000)kbps fps=\(currentFPS) (rtt=\(Int(rtt))ms frameLatency=\(Int(worstFrameLatency))ms drops=\(newDrops))")
            }
        } else if rtt < config.rttThresholdUp &&
                    (frameLatency == 0 || frameLatency < config.frameLatencyThresholdUp) &&
                    newDrops == 0 {
            let newBitrate = min(config.maxBitrate, currentBitrate * 120 / 100)
            let newFPS = min(config.maxFPS, currentFPS + 5)
            if newBitrate != currentBitrate || newFPS != currentFPS {
                currentBitrate = newBitrate
                currentFPS = newFPS
                trend = .up
                changed = true
                Logger.shared.debug("ABR ↑ bitrate=\(currentBitrate/1000)kbps fps=\(currentFPS)")
            }
        } else {
            trend = .stable
        }

        return changed
    }
}
