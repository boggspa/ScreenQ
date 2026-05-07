//
//  SessionRecorder.swift
//  Screen Q
//
//  Records the decoded video stream to a .mov file using AVAssetWriter.
//  Can be toggled on/off from the viewer toolbar. Writes H.264 at the
//  native stream resolution.
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import Combine

@MainActor
final class SessionRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var outputURL: URL?

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var frameCount: Int = 0
    private var timer: Timer?
    private var outputWidth: Int = 0
    private var outputHeight: Int = 0

    func start(width: Int, height: Int) {
        guard !isRecording else { return }
        guard width > 0, height > 0 else {
            Logger.shared.error("SessionRecorder: invalid recording size \(width)x\(height)")
            return
        }

        let filename = "ScreenQ_\(DateFormatter.filenameSafe.string(from: Date())).mov"
        #if os(macOS)
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #else
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #endif
        let url = dir.appendingPathComponent(filename)

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: attrs
            )

            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            self.assetWriter = writer
            self.videoInput = input
            self.pixelBufferAdaptor = adaptor
            self.startTime = nil
            self.frameCount = 0
            self.outputURL = url
            self.outputWidth = width
            self.outputHeight = height
            self.isRecording = true
            self.duration = 0

            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.duration += 1
                }
            }

            Logger.shared.info("SessionRecorder: started → \(url.lastPathComponent)")
        } catch {
            Logger.shared.error("SessionRecorder: failed to start: \(error)")
        }
    }

    func appendFrame(_ image: CGImage) {
        guard isRecording,
              let input = videoInput,
              let adaptor = pixelBufferAdaptor,
              input.isReadyForMoreMediaData else { return }

        let now = CMTime(value: CMTimeValue(frameCount), timescale: 30)
        if startTime == nil { startTime = now }

        guard let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        let width = max(1, outputWidth)
        let height = max(1, outputHeight)
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        if let ctx {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            let sourceSize = CGSize(width: image.width, height: image.height)
            let targetRect = AVMakeRect(
                aspectRatio: sourceSize,
                insideRect: CGRect(x: 0, y: 0, width: width, height: height)
            )
            ctx.draw(image, in: targetRect)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        adaptor.append(pb, withPresentationTime: now)
        frameCount += 1
    }

    func stop() {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil

        videoInput?.markAsFinished()
        assetWriter?.finishWriting { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRecording = false
                if let url = self.outputURL {
                    Logger.shared.info("SessionRecorder: saved \(url.lastPathComponent) (\(self.frameCount) frames)")
                }
            }
        }
    }
}

private extension DateFormatter {
    static let filenameSafe: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
