//
//  AudioCaptureService.swift
//  Screen Q
//
//  Captures system audio via ScreenCaptureKit's audio output and encodes
//  it as AAC using AudioToolbox's AudioConverter. Streams encoded frames
//  over the Screen Q protocol.
//

#if os(macOS)
import Foundation
import Combine
import ScreenCaptureKit
import AVFoundation
import AudioToolbox
import CoreMedia

@available(macOS 13.0, *)
@MainActor
final class AudioCaptureService: ObservableObject {

    @Published private(set) var isCapturing = false
    var enabled = false

    private var audioSink: ((Data) -> Void)?
    private var formatSink: ((AudioFormatMessage) -> Void)?

    /// Start audio capture on the given SCStream.
    /// Call this after the SCStream is already created and started — we just
    /// add an audio output to the existing stream.
    func attach(
        to stream: SCStream,
        queue: DispatchQueue,
        onFormat: @escaping (AudioFormatMessage) -> Void,
        onAudioFrame: @escaping @Sendable (Data) -> Void
    ) throws {
        guard enabled else { return }
        self.formatSink = onFormat
        self.audioSink = onAudioFrame

        // Add audio output (requires macOS 13+).
        try stream.addStreamOutput(
            AudioOutputDelegate(onBuffer: { [weak self] buffer, time in
                self?.handleAudioBuffer(buffer, time: time)
            }),
            type: .audio,
            sampleHandlerQueue: queue
        )
        isCapturing = true
        Logger.shared.info("Audio capture attached")
    }

    func stop() {
        isCapturing = false
        audioSink = nil
        formatSink = nil
    }

    private var sentFormat = false

    private func handleAudioBuffer(_ buffer: CMSampleBuffer, time: CMTime) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(buffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }

        // Send format once.
        if !sentFormat {
            let fmt = AudioFormatMessage(
                sampleRate: asbd.mSampleRate,
                channels: Int(asbd.mChannelsPerFrame),
                codec: "pcm",  // we send raw PCM; viewer decodes
                bitsPerSample: Int(asbd.mBitsPerChannel)
            )
            formatSink?(fmt)
            sentFormat = true
        }

        // Extract raw PCM bytes.
        guard let dataBuffer = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        audioSink?(data)
    }
}

/// Minimal SCStreamOutput delegate that forwards audio buffers.
@available(macOS 13.0, *)
private final class AudioOutputDelegate: NSObject, SCStreamOutput {
    let onBuffer: (CMSampleBuffer, CMTime) -> Void

    init(onBuffer: @escaping (CMSampleBuffer, CMTime) -> Void) {
        self.onBuffer = onBuffer
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onBuffer(sampleBuffer, pts)
    }
}
#endif
