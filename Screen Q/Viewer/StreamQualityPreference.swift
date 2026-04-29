//
//  StreamQualityPreference.swift
//  Screen Q
//
//  Shared viewer-side quality intent. Native Screen Q can apply most of this
//  directly; adapter protocols use the parts their current engine exposes.
//

import Foundation

nonisolated struct StreamQualityPreference: Codable, Hashable, Sendable {
    static let defaultQuality: Double = 0.65
    static let allowedRange: ClosedRange<Double> = 0.2...1.0

    var quality: Double

    init(quality: Double = Self.defaultQuality) {
        self.quality = Self.clamp(quality)
    }

    var normalized: Double {
        let range = Self.allowedRange.upperBound - Self.allowedRange.lowerBound
        guard range > 0 else { return 0 }
        return (quality - Self.allowedRange.lowerBound) / range
    }

    var percent: Int {
        Int((quality * 100).rounded())
    }

    var jpegQuality: Double {
        interpolate(min: 0.25, max: 0.95)
    }

    var nativeTargetBitrate: Int {
        Int(interpolate(min: 1_000_000, max: 30_000_000).rounded())
    }

    var nativeTargetFPS: Int {
        Int(interpolate(min: 15, max: 60).rounded())
    }

    var vncTargetFPS: Int {
        Int(interpolate(min: 6, max: 24).rounded())
    }

    var rdpTargetFPS: Int {
        Int(interpolate(min: 12, max: 30).rounded())
    }

    var nativeMessage: StreamQualityMessage {
        StreamQualityMessage(
            quality: quality,
            targetBitrate: nativeTargetBitrate,
            targetFPS: nativeTargetFPS,
            jpegQuality: jpegQuality
        )
    }

    func vncImagePublishInterval(isIOS: Bool) -> TimeInterval {
        let maxFPS = isIOS ? vncTargetFPS : max(12, min(30, vncTargetFPS + 6))
        return 1.0 / Double(max(1, maxFPS))
    }

    func vncRenderMaxDimension(isIOS: Bool) -> Int? {
        guard isIOS else { return nil }
        return Int(interpolate(min: 1_024, max: 2_560).rounded())
    }

    func vncMaxStreamPixels(isFullDesktop: Bool, isIOS: Bool) -> Int {
        guard isIOS else { return Int.max / 4 }
        if isFullDesktop {
            return Int(interpolate(min: 2_400_000, max: 30_000_000).rounded())
        }
        return Int(interpolate(min: 700_000, max: 2_000_000).rounded())
    }

    func vncDefaultStreamPixels(isFullDesktop: Bool, isIOS: Bool) -> Int {
        guard isIOS else { return Int.max / 4 }
        if isFullDesktop {
            return Int(interpolate(min: 1_500_000, max: 18_000_000).rounded())
        }
        return Int(interpolate(min: 500_000, max: 1_500_000).rounded())
    }

    func vncFullRegionPixelLimit(isIOS: Bool) -> Int {
        guard isIOS else { return Int.max / 4 }
        return Int(interpolate(min: 2_500_000, max: 30_000_000).rounded())
    }

    func rdpFramePublishInterval() -> TimeInterval {
        1.0 / Double(max(1, rdpTargetFPS))
    }

    func estimatedBitrateText(protocolName: String) -> String {
        switch protocolName {
        case "RDP":
            return "viewer cadence \(rdpTargetFPS) fps"
        case "Mac Screen Sharing", "Generic VNC", "VNC":
            return "viewport cadence \(vncTargetFPS) fps"
        default:
            return "\(Self.formatMbps(nativeTargetBitrate)) at \(nativeTargetFPS) fps"
        }
    }

    private func interpolate(min: Double, max: Double) -> Double {
        min + (max - min) * normalized
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }

    private static func formatMbps(_ bitsPerSecond: Int) -> String {
        let mbps = Double(bitsPerSecond) / 1_000_000.0
        return String(format: "%.1f Mbps", mbps)
    }
}

nonisolated struct StreamQualityMessage: Codable, Sendable {
    var quality: Double
    var targetBitrate: Int
    var targetFPS: Int
    var jpegQuality: Double
}
