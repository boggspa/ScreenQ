//
//  RemoteScreenRenderer.swift
//  Screen Q
//
//  Decodes incoming JPEG and H.264 frames and exposes them to SwiftUI as
//  a current `CGImage`. Stale frames are dropped so the viewer never
//  queues more than one frame deep — playback latency wins over
//  completeness for screen sharing.
//

import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Combine
import VideoToolbox
import CoreMedia
import CoreVideo

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class RemoteScreenRenderer: ObservableObject {

    @Published private(set) var currentImage: CGImage?
    @Published private(set) var format: VideoFormat?

    private var lastSequence: UInt64 = 0
    private var h264Decoder: H264Decoder?

    func updateFormat(_ format: VideoFormat) {
        self.format = format
        self.lastSequence = 0
        if format.encoding == .h264 {
            h264Decoder = H264Decoder()
        } else {
            h264Decoder = nil
        }
    }

    /// Feed a freshly received frame. We drop frames whose sequence is older
    /// than the latest one we've already presented.
    func ingest(meta: VideoFrameMeta, payload: Data, stats: TransportStats?) {
        if meta.sequence <= lastSequence {
            stats?.recordDropped()
            return
        }
        lastSequence = meta.sequence
        switch meta.encoding {
        case .jpeg:
            if let image = decodeJPEG(payload) {
                currentImage = image
                stats?.recordFrame(byteCount: payload.count)
            } else {
                Logger.shared.warn("JPEG decode failed for seq \(meta.sequence), \(payload.count) bytes")
                stats?.recordDropped()
            }
        case .h264:
            if let decoder = h264Decoder, let image = decoder.decode(payload) {
                currentImage = image
                stats?.recordFrame(byteCount: payload.count)
            } else {
                if h264Decoder == nil {
                    Logger.shared.warn("H.264 frame \(meta.sequence) dropped: no decoder (missing videoFormat?)")
                } else {
                    Logger.shared.debug("H.264 frame \(meta.sequence) decoded to nil (\(payload.count) bytes, key=\(meta.isKeyFrame))")
                }
                stats?.recordDropped()
            }
        }
    }

    func reset() {
        currentImage = nil
        format = nil
        lastSequence = 0
        h264Decoder = nil
    }

    private func decodeJPEG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - H.264 Annex B Decoder

/// Decodes Annex B H.264 byte streams using VTDecompressionSession.
/// Thread-safe for single-threaded use from the MainActor.
private final class H264Decoder {

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var pendingImage: CGImage?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Cached SPS/PPS for format description creation.
    private var sps: Data?
    private var pps: Data?

    func decode(_ annexBData: Data) -> CGImage? {
        pendingImage = nil

        let nalus = splitNALUs(annexBData)
        guard !nalus.isEmpty else { return nil }

        // Extract SPS/PPS and rebuild format description if needed.
        for nalu in nalus {
            guard !nalu.isEmpty else { continue }
            let naluType = nalu[0] & 0x1F
            switch naluType {
            case 7: // SPS
                if sps != nalu { sps = nalu; rebuildFormatDescription() }
            case 8: // PPS
                if pps != nalu { pps = nalu; rebuildFormatDescription() }
            default:
                break
            }
        }

        guard let formatDescription else { return nil }

        let frameNALUs = nalus.filter { nalu in
            guard !nalu.isEmpty else { return false }
            let naluType = nalu[0] & 0x1F
            return naluType != 7 && naluType != 8 && naluType != 9
        }
        guard !frameNALUs.isEmpty else { return nil }

        guard let blockBuffer = createBlockBuffer(from: frameNALUs) else { return nil }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = blockBuffer.dataLength
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000),
            decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        if status == noErr, let sb = sampleBuffer {
            decodeSampleBuffer(sb)
        } else {
            Logger.shared.debug("CMSampleBufferCreateReady failed for H.264 access unit: \(status)")
        }

        return pendingImage
    }

    // MARK: - NALU splitting

    /// Splits Annex B byte stream into individual NAL units (without start codes).
    private func splitNALUs(_ data: Data) -> [Data] {
        var nalus: [Data] = []
        var i = 0
        let bytes = [UInt8](data)
        let count = bytes.count

        while i < count {
            // Find start code (00 00 01 or 00 00 00 01)
            var startCodeLen = 0
            if i + 2 < count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                startCodeLen = 3
            } else if i + 3 < count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                startCodeLen = 4
            } else {
                i += 1
                continue
            }
            let naluStart = i + startCodeLen
            // Find next start code
            var j = naluStart + 1
            while j < count {
                if j + 2 < count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 1 {
                    break
                }
                if j + 3 < count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 0 && bytes[j+3] == 1 {
                    break
                }
                j += 1
            }
            if naluStart < j {
                nalus.append(Data(bytes[naluStart..<j]))
            }
            i = j
        }
        return nalus
    }

    // MARK: - Format description

    private func rebuildFormatDescription() {
        guard let sps, let pps else { return }
        formatDescription = nil
        session = nil

        // We need stable pointers, so use withUnsafeBytes on each.
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes = [sps.count, pps.count]
                var fmt: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fmt
                )
                if status == noErr {
                    formatDescription = fmt
                } else {
                    Logger.shared.debug("CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(status)")
                }
            }
        }
    }

    // MARK: - Block buffer

    /// Wraps one H.264 access unit in an AVCC-style block buffer.
    private func createBlockBuffer(from nalus: [Data]) -> CMBlockBuffer? {
        var fullData = Data()
        for nalu in nalus {
            var avccLength = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &avccLength) { fullData.append(contentsOf: $0) }
            fullData.append(nalu)
        }

        var blockBuffer: CMBlockBuffer?
        fullData.withUnsafeBytes { rawBuf in
            guard let baseAddr = rawBuf.baseAddress else { return }
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: fullData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: fullData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            if let bb = blockBuffer {
                CMBlockBufferReplaceDataBytes(
                    with: baseAddr,
                    blockBuffer: bb,
                    offsetIntoDestination: 0,
                    dataLength: fullData.count
                )
            }
        }
        return blockBuffer
    }

    // MARK: - VT Decompression

    private func decodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        ensureSession()
        guard let session else { return }

        var infoFlags = VTDecodeInfoFlags()

        // VideoToolbox may still deliver output asynchronously on iOS even
        // when we do not request async decode. Wait briefly for the callback
        // so `decode(_:)` can publish every new frame instead of leaving the
        // viewer stuck on the previous image.
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        if status != noErr {
            Logger.shared.debug("VTDecompressionSession decode error: \(status)")
            return
        }

        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    private func ensureSession() {
        guard session == nil, let formatDescription else { return }

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]

        var decompressionSession: VTDecompressionSession?

        let callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer else { return }
                guard let refCon else { return }
                let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
                let ci = CIImage(cvPixelBuffer: imageBuffer)
                let extent = ci.extent
                if let cgImage = decoder.ciContext.createCGImage(ci, from: extent) {
                    decoder.pendingImage = cgImage
                }
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var callbackRecord = callback
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &decompressionSession
        )

        if status == noErr {
            session = decompressionSession
        } else {
            Logger.shared.debug("VTDecompressionSessionCreate failed: \(status)")
        }
    }
}
