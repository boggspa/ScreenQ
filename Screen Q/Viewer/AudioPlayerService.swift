//
//  AudioPlayerService.swift
//  Screen Q
//
//  Plays back raw PCM audio received from the host. Uses AVAudioEngine
//  for low-latency playback with a small buffer to stay responsive.
//

import Foundation
import Combine
import AVFoundation

@MainActor
final class AudioPlayerService: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published var muted = false

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?

    func configure(format: AudioFormatMessage) {
        stop()

        let avFormat = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channels)
        )
        guard let avFormat else {
            Logger.shared.error("AudioPlayer: invalid format sr=\(format.sampleRate) ch=\(format.channels)")
            return
        }
        self.audioFormat = avFormat

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: avFormat)

        do {
            try engine.start()
            player.play()
            self.engine = engine
            self.playerNode = player
            self.isPlaying = true
            Logger.shared.info("AudioPlayer started: \(format.sampleRate)Hz \(format.channels)ch")
        } catch {
            Logger.shared.error("AudioPlayer start failed: \(error.localizedDescription)")
        }
    }

    func ingest(_ data: Data) {
        guard !muted, let format = audioFormat, let player = playerNode else { return }

        let frameCount = AVAudioFrameCount(data.count) / AVAudioFrameCount(format.streamDescription.pointee.mBytesPerFrame)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress else { return }
            if let dst = buffer.floatChannelData {
                // Interleaved float data
                memcpy(dst[0], src, min(data.count, Int(frameCount) * MemoryLayout<Float>.size * Int(format.channelCount)))
            } else if let dst = buffer.int16ChannelData {
                memcpy(dst[0], src, min(data.count, Int(frameCount) * MemoryLayout<Int16>.size * Int(format.channelCount)))
            }
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        audioFormat = nil
        isPlaying = false
    }
}
