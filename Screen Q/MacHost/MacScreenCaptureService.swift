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
nonisolated final class MacCaptureCrossState: @unchecked Sendable {
    var encoder: FrameEncoder = H264FrameEncoder()
    var sequence: UInt64 = 0
    var displayID: CGDirectDisplayID = 0
    private let sinkLock = NSLock()
    private var frameSinks: [UUID: @Sendable (VideoFrameMeta, Data) -> Void] = [:]

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
        let meta = VideoFrameMeta(
            sequence: sequence,
            captureTimestamp: CACurrentMediaTime(),
            pixelWidth: outputWidth,
            pixelHeight: outputHeight,
            displayID: displayID,
            encoding: .jpeg,
            isKeyFrame: true,
            payloadSize: data.count
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
final class MacScreenCaptureService: NSObject, ObservableObject {

    @Published private(set) var isCapturing: Bool = false
    @Published var settings = CaptureSettings()

    private let displaySelection: DisplaySelectionService
    private let permissions: MacPermissionsService
    private let outputQueue = DispatchQueue(label: "com.screenq.capture-output", qos: .userInitiated)

    // Crossed by the nonisolated SCStreamOutput callback. Held nonisolated.
    nonisolated let xstate = MacCaptureCrossState()

    private var stream: SCStream?
    private var allDisplayStreams: [SCStream] = []
    private var allDisplayOutputs: [AllDisplaysSCStreamOutput] = []
    private var allDisplayCompositeTimer: DispatchSourceTimer?
    private var activeFormat: VideoFormat?
    private var activeDisplayGeometry: ActiveDisplayGeometry?
    private var formatSinks: [UUID: (VideoFormat) async -> Void] = [:]
    private var currentStreamProfile = StreamQualityPreference().nativeProfile
    private var viewerViewportScale: CGFloat = 1.0
    private var isAllDisplaysCaptureActive = false

    private struct ActiveDisplayGeometry {
        let displayID: CGDirectDisplayID
        let pixelWidth: Int
        let pixelHeight: Int
        let pointWidth: Double
        let pointHeight: Double
        let scaleFactor: Double
    }

    init(displaySelection: DisplaySelectionService, permissions: MacPermissionsService) {
        self.displaySelection = displaySelection
        self.permissions = permissions
        super.init()
    }

    func start(
        subscriberID: UUID,
        onFormat: @escaping (VideoFormat) async -> Void,
        onFrame: @escaping @Sendable (VideoFrameMeta, Data) -> Void
    ) async throws {
        if isCapturing {
            formatSinks[subscriberID] = onFormat
            if let activeFormat {
                await onFormat(activeFormat)
            }
            xstate.addFrameSink(id: subscriberID, onFrame)
            requestKeyFrame()
            Logger.shared.info("ScreenCaptureKit already running; added/rebound frame sink")
            return
        }
        permissions.refresh()
        guard permissions.screenRecordingGranted else {
            throw NSError(
                domain: "ScreenQ.Capture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission required"]
            )
        }

        if displaySelection.isAllDisplaysSelected {
            try await startAllDisplaysCapture(
                subscriberID: subscriberID,
                onFormat: onFormat,
                onFrame: onFrame
            )
            return
        }

        guard let display = await chooseSCDisplay() else {
            throw NSError(
                domain: "ScreenQ.Capture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No shareable display"]
            )
        }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        var excludedApps: [SCRunningApplication] = []
        if let content = try? await SCShareableContent.current {
            excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }
        }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = makeStreamConfiguration(
            sourcePixelWidth: display.width,
            sourcePixelHeight: display.height
        )

        // Choose encoder based on settings.
        if settings.preferH264 {
            let h264 = H264FrameEncoder()
            h264.configure(width: config.width, height: config.height,
                           fps: settings.fps, bitrate: settings.h264Bitrate)
            xstate.encoder = h264
        } else {
            let jpeg = JPEGFrameEncoder()
            jpeg.setQuality(settings.jpegQuality)
            xstate.encoder = jpeg
        }

        // Compute the actual backing scale factor for this display.
        let nativeScaleFactor: Double = {
            if let screen = NSScreen.screens.first(where: { screen in
                guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
                return screenNumber == display.displayID
            }) {
                return Double(screen.backingScaleFactor)
            }
            return 1.0
        }()

        let geometry = ActiveDisplayGeometry(
            displayID: display.displayID,
            pixelWidth: display.width,
            pixelHeight: display.height,
            pointWidth: Double(display.frame.width),
            pointHeight: Double(display.frame.height),
            scaleFactor: nativeScaleFactor
        )
        let format = videoFormat(for: geometry, config: config)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        xstate.removeAllFrameSinks()
        xstate.displayID = display.displayID
        xstate.encoder.reset()
        xstate.sequence = 0

        try await stream.startCapture()
        self.stream = stream
        self.isCapturing = true
        self.isAllDisplaysCaptureActive = false
        self.activeDisplayGeometry = geometry
        self.activeFormat = format
        self.formatSinks[subscriberID] = onFormat

        await onFormat(format)
        xstate.addFrameSink(id: subscriberID, onFrame)
        requestKeyFrame()
        Logger.shared.info("ScreenCaptureKit started: \(config.width)x\(config.height) @ \(self.settings.fps)fps")
    }

    func removeSubscriber(_ id: UUID) {
        xstate.removeFrameSink(id: id)
        formatSinks.removeValue(forKey: id)
    }

    func requestKeyFrame() {
        if let h264 = xstate.encoder as? H264FrameEncoder {
            h264.forceKeyFrame()
        }
    }

    func applyStreamQuality(_ preference: StreamQualityPreference) {
        applyStreamQuality(preference.nativeMessage)
    }

    func applyStreamQuality(_ message: StreamQualityMessage) {
        let profile = message.profile
        currentStreamProfile = profile
        settings.jpegQuality = CGFloat(max(0.1, min(1.0, message.jpegQuality)))
        settings.h264Bitrate = max(500_000, min(30_000_000, message.targetBitrate))
        settings.fps = max(5, min(60, message.targetFPS))
        if !profile.adaptive {
            viewerViewportScale = 1.0
        }
        settings.scale = effectiveCaptureScale(for: profile)
        if !isCapturing {
            settings.preferH264 = profile.codecPreference != .jpeg
        }
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
        if adaptiveEnabled && currentStreamProfile.adaptive {
            viewerViewportScale = CGFloat(max(1.0, min(5.0, viewport.zoomScale)))
        } else {
            viewerViewportScale = 1.0
        }

        let nextScale = effectiveCaptureScale(for: currentStreamProfile)
        guard abs(settings.scale - nextScale) >= 0.02 else { return }
        settings.scale = nextScale
        scheduleActiveStreamConfigurationUpdate()
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
        let baseScale = captureScale(for: profile.scalePolicy)
        guard profile.adaptive else { return baseScale }
        return max(0.25, min(1.0, baseScale * max(1.0, viewerViewportScale)))
    }

    private func makeStreamConfiguration(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = max(0.25, min(1.0, settings.scale))
        config.width = max(160, Int((Double(sourcePixelWidth) * Double(scale)).rounded()))
        config.height = max(120, Int((Double(sourcePixelHeight) * Double(scale)).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.fps)))
        config.queueDepth = 4
        config.showsCursor = settings.showCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 13.0, *) {
            config.capturesAudio = settings.captureAudio
        }
        return config
    }

    private func videoFormat(
        for geometry: ActiveDisplayGeometry,
        config: SCStreamConfiguration
    ) -> VideoFormat {
        VideoFormat(
            pixelWidth: config.width,
            pixelHeight: config.height,
            pointWidth: geometry.pointWidth,
            pointHeight: geometry.pointHeight,
            displayID: geometry.displayID,
            scaleFactor: geometry.scaleFactor,
            encoding: xstate.encoder.encoding,
            targetFPS: settings.fps
        )
    }

    private func scheduleActiveStreamConfigurationUpdate() {
        guard isCapturing, !isAllDisplaysCaptureActive else { return }
        Task { @MainActor [weak self] in
            await self?.updateActiveStreamConfigurationIfNeeded()
        }
    }

    private func updateActiveStreamConfigurationIfNeeded() async {
        guard isCapturing,
              !isAllDisplaysCaptureActive,
              let stream,
              let geometry = activeDisplayGeometry else {
            return
        }

        let config = makeStreamConfiguration(
            sourcePixelWidth: geometry.pixelWidth,
            sourcePixelHeight: geometry.pixelHeight
        )
        if activeFormat?.pixelWidth == config.width,
           activeFormat?.pixelHeight == config.height,
           activeFormat?.targetFPS == settings.fps {
            return
        }

        do {
            try await stream.updateConfiguration(config)
            let format = videoFormat(for: geometry, config: config)
            activeFormat = format
            await notifyFormatSinks(format)
            requestKeyFrame()
            Logger.shared.info("ScreenCaptureKit updated: \(config.width)x\(config.height) @ \(settings.fps)fps")
        } catch {
            Logger.shared.warn("ScreenCaptureKit updateConfiguration failed: \(error.localizedDescription)")
        }
    }

    private func notifyFormatSinks(_ format: VideoFormat) async {
        for sink in formatSinks.values {
            await sink(format)
        }
    }

    func stop() async {
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
        activeDisplayGeometry = nil
        formatSinks.removeAll()
        isAllDisplaysCaptureActive = false
        xstate.removeAllFrameSinks()
        xstate.encoder.reset()
        isCapturing = false
        Logger.shared.info("ScreenCaptureKit stopped")
    }

    private func startAllDisplaysCapture(
        subscriberID: UUID,
        onFormat: @escaping (VideoFormat) async -> Void,
        onFrame: @escaping @Sendable (VideoFrameMeta, Data) -> Void
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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
        activeFormat = format
        formatSinks[subscriberID] = onFormat

        await onFormat(format)
        xstate.addFrameSink(id: subscriberID, onFrame)
        timer.resume()
        Logger.shared.info("ScreenCaptureKit all-displays started: \(format.pixelWidth)x\(format.pixelHeight) @ \(fps)fps")
    }

    private func chooseSCDisplay() async -> SCDisplay? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            if let id = displaySelection.selectedDisplayID,
               let match = content.displays.first(where: { $0.displayID == id }) {
                return match
            }
            return content.displays.first
        } catch {
            Logger.shared.error("SCShareableContent: \(error.localizedDescription)")
            return nil
        }
    }
}

@available(macOS 12.3, *)
extension MacScreenCaptureService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.shared.error("SCStream stopped: \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            self?.isCapturing = false
        }
    }
}

@available(macOS 12.3, *)
extension MacScreenCaptureService: SCStreamOutput {

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

        let state = xstate
        state.sequence &+= 1
        let seq = state.sequence
        let did = state.displayID
        guard let result = state.encoder.encode(sampleBuffer, sequence: seq, displayID: did) else { return }
        state.emitFrame(result.0, result.1)
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
            payloadSize: data.count
        )
        return (meta, data)
    }
}
#endif
