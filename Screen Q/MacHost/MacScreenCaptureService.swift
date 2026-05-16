//
//  MacScreenCaptureService.swift
//  Screen Q
//
//  ScreenCaptureKit-based capture service. We start with a JPEG fallback
//  pipeline so the vertical slice is testable without VideoToolbox; the
//  encoder boundary is `FrameEncoder` so VTCompressionSession can replace
//  JPEG with H.264 in a single point of change.
//

#if os(macOS)
import Foundation
import AppKit
import ScreenCaptureKit
import CoreImage
import CoreVideo
import CoreMedia
import VideoToolbox
import QuartzCore
import ImageIO
import Combine

// MARK: - Encoder protocol

/// Encodes a CMSampleBuffer into a compressed payload + metadata. JPEG is
/// the default; an H.264 implementation can drop in here later without
/// touching the capture loop.
nonisolated protocol FrameEncoder: AnyObject, Sendable {
    var encoding: VideoEncoding { get }
    func encode(_ sample: CMSampleBuffer, sequence: UInt64, displayID: CGDirectDisplayID) -> (VideoFrameMeta, Data)?
    func reset()
}

nonisolated private func screenQCaptureWallClockTimestamp(forHostTimestamp hostTimestamp: TimeInterval) -> TimeInterval {
    let nowWall = Date().timeIntervalSince1970
    let nowHost = CACurrentMediaTime()
    guard hostTimestamp.isFinite, hostTimestamp > 0, nowHost.isFinite else {
        return nowWall
    }
    let age = nowHost - hostTimestamp
    guard age.isFinite, age >= 0, age < 60 else {
        return nowWall
    }
    return nowWall - age
}

/// Settings driving capture and encoding.
struct CaptureSettings: Equatable, Sendable {
    var fps: Int = 30
    var jpegQuality: CGFloat = 0.6
    var scale: CGFloat = 1.0
    var showCursor: Bool = true
    var preferH264: Bool = true
    var h264Bitrate: Int = 8_000_000  // 8 Mbps
    var captureAudio: Bool = false
}

/// Mutable state shared between the main actor (which configures capture)
/// and the SCStream output callback queue. `nonisolated` so it doesn't
/// inherit MainActor isolation from the surrounding class.
/// Throttled CGImage publisher for the host-side "viewers see this" preview
/// tile. Lives nonisolated so SCStream delegate methods can feed it directly
/// from their background queue; emits CGImages back to the owning service
/// (which then publishes on the MainActor for SwiftUI).
nonisolated final class MacCapturePreviewBridge: @unchecked Sendable {

    private let lock = NSLock()
    private var lastEmittedAt: Date = .distantPast
    private var pendingEmit = false
    private let interval: TimeInterval
    private let targetWidth: CGFloat
    private let ciContext: CIContext

    /// Set by the owning service on MainActor; called whenever a new
    /// throttled preview frame is ready. Closure is invoked on a background
    /// queue — implementer should hop to MainActor before touching UI state.
    var onEmit: (@Sendable (CGImage) -> Void)?

    init(interval: TimeInterval = 0.5, targetWidth: CGFloat = 720) {
        self.interval = interval
        self.targetWidth = targetWidth
        self.ciContext = CIContext(options: nil)
    }

    /// Feed a sample buffer. The bridge throttles itself and only converts /
    /// emits at the configured interval.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let now = Date()
        let dt = now.timeIntervalSince(lastEmittedAt)
        if pendingEmit || dt < interval {
            lock.unlock()
            return
        }
        lastEmittedAt = now
        pendingEmit = true
        let callback = onEmit
        lock.unlock()

        guard let callback else {
            clearPending()
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            clearPending()
            return
        }
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else {
            clearPending()
            return
        }
        let scale = min(1.0, targetWidth / max(1, extent.width))
        let scaled = scale < 1.0
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            clearPending()
            return
        }
        callback(cgImage)
        clearPending()
    }

    /// Force the next ingest to emit immediately (e.g. after capture restart).
    func reset() {
        lock.lock()
        lastEmittedAt = .distantPast
        pendingEmit = false
        lock.unlock()
    }

    private func clearPending() {
        lock.lock()
        pendingEmit = false
        lock.unlock()
    }
}

nonisolated final class MacCaptureCrossState: @unchecked Sendable {
    var sequence: UInt64 = 0
    var displayID: CGDirectDisplayID = 0
    private let encoderLock = NSLock()
    private let sinkLock = NSLock()
    private let regionLock = NSLock()
    private var activeEncoder: FrameEncoder = H264FrameEncoder()
    private var encoderFailureCount = 0
    private var encoderFallbackScheduled = false
    private var frameSinks: [UUID: @Sendable (VideoFrameMeta, Data) -> Void] = [:]
    private var frameRegion: VideoFrameRegion?

    var encoder: FrameEncoder {
        get {
            encoderLock.lock()
            defer { encoderLock.unlock() }
            return activeEncoder
        }
        set {
            encoderLock.lock()
            activeEncoder = newValue
            encoderFailureCount = 0
            encoderFallbackScheduled = false
            encoderLock.unlock()
        }
    }

    func recordEncoderSuccess() {
        encoderLock.lock()
        encoderFailureCount = 0
        encoderLock.unlock()
    }

    func shouldFallbackAfterEncoderFailure(threshold: Int) -> Bool {
        encoderLock.lock()
        defer { encoderLock.unlock() }
        encoderFailureCount += 1
        guard encoderFailureCount >= threshold, !encoderFallbackScheduled else {
            return false
        }
        encoderFallbackScheduled = true
        return true
    }

    func resetEncoderFailures() {
        encoderLock.lock()
        encoderFailureCount = 0
        encoderFallbackScheduled = false
        encoderLock.unlock()
    }

    func addFrameSink(id: UUID, _ sink: @escaping @Sendable (VideoFrameMeta, Data) -> Void) {
        sinkLock.lock()
        frameSinks[id] = sink
        sinkLock.unlock()
    }

    func removeFrameSink(id: UUID) {
        sinkLock.lock()
        frameSinks.removeValue(forKey: id)
        sinkLock.unlock()
    }

    func removeAllFrameSinks() {
        sinkLock.lock()
        frameSinks.removeAll()
        sinkLock.unlock()
    }

    func setFrameRegion(_ region: VideoFrameRegion?) {
        regionLock.lock()
        frameRegion = region
        regionLock.unlock()
    }

    func activeFrameRegion() -> VideoFrameRegion? {
        regionLock.lock()
        let region = frameRegion
        regionLock.unlock()
        return region
    }

    func emitFrame(_ meta: VideoFrameMeta, _ payload: Data) {
        sinkLock.lock()
        let sinks = Array(frameSinks.values)
        sinkLock.unlock()
        for sink in sinks {
            sink(meta, payload)
        }
    }
}

@available(macOS 12.3, *)
private struct AllDisplaysCaptureEntry: Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let streamPixelWidth: Int
}

@available(macOS 12.3, *)
nonisolated final class AllDisplaysFrameCompositor: @unchecked Sendable {
    private let entries: [AllDisplaysCaptureEntry]
    private let unionFrame: CGRect
    private let targetScale: CGFloat
    private let displayID: CGDirectDisplayID
    private let quality: CGFloat
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let colorspace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var latestFrames: [CGDirectDisplayID: CIImage] = [:]

    let outputWidth: Int
    let outputHeight: Int

    fileprivate init(entries: [AllDisplaysCaptureEntry], quality: CGFloat, displayID: CGDirectDisplayID) {
        self.entries = entries
        self.quality = max(0.1, min(1.0, quality))
        self.displayID = displayID
        self.unionFrame = entries.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        self.targetScale = entries
            .map { CGFloat($0.streamPixelWidth) / max(1, $0.frame.width) }
            .max() ?? 1
        self.outputWidth = max(160, Int((unionFrame.width * targetScale).rounded(.up)))
        self.outputHeight = max(120, Int((unionFrame.height * targetScale).rounded(.up)))
    }

    func ingest(_ sampleBuffer: CMSampleBuffer, displayID: CGDirectDisplayID) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        lock.lock()
        latestFrames[displayID] = image
        lock.unlock()
    }

    func makeFrame(sequence: UInt64) -> (VideoFrameMeta, Data)? {
        lock.lock()
        let frames = latestFrames
        lock.unlock()
        guard !frames.isEmpty else { return nil }

        let targetRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        var composite = CIImage(color: .black).cropped(to: targetRect)

        for entry in entries {
            guard let source = frames[entry.displayID] else { continue }
            let destinationWidth = entry.frame.width * targetScale
            let destinationHeight = entry.frame.height * targetScale
            let scaleX = destinationWidth / max(1, source.extent.width)
            let scaleY = destinationHeight / max(1, source.extent.height)
            let x = (entry.frame.minX - unionFrame.minX) * targetScale
            let yFromTop = (entry.frame.minY - unionFrame.minY) * targetScale
            let y = CGFloat(outputHeight) - yFromTop - destinationHeight
            let placed = source
                .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .transformed(by: CGAffineTransform(translationX: x, y: y))
            composite = placed.composited(over: composite)
        }

        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        guard let data = context.jpegRepresentation(of: composite.cropped(to: targetRect), colorSpace: colorspace, options: options) else {
            return nil
        }
        let captureTimestamp = CACurrentMediaTime()
        let meta = VideoFrameMeta(
            sequence: sequence,
            captureTimestamp: captureTimestamp,
            pixelWidth: outputWidth,
            pixelHeight: outputHeight,
            displayID: displayID,
            encoding: .jpeg,
            isKeyFrame: true,
            payloadSize: data.count,
            captureWallClockTimestamp: screenQCaptureWallClockTimestamp(forHostTimestamp: captureTimestamp)
        )
        return (meta, data)
    }
}

@available(macOS 12.3, *)
nonisolated final class AllDisplaysSCStreamOutput: NSObject, SCStreamOutput {
    private let displayID: CGDirectDisplayID
    private let onFrame: @Sendable (CGDirectDisplayID, CMSampleBuffer) -> Void

    init(displayID: CGDirectDisplayID, onFrame: @escaping @Sendable (CGDirectDisplayID, CMSampleBuffer) -> Void) {
        self.displayID = displayID
        self.onFrame = onFrame
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attach = attachments.first,
           let statusRaw = attach[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }
        onFrame(displayID, sampleBuffer)
    }
}

@MainActor
@available(macOS 12.3, *)
private final class MacCapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate {
    private let subscriberID: UUID
    private let captureTargets: CaptureTargetSelectionService
    private let permissions: MacPermissionsService
    private let outputQueue: DispatchQueue

    nonisolated let xstate = MacCaptureCrossState()
    nonisolated let previewBridge: MacCapturePreviewBridge

    private var stream: SCStream?
    private var allDisplayStreams: [SCStream] = []
    private var allDisplayOutputs: [AllDisplaysSCStreamOutput] = []
    private var allDisplayCompositeTimer: DispatchSourceTimer?
    private var activeFormat: VideoFormat?
    private var activeStreamConfiguration: ActiveStreamConfiguration?
    private var activeDisplayGeometry: ActiveDisplayGeometry?
    private var currentStreamProfile = StreamQualityPreference().nativeProfile
    private var viewerViewport: ViewerViewportMessage?
    private var pendingViewportConfigurationTask: Task<Void, Never>?
    private var isApplyingActiveStreamConfiguration = false
    private var activeStreamConfigurationUpdateQueued = false
    private var isCapturing = false
    private var isAllDisplaysCaptureActive = false
    private var targetID: String?
    private var settings: CaptureSettings
    private var formatSink: ((VideoFormat) async -> Void)?
    private var frameSink: (@Sendable (VideoFrameMeta, Data) -> Void)?

    private struct ActiveDisplayGeometry {
        let displayID: CGDirectDisplayID
        let pixelWidth: Int
        let pixelHeight: Int
        let pointWidth: Double
        let pointHeight: Double
        let scaleFactor: Double
        let sourceRect: CGRect?
    }

    private struct CapturePlan {
        let outputWidth: Int
        let outputHeight: Int
        let sourceRect: CGRect?
        let region: VideoFrameRegion?
    }

    private struct ActiveStreamConfiguration: Equatable {
        let outputWidth: Int
        let outputHeight: Int
        let sourceRect: CGRect?
        let fps: Int
        let encoding: VideoEncoding
    }

    init(
        subscriberID: UUID,
        captureTargets: CaptureTargetSelectionService,
        permissions: MacPermissionsService,
        defaultSettings: CaptureSettings,
        previewBridge: MacCapturePreviewBridge
    ) {
        self.subscriberID = subscriberID
        self.captureTargets = captureTargets
        self.permissions = permissions
        self.settings = defaultSettings
        self.previewBridge = previewBridge
        self.outputQueue = DispatchQueue(label: "com.screenq.capture-output.\(subscriberID.uuidString)", qos: .userInitiated)
        super.init()
        settings.scale = effectiveCaptureScale(for: currentStreamProfile)
        settings.preferH264 = currentStreamProfile.codecPreference != .jpeg
    }

    var activeTargetID: String? {
        targetID ?? captureTargets.activeTargetID()
    }

    var activeDisplayID: CGDirectDisplayID? {
        captureTargets.displayID(forTargetID: activeTargetID)
    }

    var activeInputConstraint: CaptureInputConstraint? {
        captureTargets.inputConstraint(forTargetID: activeTargetID)
    }

    func start(
        targetID requestedTargetID: String?,
        onFormat: @escaping (VideoFormat) async -> Void,
        onFrame: @escaping @Sendable (VideoFrameMeta, Data) -> Void
    ) async throws {
        formatSink = onFormat
        frameSink = onFrame

        if isCapturing {
            if let activeFormat {
                await onFormat(activeFormat)
            }
            xstate.addFrameSink(id: subscriberID, onFrame)
            requestKeyFrame()
            Logger.shared.info("ScreenCaptureKit pipeline already running for subscriber \(subscriberID)")
            return
        }

        permissions.refresh()
        guard permissions.screenRecordingGranted else {
            throw NSError(
                domain: "ScreenQ.Capture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission required"]
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        captureTargets.refresh(using: content)

        let resolvedTargetID = requestedTargetID ?? captureTargets.activeTargetID()
        targetID = resolvedTargetID

        if captureTargets.isAllDisplaysTarget(resolvedTargetID) {
            try await startAllDisplaysCapture(content: content, onFormat: onFormat, onFrame: onFrame)
            return
        }

        let target = try captureTargets.resolvedTarget(id: resolvedTargetID, in: content)
        targetID = target.id

        settings.scale = effectiveCaptureScale(for: currentStreamProfile)
        settings.preferH264 = currentStreamProfile.codecPreference != .jpeg

        let geometry = ActiveDisplayGeometry(
            displayID: target.displayID,
            pixelWidth: target.pixelWidth,
            pixelHeight: target.pixelHeight,
            pointWidth: target.pointWidth,
            pointHeight: target.pointHeight,
            scaleFactor: target.scaleFactor,
            sourceRect: target.sourceRect
        )
        let plan = capturePlan(for: geometry)
        let config = makeStreamConfiguration(for: plan)
        configureEncoder(for: config)
        let format = videoFormat(for: geometry)

        let stream = SCStream(filter: target.filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        xstate.removeAllFrameSinks()
        xstate.displayID = target.displayID
        xstate.setFrameRegion(plan.region)
        xstate.encoder.reset()
        xstate.sequence = 0

        try await stream.startCapture()
        self.stream = stream
        self.isCapturing = true
        self.isAllDisplaysCaptureActive = false
        self.activeDisplayGeometry = geometry
        self.activeStreamConfiguration = activeConfiguration(for: plan)
        self.activeFormat = format
        await updateActiveStreamConfigurationIfNeeded()

        await onFormat(activeFormat ?? format)
        xstate.addFrameSink(id: subscriberID, onFrame)
        requestKeyFrame()
        Logger.shared.info("ScreenCaptureKit pipeline started for subscriber \(subscriberID): \(config.width)x\(config.height) @ \(settings.fps)fps target=\(target.id)")
    }

    func restart(
        targetID requestedTargetID: String?,
        onFormat: @escaping (VideoFormat) async -> Void,
        onFrame: @escaping @Sendable (VideoFrameMeta, Data) -> Void
    ) async throws {
        await stop()
        try await start(targetID: requestedTargetID, onFormat: onFormat, onFrame: onFrame)
    }

    func applyStreamQuality(_ message: StreamQualityMessage) {
        let profile = message.profile
        currentStreamProfile = profile
        settings.jpegQuality = CGFloat(max(0.1, min(1.0, message.jpegQuality)))
        settings.h264Bitrate = max(500_000, min(30_000_000, message.targetBitrate))
        settings.fps = max(5, min(60, message.targetFPS))
        if !profile.adaptive || !profile.usesViewportAwareDetail {
            viewerViewport = nil
        }
        settings.scale = effectiveCaptureScale(for: profile)
        settings.preferH264 = profile.codecPreference != .jpeg
        if let h264 = xstate.encoder as? H264FrameEncoder {
            h264.updateBitrate(settings.h264Bitrate)
            h264.updateFrameRate(settings.fps)
            h264.updateKeyFrameInterval(seconds: profile.keyframeInterval)
            h264.forceKeyFrame()
        } else if let jpeg = xstate.encoder as? JPEGFrameEncoder {
            jpeg.setQuality(settings.jpegQuality)
        }
        scheduleActiveStreamConfigurationUpdate()
    }

    func applyViewerViewport(_ viewport: ViewerViewportMessage, adaptiveEnabled: Bool) {
        if adaptiveEnabled && currentStreamProfile.adaptive && currentStreamProfile.usesViewportAwareDetail {
            if let current = viewerViewport,
               viewport.timestamp.isFinite,
               current.timestamp.isFinite,
               viewport.timestamp < current.timestamp {
                return
            }
            viewerViewport = viewport
        } else {
            viewerViewport = nil
        }
        scheduleActiveStreamConfigurationUpdate()
    }

    func updateAdaptiveBitrate(bitrate: Int, fps: Int) {
        guard currentStreamProfile.adaptive else { return }
        if let h264 = xstate.encoder as? H264FrameEncoder {
            h264.updateBitrate(bitrate)
            h264.updateFrameRate(fps)
        }
    }

    func stop() async {
        pendingViewportConfigurationTask?.cancel()
        pendingViewportConfigurationTask = nil
        activeStreamConfigurationUpdateQueued = false
        isApplyingActiveStreamConfiguration = false
        allDisplayCompositeTimer?.cancel()
        allDisplayCompositeTimer = nil
        for stream in allDisplayStreams {
            do {
                try await stream.stopCapture()
            } catch {
                Logger.shared.warn("stopCapture all-displays error: \(error.localizedDescription)")
            }
        }
        allDisplayStreams.removeAll()
        allDisplayOutputs.removeAll()

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                Logger.shared.warn("stopCapture error: \(error.localizedDescription)")
            }
        }
        stream = nil
        activeFormat = nil
        activeStreamConfiguration = nil
        activeDisplayGeometry = nil
        viewerViewport = nil
        formatSink = nil
        frameSink = nil
        isAllDisplaysCaptureActive = false
        xstate.removeAllFrameSinks()
        xstate.setFrameRegion(nil)
        xstate.encoder.reset()
        isCapturing = false
        Logger.shared.info("ScreenCaptureKit pipeline stopped for subscriber \(subscriberID)")
    }

    private func requestKeyFrame() {
        if let h264 = xstate.encoder as? H264FrameEncoder {
            h264.forceKeyFrame()
        }
    }

    private func captureScale(for policy: StreamScalePolicy) -> CGFloat {
        switch policy {
        case .native:
            return 1.0
        case .viewerMatched:
            return 0.85
        case .balancedDownscale:
            return 0.7
        case .bandwidthSaver:
            return 0.5
        }
    }

    private func effectiveCaptureScale(for profile: StreamProfile) -> CGFloat {
        captureScale(for: profile.scalePolicy)
    }

    private func fullCanvasPixelSize(for geometry: ActiveDisplayGeometry) -> (width: Int, height: Int) {
        let scale = max(0.25, min(1.0, effectiveCaptureScale(for: currentStreamProfile)))
        return (
            max(160, Int((Double(geometry.pixelWidth) * Double(scale)).rounded())),
            max(120, Int((Double(geometry.pixelHeight) * Double(scale)).rounded()))
        )
    }

    private func capturePlan(for geometry: ActiveDisplayGeometry) -> CapturePlan {
        let fullSize = fullCanvasPixelSize(for: geometry)
        guard let viewport = viewerViewport,
              currentStreamProfile.adaptive,
              currentStreamProfile.usesViewportAwareDetail,
              viewport.adaptiveEnabled,
              viewport.zoomScale >= 1.08,
              viewport.visibleRect.width < 0.98 || viewport.visibleRect.height < 0.98 else {
            return CapturePlan(
                outputWidth: fullSize.width,
                outputHeight: fullSize.height,
                sourceRect: geometry.sourceRect,
                region: nil
            )
        }

        let baseOrigin = geometry.sourceRect?.origin ?? .zero
        let paddedRect = paddedViewportRect(viewport.visibleRect)
        let sourceRect = CGRect(
            x: baseOrigin.x + paddedRect.x * geometry.pointWidth,
            y: baseOrigin.y + paddedRect.y * geometry.pointHeight,
            width: max(1, paddedRect.width * geometry.pointWidth),
            height: max(1, paddedRect.height * geometry.pointHeight)
        )

        let region = VideoFrameRegion(
            x: Int((paddedRect.x * Double(fullSize.width)).rounded(.down)),
            y: Int((paddedRect.y * Double(fullSize.height)).rounded(.down)),
            width: max(1, Int((paddedRect.width * Double(fullSize.width)).rounded(.up))),
            height: max(1, Int((paddedRect.height * Double(fullSize.height)).rounded(.up))),
            fullWidth: fullSize.width,
            fullHeight: fullSize.height
        )

        let visibleWidth = max(0.01, viewport.visibleRect.width)
        let visibleHeight = max(0.01, viewport.visibleRect.height)
        let paddedCanvasWidth = Double(max(1, viewport.canvasPixelWidth)) * paddedRect.width / visibleWidth
        let paddedCanvasHeight = Double(max(1, viewport.canvasPixelHeight)) * paddedRect.height / visibleHeight
        let nativeWidth = Double(geometry.pixelWidth) * paddedRect.width
        let nativeHeight = Double(geometry.pixelHeight) * paddedRect.height
        var outputWidth = max(160, Int(min(nativeWidth, paddedCanvasWidth * 1.15).rounded(.up)))
        var outputHeight = max(120, Int(min(nativeHeight, paddedCanvasHeight * 1.15).rounded(.up)))

        let maxPixels = 5_000_000.0
        let pixelCount = Double(outputWidth * outputHeight)
        if pixelCount > maxPixels {
            let ratio = sqrt(maxPixels / pixelCount)
            outputWidth = max(160, Int((Double(outputWidth) * ratio).rounded(.down)))
            outputHeight = max(120, Int((Double(outputHeight) * ratio).rounded(.down)))
        }

        return CapturePlan(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            sourceRect: sourceRect,
            region: region
        )
    }

    private func paddedViewportRect(_ rect: NormalisedRect) -> NormalisedRect {
        let padX = max(0.025, rect.width * 0.18)
        let padY = max(0.025, rect.height * 0.18)
        return NormalisedRect(
            x: rect.x - padX,
            y: rect.y - padY,
            width: rect.width + padX * 2,
            height: rect.height + padY * 2
        )
    }

    private func makeStreamConfiguration(for plan: CapturePlan) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = plan.outputWidth
        config.height = plan.outputHeight
        if let sourceRect = plan.sourceRect {
            config.sourceRect = sourceRect
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.fps)))
        config.queueDepth = 2
        config.showsCursor = settings.showCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 13.0, *) {
            config.capturesAudio = settings.captureAudio
        }
        return config
    }

    private func activeConfiguration(for plan: CapturePlan) -> ActiveStreamConfiguration {
        ActiveStreamConfiguration(
            outputWidth: plan.outputWidth,
            outputHeight: plan.outputHeight,
            sourceRect: plan.sourceRect,
            fps: settings.fps,
            encoding: desiredEncoding
        )
    }

    private var desiredEncoding: VideoEncoding {
        settings.preferH264 ? .h264 : .jpeg
    }

    private func configureEncoder(for config: SCStreamConfiguration) {
        if settings.preferH264 {
            let h264 = (xstate.encoder as? H264FrameEncoder) ?? H264FrameEncoder()
            h264.configure(
                width: config.width,
                height: config.height,
                fps: settings.fps,
                bitrate: settings.h264Bitrate
            )
            xstate.encoder = h264
        } else {
            let jpeg = (xstate.encoder as? JPEGFrameEncoder) ?? JPEGFrameEncoder()
            jpeg.setQuality(settings.jpegQuality)
            xstate.encoder = jpeg
        }
    }

    private func videoFormat(for geometry: ActiveDisplayGeometry) -> VideoFormat {
        let fullSize = fullCanvasPixelSize(for: geometry)
        return VideoFormat(
            pixelWidth: fullSize.width,
            pixelHeight: fullSize.height,
            pointWidth: geometry.pointWidth,
            pointHeight: geometry.pointHeight,
            displayID: geometry.displayID,
            scaleFactor: geometry.scaleFactor,
            encoding: desiredEncoding,
            targetFPS: settings.fps
        )
    }

    private func scheduleActiveStreamConfigurationUpdate() {
        guard isCapturing, !isAllDisplaysCaptureActive else { return }
        pendingViewportConfigurationTask?.cancel()
        let debounceNanoseconds: UInt64 = viewerViewport == nil ? 0 : 120_000_000
        pendingViewportConfigurationTask = Task { @MainActor [weak self] in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.runActiveStreamConfigurationUpdateLoop()
        }
    }

    private func runActiveStreamConfigurationUpdateLoop() async {
        guard isCapturing, !isAllDisplaysCaptureActive else { return }
        if isApplyingActiveStreamConfiguration {
            activeStreamConfigurationUpdateQueued = true
            return
        }

        isApplyingActiveStreamConfiguration = true
        defer { isApplyingActiveStreamConfiguration = false }

        repeat {
            activeStreamConfigurationUpdateQueued = false
            await updateActiveStreamConfigurationIfNeeded()
        } while activeStreamConfigurationUpdateQueued && isCapturing && !isAllDisplaysCaptureActive
    }

    private func fallbackToJPEGAfterEncoderFailures() {
        guard isCapturing, !isAllDisplaysCaptureActive, settings.preferH264 else { return }
        settings.preferH264 = false
        currentStreamProfile.codecPreference = .jpeg
        let jpeg = JPEGFrameEncoder()
        jpeg.setQuality(settings.jpegQuality)
        xstate.encoder = jpeg
        xstate.resetEncoderFailures()
        Logger.shared.warn("H.264 encoder failed repeatedly; falling back to JPEG for subscriber \(subscriberID)")
        scheduleActiveStreamConfigurationUpdate()
    }

    private func updateActiveStreamConfigurationIfNeeded() async {
        guard isCapturing,
              !isAllDisplaysCaptureActive,
              let stream,
              let geometry = activeDisplayGeometry else {
            return
        }

        let plan = capturePlan(for: geometry)
        let config = makeStreamConfiguration(for: plan)
        let nextConfiguration = activeConfiguration(for: plan)
        let nextFormat = videoFormat(for: geometry)
        let needsStreamUpdate = activeStreamConfiguration != nextConfiguration
        let needsEncoderUpdate = activeStreamConfiguration?.encoding != nextConfiguration.encoding ||
            activeStreamConfiguration?.outputWidth != nextConfiguration.outputWidth ||
            activeStreamConfiguration?.outputHeight != nextConfiguration.outputHeight
        let needsFormatUpdate = activeFormat != nextFormat
        if !needsStreamUpdate && !needsEncoderUpdate && !needsFormatUpdate {
            xstate.setFrameRegion(plan.region)
            return
        }

        do {
            if needsStreamUpdate {
                try await stream.updateConfiguration(config)
            }
            if needsEncoderUpdate {
                configureEncoder(for: config)
            }
            activeStreamConfiguration = nextConfiguration
            xstate.setFrameRegion(plan.region)
            if needsFormatUpdate {
                activeFormat = nextFormat
                if let formatSink {
                    await formatSink(nextFormat)
                }
            }
            requestKeyFrame()
            Logger.shared.info("ScreenCaptureKit pipeline updated for subscriber \(subscriberID): \(config.width)x\(config.height) @ \(settings.fps)fps\(plan.region == nil ? "" : " viewport")")
        } catch {
            Logger.shared.warn("ScreenCaptureKit updateConfiguration failed for subscriber \(subscriberID): \(error.localizedDescription)")
        }
    }

    private func startAllDisplaysCapture(
        content: SCShareableContent,
        onFormat: @escaping (VideoFormat) async -> Void,
        onFrame: @escaping @Sendable (VideoFrameMeta, Data) -> Void
    ) async throws {
        let displays = content.displays
        guard displays.count > 1 else {
            throw NSError(
                domain: "ScreenQ.Capture", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "All Displays requires more than one shareable display"]
            )
        }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }
        let scale = max(0.25, min(1.0, settings.scale))
        let fps = max(1, settings.fps)
        let allDisplaysID = DisplaySelectionService.allDisplaysID

        let entries = displays.map { display in
            AllDisplaysCaptureEntry(
                displayID: display.displayID,
                frame: display.frame,
                streamPixelWidth: max(160, Int(Double(display.width) * scale))
            )
        }
        let compositor = AllDisplaysFrameCompositor(
            entries: entries,
            quality: settings.jpegQuality,
            displayID: allDisplaysID
        )

        var streams: [SCStream] = []
        var outputs: [AllDisplaysSCStreamOutput] = []
        for display in displays {
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = max(160, Int(Double(display.width) * scale))
            config.height = max(120, Int(Double(display.height) * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 2
            config.showsCursor = settings.showCursor
            config.pixelFormat = kCVPixelFormatType_32BGRA
            if #available(macOS 13.0, *) {
                config.capturesAudio = false
            }

            let output = AllDisplaysSCStreamOutput(displayID: display.displayID) { displayID, sampleBuffer in
                compositor.ingest(sampleBuffer, displayID: displayID)
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
            streams.append(stream)
            outputs.append(output)
        }

        do {
            for stream in streams {
                try await stream.startCapture()
            }
        } catch {
            for stream in streams {
                try? await stream.stopCapture()
            }
            throw error
        }

        let jpeg = JPEGFrameEncoder()
        jpeg.setQuality(settings.jpegQuality)
        xstate.encoder = jpeg
        xstate.removeAllFrameSinks()
        xstate.displayID = allDisplaysID
        xstate.setFrameRegion(nil)
        xstate.encoder.reset()
        xstate.sequence = 0

        let format = VideoFormat(
            pixelWidth: compositor.outputWidth,
            pixelHeight: compositor.outputHeight,
            pointWidth: Double(compositor.outputWidth),
            pointHeight: Double(compositor.outputHeight),
            displayID: allDisplaysID,
            scaleFactor: 1.0,
            encoding: .jpeg,
            targetFPS: fps
        )

        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(Int(1000 / fps)),
            repeating: .milliseconds(Int(1000 / fps)),
            leeway: .milliseconds(4)
        )
        timer.setEventHandler { [xstate, compositor] in
            xstate.sequence &+= 1
            let sequence = xstate.sequence
            guard let result = compositor.makeFrame(sequence: sequence) else { return }
            xstate.emitFrame(result.0, result.1)
        }

        allDisplayStreams = streams
        allDisplayOutputs = outputs
        allDisplayCompositeTimer = timer
        isCapturing = true
        isAllDisplaysCaptureActive = true
        activeDisplayGeometry = nil
        activeStreamConfiguration = nil
        activeFormat = format
        targetID = CaptureTargetSelectionService.allDisplaysTargetID

        await onFormat(format)
        xstate.addFrameSink(id: subscriberID, onFrame)
        timer.resume()
        Logger.shared.info("ScreenCaptureKit all-displays pipeline started for subscriber \(subscriberID): \(format.pixelWidth)x\(format.pixelHeight) @ \(fps)fps")
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.shared.error("SCStream stopped for subscriber \(subscriberID): \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            self?.isCapturing = false
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attach = attachments.first,
           let statusRaw = attach[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        previewBridge.ingest(sampleBuffer)

        let state = xstate
        state.sequence &+= 1
        let seq = state.sequence
        let did = state.displayID
        let encoder = state.encoder
        guard let result = encoder.encode(sampleBuffer, sequence: seq, displayID: did) else {
            if encoder is H264FrameEncoder, state.shouldFallbackAfterEncoderFailure(threshold: 12) {
                Task { @MainActor [weak self] in
                    self?.fallbackToJPEGAfterEncoderFailures()
                }
            }
            return
        }
        state.recordEncoderSuccess()
        let meta = result.0.withRegion(state.activeFrameRegion())
        state.emitFrame(meta, result.1)
    }
}

@MainActor
@available(macOS 12.3, *)
final class MacScreenCaptureService: NSObject, ObservableObject {

    @Published private(set) var isCapturing: Bool = false
    @Published var settings = CaptureSettings()

    /// Throttled (~2 fps) downscaled CGImage of the current capture, used by
    /// `HostMacView`'s "Viewers see this" preview tile. `nil` when not
    /// actively sharing or before the first frame has been encoded.
    @Published private(set) var previewCGImage: CGImage?

    private let captureTargets: CaptureTargetSelectionService
    private let permissions: MacPermissionsService
    private var pipelines: [UUID: MacCapturePipeline] = [:]
    private let previewBridge = MacCapturePreviewBridge()

    init(
        displaySelection: DisplaySelectionService,
        captureTargets: CaptureTargetSelectionService,
        permissions: MacPermissionsService
    ) {
        self.captureTargets = captureTargets
        self.permissions = permissions
        super.init()
        previewBridge.onEmit = { [weak self] cgImage in
            Task { @MainActor [weak self] in
                self?.previewCGImage = cgImage
            }
        }
    }

    func start(
        subscriberID: UUID,
        targetID: String? = nil,
        onFormat: @escaping (VideoFormat) async -> Void,
        onFrame: @escaping @Sendable (VideoFrameMeta, Data) -> Void
    ) async throws {
        let pipeline = pipeline(for: subscriberID)
        try await pipeline.start(targetID: targetID, onFormat: onFormat, onFrame: onFrame)
        updateCaptureState()
    }

    func restartSubscriber(
        _ subscriberID: UUID,
        targetID: String?,
        onFormat: @escaping (VideoFormat) async -> Void,
        onFrame: @escaping @Sendable (VideoFrameMeta, Data) -> Void
    ) async throws {
        let pipeline = pipeline(for: subscriberID)
        try await pipeline.restart(targetID: targetID, onFormat: onFormat, onFrame: onFrame)
        updateCaptureState()
    }

    func removeSubscriber(_ id: UUID) async {
        guard let pipeline = pipelines.removeValue(forKey: id) else { return }
        await pipeline.stop()
        updateCaptureState()
    }

    func stop() async {
        let activePipelines = Array(pipelines.values)
        pipelines.removeAll()
        for pipeline in activePipelines {
            await pipeline.stop()
        }
        updateCaptureState()
    }

    func applyStreamQuality(_ preference: StreamQualityPreference) {
        applyStreamQuality(preference.nativeMessage)
    }

    func applyStreamQuality(_ message: StreamQualityMessage) {
        settings.jpegQuality = CGFloat(max(0.1, min(1.0, message.jpegQuality)))
        settings.h264Bitrate = max(500_000, min(30_000_000, message.targetBitrate))
        settings.fps = max(5, min(60, message.targetFPS))
        settings.scale = captureScale(for: message.profile.scalePolicy)
        settings.preferH264 = message.profile.codecPreference != .jpeg
        pipelines.values.forEach { $0.applyStreamQuality(message) }
    }

    func applyStreamQuality(for subscriberID: UUID, _ message: StreamQualityMessage) {
        settings.jpegQuality = CGFloat(max(0.1, min(1.0, message.jpegQuality)))
        settings.h264Bitrate = max(500_000, min(30_000_000, message.targetBitrate))
        settings.fps = max(5, min(60, message.targetFPS))
        settings.scale = captureScale(for: message.profile.scalePolicy)
        settings.preferH264 = message.profile.codecPreference != .jpeg
        pipelines[subscriberID]?.applyStreamQuality(message)
    }

    func applyViewerViewport(_ viewport: ViewerViewportMessage, adaptiveEnabled: Bool) {
        pipelines.values.forEach {
            $0.applyViewerViewport(viewport, adaptiveEnabled: adaptiveEnabled)
        }
    }

    func applyViewerViewport(for subscriberID: UUID, _ viewport: ViewerViewportMessage, adaptiveEnabled: Bool) {
        pipelines[subscriberID]?.applyViewerViewport(viewport, adaptiveEnabled: adaptiveEnabled)
    }

    func updateAdaptiveBitrate(bitrate: Int, fps: Int) {
        pipelines.values.forEach {
            $0.updateAdaptiveBitrate(bitrate: bitrate, fps: fps)
        }
    }

    func updateAdaptiveBitrate(for subscriberID: UUID, bitrate: Int, fps: Int) {
        pipelines[subscriberID]?.updateAdaptiveBitrate(bitrate: bitrate, fps: fps)
    }

    func activeTargetID(for subscriberID: UUID) -> String? {
        pipelines[subscriberID]?.activeTargetID ?? captureTargets.activeTargetID()
    }

    func activeDisplayID(for subscriberID: UUID) -> CGDirectDisplayID? {
        pipelines[subscriberID]?.activeDisplayID ?? captureTargets.displayID(forTargetID: nil)
    }

    func activeInputConstraint(for subscriberID: UUID) -> CaptureInputConstraint? {
        pipelines[subscriberID]?.activeInputConstraint ?? captureTargets.inputConstraint(forTargetID: nil)
    }

    private func pipeline(for subscriberID: UUID) -> MacCapturePipeline {
        if let pipeline = pipelines[subscriberID] {
            return pipeline
        }
        let pipeline = MacCapturePipeline(
            subscriberID: subscriberID,
            captureTargets: captureTargets,
            permissions: permissions,
            defaultSettings: settings,
            previewBridge: previewBridge
        )
        pipelines[subscriberID] = pipeline
        return pipeline
    }

    private func updateCaptureState() {
        let nowCapturing = !pipelines.isEmpty
        isCapturing = nowCapturing
        if !nowCapturing {
            previewBridge.reset()
            previewCGImage = nil
        }
    }

    private func captureScale(for policy: StreamScalePolicy) -> CGFloat {
        switch policy {
        case .native:
            return 1.0
        case .viewerMatched:
            return 0.85
        case .balancedDownscale:
            return 0.7
        case .bandwidthSaver:
            return 0.5
        }
    }
}

// MARK: - JPEG implementation

nonisolated final class JPEGFrameEncoder: FrameEncoder, @unchecked Sendable {

    let encoding: VideoEncoding = .jpeg
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let colorspace = CGColorSpaceCreateDeviceRGB()
    private var jpegQuality: CGFloat = 0.6

    func setQuality(_ q: CGFloat) { jpegQuality = max(0.1, min(1.0, q)) }
    func reset() {}

    func encode(_ sample: CMSampleBuffer, sequence: UInt64, displayID: CGDirectDisplayID) -> (VideoFrameMeta, Data)? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = ci.extent
        let opts = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
        guard let data = context.jpegRepresentation(of: ci, colorSpace: colorspace, options: opts) else {
            return nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let timestamp = CMTimeGetSeconds(pts).isFinite ? CMTimeGetSeconds(pts) : CACurrentMediaTime()
        let meta = VideoFrameMeta(
            sequence: sequence,
            captureTimestamp: timestamp,
            pixelWidth: Int(rect.width),
            pixelHeight: Int(rect.height),
            displayID: displayID,
            encoding: .jpeg,
            isKeyFrame: true,
            payloadSize: data.count,
            captureWallClockTimestamp: screenQCaptureWallClockTimestamp(forHostTimestamp: timestamp)
        )
        return (meta, data)
    }
}
#endif
