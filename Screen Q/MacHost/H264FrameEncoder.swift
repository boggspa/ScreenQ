//
//  H264FrameEncoder.swift
//  Screen Q
//
//  Hardware-accelerated H.264 encoder using VTCompressionSession. Conforms
//  to the existing FrameEncoder protocol so it drops into the capture
//  pipeline alongside JPEGFrameEncoder.
//
//  Each encoded callback produces one or more NAL units concatenated into
//  a single Data blob — the same format RemoteScreenRenderer will feed
//  into VTDecompressionSession on the viewer side.
//

#if os(macOS)
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore

nonisolated private func screenQH264CaptureWallClockTimestamp(forHostTimestamp hostTimestamp: TimeInterval) -> TimeInterval {
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

nonisolated private final class H264EncodedFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var encodedData: Data?
    private var encodedIsKeyFrame = false

    func store(data: Data, isKeyFrame: Bool) {
        lock.lock()
        encodedData = data
        encodedIsKeyFrame = isKeyFrame
        lock.unlock()
    }

    func snapshot() -> (data: Data, isKeyFrame: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let encodedData else { return nil }
        return (encodedData, encodedIsKeyFrame)
    }
}

nonisolated final class H264FrameEncoder: FrameEncoder, @unchecked Sendable {

    let encoding: VideoEncoding = .h264

    // Configuration
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var targetFPS: Int = 30
    private var maxBitrate: Int = 8_000_000        // 8 Mbps default
    private var keyFrameIntervalFrames: Int = 60    // key every 2s @ 30fps

    // VT state
    private var session: VTCompressionSession?
    private let lock = NSLock()

    private var forceNextKeyFrame = true

    // MARK: - Public API

    func configure(width: Int, height: Int, fps: Int, bitrate: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        tearDownLocked()
        self.width = Int32(width)
        self.height = Int32(height)
        self.targetFPS = fps
        if let b = bitrate { self.maxBitrate = b }
        createSessionLocked()
    }

    /// Adjust bitrate on the fly for adaptive streaming.
    func updateBitrate(_ bps: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bps as CFNumber)
        // Also set a byte limit per second (1.5× average) to avoid spikes.
        let limit: [Int] = [bps * 3 / 2, 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: limit as CFArray)
    }

    func updateFrameRate(_ fps: Int) {
        lock.lock()
        defer { lock.unlock() }
        targetFPS = max(1, min(120, fps))
        keyFrameIntervalFrames = max(1, targetFPS * 2)
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: targetFPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: keyFrameIntervalFrames as CFNumber)
    }

    func updateKeyFrameInterval(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        let clampedSeconds = max(0.5, min(10.0, seconds))
        keyFrameIntervalFrames = max(1, Int((Double(targetFPS) * clampedSeconds).rounded()))
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: keyFrameIntervalFrames as CFNumber)
    }

    /// Request that the next frame be a keyframe.
    func forceKeyFrame() {
        lock.lock()
        defer { lock.unlock() }
        forceNextKeyFrame = true
    }

    func encode(_ sample: CMSampleBuffer, sequence: UInt64, displayID: CGDirectDisplayID) -> (VideoFrameMeta, Data)? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        lock.lock()
        defer { lock.unlock() }

        // Lazy-create or recreate if resolution changed.
        if session == nil || Int32(w) != width || Int32(h) != height {
            width = Int32(w)
            height = Int32(h)
            tearDownLocked()
            createSessionLocked()
        }
        guard let session = self.session else {
            return nil
        }
        let shouldForceKeyFrame = forceNextKeyFrame
        if forceNextKeyFrame {
            forceNextKeyFrame = false
        }

        // Presentation timestamp
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))

        // Keep each VT callback's output isolated to this frame so encoder
        // reconfiguration cannot race shared pending state under load.
        let encodedFrame = H264EncodedFrameBox()
        let encodedFrameRefcon = Unmanaged.passRetained(encodedFrame)

        let frameProperties: CFDictionary? = shouldForceKeyFrame
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary)
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: encodedFrameRefcon.toOpaque(),
            infoFlagsOut: nil
        )

        guard status == noErr else {
            encodedFrameRefcon.release()
            Logger.shared.warn("VTCompressionSession encode failed: \(status)")
            return nil
        }

        // Force synchronous output.
        let completeStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        encodedFrameRefcon.release()
        guard completeStatus == noErr else {
            Logger.shared.warn("VTCompressionSession complete failed: \(completeStatus)")
            return nil
        }

        guard let encoded = encodedFrame.snapshot() else { return nil }

        let timestamp = CMTimeGetSeconds(pts).isFinite ? CMTimeGetSeconds(pts) : CACurrentMediaTime()
        let meta = VideoFrameMeta(
            sequence: sequence,
            captureTimestamp: timestamp,
            pixelWidth: w,
            pixelHeight: h,
            displayID: displayID,
            encoding: .h264,
            isKeyFrame: encoded.isKeyFrame,
            payloadSize: encoded.data.count,
            captureWallClockTimestamp: screenQH264CaptureWallClockTimestamp(forHostTimestamp: timestamp)
        )
        return (meta, encoded.data)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        tearDownLocked()
    }

    deinit {
        lock.lock()
        tearDownLocked()
        lock.unlock()
    }

    // MARK: - Session lifecycle

    private func createSessionLocked() {
        guard width > 0, height > 0 else { return }

        var sessionOut: VTCompressionSession?

        let callbackPtr: VTCompressionOutputCallback = { _, sourceFrameRefcon, status, _, sampleBuffer in
            guard let sourceFrameRefcon else { return }
            let output = Unmanaged<H264EncodedFrameBox>.fromOpaque(sourceFrameRefcon).takeUnretainedValue()
            H264FrameEncoder.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer, output: output)
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callbackPtr,
            refcon: nil,
            compressionSessionOut: &sessionOut
        )

        guard status == noErr, let session = sessionOut else {
            Logger.shared.error("VTCompressionSessionCreate failed: \(status)")
            return
        }

        // Properties
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: maxBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: targetFPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: keyFrameIntervalFrames as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                             value: 1 as CFNumber)

        // Data rate limit: 1.5x average over 1 second.
        let limit: [Int] = [maxBitrate * 3 / 2, 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: limit as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        self.forceNextKeyFrame = true
        Logger.shared.info("H.264 encoder created: \(width)x\(height) @ \(targetFPS)fps, \(maxBitrate/1000)kbps")
    }

    private func tearDownLocked() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        forceNextKeyFrame = true
    }

    // MARK: - Output callback

    /// Called by VideoToolbox on the encoder's internal queue.
    fileprivate static func handleEncodedFrame(
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?,
        output: H264EncodedFrameBox
    ) {
        guard status == noErr, let sampleBuffer, sampleBuffer.isValid else { return }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync

        // Extract parameter sets (SPS/PPS) for keyframes — prepend as Annex B.
        var outputData = Data()
        if isKey, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            outputData.append(extractParameterSets(formatDesc))
        }

        // Convert AVCC length-prefixed NALUs to Annex B (start codes).
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var offset = 0
        while offset + 4 <= length {
            var naluLength: UInt32 = 0
            let lengthStatus = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: offset, dataLength: 4, destination: &naluLength)
            guard lengthStatus == noErr else { return }
            naluLength = naluLength.bigEndian
            offset += 4
            let payloadLength = Int(naluLength)
            guard payloadLength > 0, offset + payloadLength <= length else { return }

            // Annex B start code
            outputData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

            var naluData = Data(count: payloadLength)
            let copyStatus = naluData.withUnsafeMutableBytes { buf -> OSStatus in
                guard let baseAddress = buf.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    dataBuffer,
                    atOffset: offset,
                    dataLength: payloadLength,
                    destination: baseAddress
                )
            }
            guard copyStatus == noErr else { return }
            outputData.append(naluData)
            offset += payloadLength
        }

        guard !outputData.isEmpty else { return }
        output.store(data: outputData, isKeyFrame: isKey)
    }

    private static func extractParameterSets(_ formatDesc: CMFormatDescription) -> Data {
        var data = Data()
        // SPS
        var spsCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
        )
        for i in 0..<spsCount {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let ptr {
                data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                data.append(ptr, count: size)
            }
        }
        return data
    }
}

#endif
