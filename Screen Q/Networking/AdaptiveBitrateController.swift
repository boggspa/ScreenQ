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
        var dropThreshold: Int = 3          // dropped frames in window → decrease
        var adjustIntervalSeconds: TimeInterval = 2.0
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

    /// Called periodically with current transport stats. Returns true if settings changed.
    @discardableResult
    func evaluate(stats: TransportStats) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastAdjust) >= config.adjustIntervalSeconds else { return false }
        lastAdjust = now
        guard stats.totalBytes > 0 || stats.roundTripMillis > 0 || stats.droppedFrames > 0 else {
            trend = .stable
            return false
        }

        let rtt = stats.roundTripMillis
        let newDrops = stats.droppedFrames - prevDropped
        prevDropped = stats.droppedFrames

        var changed = false

        if rtt > config.rttThresholdDown || newDrops >= config.dropThreshold {
            // Network struggling — reduce quality
            let newBitrate = max(config.minBitrate, currentBitrate * 70 / 100)
            let newFPS = max(config.minFPS, currentFPS - 5)
            if newBitrate != currentBitrate || newFPS != currentFPS {
                currentBitrate = newBitrate
                currentFPS = newFPS
                trend = .down
                changed = true
                Logger.shared.debug("ABR ↓ bitrate=\(currentBitrate/1000)kbps fps=\(currentFPS) (rtt=\(Int(rtt))ms drops=\(newDrops))")
            }
        } else if rtt < config.rttThresholdUp && newDrops == 0 {
            // Network healthy — increase quality
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
