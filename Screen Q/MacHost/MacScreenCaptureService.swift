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
    private var activeFormat: VideoFormat?

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

        let config = SCStreamConfiguration()
        let scale = max(0.25, min(1.0, settings.scale))
        config.width = max(160, Int(Double(display.width) * scale))
        config.height = max(120, Int(Double(display.height) * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.fps)))
        config.queueDepth = 4
        config.showsCursor = settings.showCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 13.0, *) {
            config.capturesAudio = settings.captureAudio
        }

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

        let format = VideoFormat(
            pixelWidth: config.width,
            pixelHeight: config.height,
            pointWidth: Double(display.frame.width),
            pointHeight: Double(display.frame.height),
            displayID: display.displayID,
            scaleFactor: nativeScaleFactor,
            encoding: xstate.encoder.encoding,
            targetFPS: settings.fps
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        xstate.removeAllFrameSinks()
        xstate.displayID = display.displayID
        xstate.encoder.reset()
        xstate.sequence = 0

        try await stream.startCapture()
        self.stream = stream
        self.isCapturing = true
        self.activeFormat = format

        await onFormat(format)
        xstate.addFrameSink(id: subscriberID, onFrame)
        requestKeyFrame()
        Logger.shared.info("ScreenCaptureKit started: \(config.width)x\(config.height) @ \(self.settings.fps)fps")
    }

    func removeSubscriber(_ id: UUID) {
        xstate.removeFrameSink(id: id)
    }

    func requestKeyFrame() {
        if let h264 = xstate.encoder as? H264FrameEncoder {
            h264.forceKeyFrame()
        }
    }

    func stop() async {
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                Logger.shared.warn("stopCapture error: \(error.localizedDescription)")
            }
        }
        stream = nil
        activeFormat = nil
        xstate.removeAllFrameSinks()
        xstate.encoder.reset()
        isCapturing = false
        Logger.shared.info("ScreenCaptureKit stopped")
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
