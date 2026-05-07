//
//  StreamQualityPreference.swift
//  Screen Q
//
//  Shared viewer-side quality intent. Native Screen Q can apply most of this
//  directly; adapter protocols use the parts their current engine exposes.
//

import Foundation

nonisolated enum StreamOptimizationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case lowData
    case balanced
    case sharp
    case smooth
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lowData: return "Low Data"
        case .balanced: return "Balanced"
        case .sharp: return "Sharper"
        case .smooth: return "Smoother"
        case .custom: return "Custom"
        }
    }
}

nonisolated enum StreamScalePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case native
    case viewerMatched
    case balancedDownscale
    case bandwidthSaver

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return "Native 1:1"
        case .viewerMatched: return "Viewer Matched"
        case .balancedDownscale: return "Balanced Downscale"
        case .bandwidthSaver: return "Bandwidth Saver"
        }
    }
}

nonisolated enum StreamCodecPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case h264
    case hevc
    case jpeg

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .jpeg: return "JPEG"
        }
    }
}

nonisolated struct StreamProfile: Codable, Hashable, Sendable {
    var mode: StreamOptimizationMode
    var scalePolicy: StreamScalePolicy
    var codecPreference: StreamCodecPreference
    var maxBitrate: Int
    var targetFPS: Int
    var quality: Double
    var keyframeInterval: Double
    var adaptive: Bool
    var prefersHardwareAcceleration: Bool
    var viewportAwareDetail: Bool?

    var usesViewportAwareDetail: Bool {
        viewportAwareDetail ?? true
    }

    static func nativeDefault(quality: Double = StreamQualityPreference.defaultQuality) -> StreamProfile {
        let preference = StreamQualityPreference(quality: quality)
        return StreamProfile(
            mode: .balanced,
            scalePolicy: .viewerMatched,
            codecPreference: .automatic,
            maxBitrate: preference.nativeTargetBitrate,
            targetFPS: preference.nativeTargetFPS,
            quality: preference.jpegQuality,
            keyframeInterval: 2.0,
            adaptive: true,
            prefersHardwareAcceleration: true,
            viewportAwareDetail: true
        )
    }

    func cappedForMobileViewer() -> StreamProfile {
        var copy = self
        let explicitCustomCeiling = copy.mode == .custom
        copy.maxBitrate = min(copy.maxBitrate, explicitCustomCeiling ? 20_000_000 : 10_000_000)
        copy.targetFPS = min(copy.targetFPS, explicitCustomCeiling ? 45 : 30)
        if copy.scalePolicy == .native {
            copy.scalePolicy = .balancedDownscale
        }
        return copy
    }
}

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
        balancedInterpolate(low: 0.25, balanced: 0.68, high: 0.95)
    }

    var nativeTargetBitrate: Int {
        // Keep the default aligned with the original stable Screen Q native
        // stream: roughly 8 Mbps at 30 fps. The upper half still lets users
        // push quality, without making iOS startup decode fight an oversized
        // first keyframe by default.
        Int(balancedInterpolate(low: 1_000_000, balanced: 8_000_000, high: 20_000_000).rounded())
    }

    var nativeTargetFPS: Int {
        Int(balancedInterpolate(low: 15, balanced: 30, high: 45).rounded())
    }

    var vncTargetFPS: Int {
        Int(interpolate(min: 6, max: 24).rounded())
    }

    var rdpTargetFPS: Int {
        Int(interpolate(min: 12, max: 30).rounded())
    }

    var nativeMessage: StreamQualityMessage {
        let profile = nativeProfile
        return StreamQualityMessage(
            quality: quality,
            mode: profile.mode,
            targetBitrate: profile.maxBitrate,
            targetFPS: profile.targetFPS,
            jpegQuality: profile.quality,
            scalePolicy: profile.scalePolicy,
            codecPreference: profile.codecPreference,
            keyframeInterval: profile.keyframeInterval,
            adaptive: profile.adaptive,
            prefersHardwareAcceleration: profile.prefersHardwareAcceleration,
            viewportAwareDetail: profile.usesViewportAwareDetail
        )
    }

    var nativeProfile: StreamProfile {
        var profile = StreamProfile.nativeDefault(quality: quality)
        switch quality {
        case ..<0.48:
            profile.mode = .lowData
            profile.scalePolicy = .bandwidthSaver
        case 0.48..<0.78:
            profile.mode = .balanced
            profile.scalePolicy = .viewerMatched
        case 0.78..<0.92:
            profile.mode = .sharp
            profile.scalePolicy = .viewerMatched
        default:
            profile.mode = .smooth
            profile.scalePolicy = .viewerMatched
        }
        return profile
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

    private func balancedInterpolate(low: Double, balanced: Double, high: Double) -> Double {
        let clampedQuality = Self.clamp(quality)
        if clampedQuality <= Self.defaultQuality {
            let span = Self.defaultQuality - Self.allowedRange.lowerBound
            let t = span > 0 ? (clampedQuality - Self.allowedRange.lowerBound) / span : 0
            return low + (balanced - low) * t
        } else {
            let span = Self.allowedRange.upperBound - Self.defaultQuality
            let t = span > 0 ? (clampedQuality - Self.defaultQuality) / span : 0
            return balanced + (high - balanced) * t
        }
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
    var mode: StreamOptimizationMode? = nil
    var targetBitrate: Int
    var targetFPS: Int
    var jpegQuality: Double
    var scalePolicy: StreamScalePolicy? = nil
    var codecPreference: StreamCodecPreference? = nil
    var keyframeInterval: Double? = nil
    var adaptive: Bool? = nil
    var prefersHardwareAcceleration: Bool? = nil
    var viewportAwareDetail: Bool? = nil

    init(quality: Double, profile: StreamProfile) {
        self.quality = StreamQualityPreference(quality: quality).quality
        self.mode = profile.mode
        self.targetBitrate = profile.maxBitrate
        self.targetFPS = profile.targetFPS
        self.jpegQuality = profile.quality
        self.scalePolicy = profile.scalePolicy
        self.codecPreference = profile.codecPreference
        self.keyframeInterval = profile.keyframeInterval
        self.adaptive = profile.adaptive
        self.prefersHardwareAcceleration = profile.prefersHardwareAcceleration
        self.viewportAwareDetail = profile.usesViewportAwareDetail
    }

    init(
        quality: Double,
        mode: StreamOptimizationMode? = nil,
        targetBitrate: Int,
        targetFPS: Int,
        jpegQuality: Double,
        scalePolicy: StreamScalePolicy? = nil,
        codecPreference: StreamCodecPreference? = nil,
        keyframeInterval: Double? = nil,
        adaptive: Bool? = nil,
        prefersHardwareAcceleration: Bool? = nil,
        viewportAwareDetail: Bool? = nil
    ) {
        self.quality = StreamQualityPreference(quality: quality).quality
        self.mode = mode
        self.targetBitrate = targetBitrate
        self.targetFPS = targetFPS
        self.jpegQuality = jpegQuality
        self.scalePolicy = scalePolicy
        self.codecPreference = codecPreference
        self.keyframeInterval = keyframeInterval
        self.adaptive = adaptive
        self.prefersHardwareAcceleration = prefersHardwareAcceleration
        self.viewportAwareDetail = viewportAwareDetail
    }

    func cappedForMobileViewer() -> StreamQualityMessage {
        let explicitCustomCeiling = mode == .custom
        return StreamQualityMessage(
            quality: quality,
            mode: mode,
            targetBitrate: min(targetBitrate, explicitCustomCeiling ? 20_000_000 : 10_000_000),
            targetFPS: min(targetFPS, explicitCustomCeiling ? 45 : 30),
            jpegQuality: jpegQuality,
            scalePolicy: scalePolicy == .native ? .balancedDownscale : scalePolicy,
            codecPreference: codecPreference,
            keyframeInterval: keyframeInterval,
            adaptive: adaptive,
            prefersHardwareAcceleration: prefersHardwareAcceleration,
            viewportAwareDetail: viewportAwareDetail
        )
    }

    var profile: StreamProfile {
        StreamProfile(
            mode: mode ?? .custom,
            scalePolicy: scalePolicy ?? .viewerMatched,
            codecPreference: codecPreference ?? .automatic,
            maxBitrate: targetBitrate,
            targetFPS: targetFPS,
            quality: jpegQuality,
            keyframeInterval: keyframeInterval ?? 2.0,
            adaptive: adaptive ?? true,
            prefersHardwareAcceleration: prefersHardwareAcceleration ?? true,
            viewportAwareDetail: viewportAwareDetail ?? true
        )
    }
}
