//
//  VideoFrame.swift
//  Screen Q
//

import Foundation

/// A single frame as it travels over the wire. We keep this small: a header
/// JSON object plus a raw payload (JPEG bytes today, encoded H.264 NAL units
/// when VideoToolbox is plugged in).
nonisolated struct VideoFrameMeta: Codable, Hashable, Sendable {
    let sequence: UInt64
    let captureTimestamp: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
    let displayID: UInt32
    let encoding: VideoEncoding
    let isKeyFrame: Bool
    let payloadSize: Int
    let region: VideoFrameRegion?
    let captureWallClockTimestamp: TimeInterval?

    init(
        sequence: UInt64,
        captureTimestamp: TimeInterval,
        pixelWidth: Int,
        pixelHeight: Int,
        displayID: UInt32,
        encoding: VideoEncoding,
        isKeyFrame: Bool,
        payloadSize: Int,
        region: VideoFrameRegion? = nil,
        captureWallClockTimestamp: TimeInterval? = nil
    ) {
        self.sequence = sequence
        self.captureTimestamp = captureTimestamp
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.displayID = displayID
        self.encoding = encoding
        self.isKeyFrame = isKeyFrame
        self.payloadSize = payloadSize
        self.region = region
        self.captureWallClockTimestamp = captureWallClockTimestamp
    }

    func withRegion(_ region: VideoFrameRegion?) -> VideoFrameMeta {
        VideoFrameMeta(
            sequence: sequence,
            captureTimestamp: captureTimestamp,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            displayID: displayID,
            encoding: encoding,
            isKeyFrame: isKeyFrame,
            payloadSize: payloadSize,
            region: region,
            captureWallClockTimestamp: captureWallClockTimestamp
        )
    }
}

nonisolated enum VideoFrameRegionKind: String, Codable, Hashable, Sendable {
    case viewport
}

/// Optional placement metadata for region-of-interest frames. Region
/// coordinates are expressed in the current full remote frame's pixel space,
/// while `pixelWidth` / `pixelHeight` on `VideoFrameMeta` describe the
/// encoded region image itself.
nonisolated struct VideoFrameRegion: Codable, Hashable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let fullWidth: Int
    let fullHeight: Int
    let kind: VideoFrameRegionKind

    init(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        fullWidth: Int,
        fullHeight: Int,
        kind: VideoFrameRegionKind = .viewport
    ) {
        let safeFullWidth = max(1, fullWidth)
        let safeFullHeight = max(1, fullHeight)
        let safeX = min(max(0, x), safeFullWidth - 1)
        let safeY = min(max(0, y), safeFullHeight - 1)
        self.x = safeX
        self.y = safeY
        self.width = max(1, min(width, safeFullWidth - safeX))
        self.height = max(1, min(height, safeFullHeight - safeY))
        self.fullWidth = safeFullWidth
        self.fullHeight = safeFullHeight
        self.kind = kind
    }

    var coversFullFrame: Bool {
        x == 0 && y == 0 && width >= fullWidth && height >= fullHeight
    }
}

/// Stream-wide format / negotiated metadata sent at the start of streaming.
nonisolated struct VideoFormat: Codable, Hashable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: Double      // points (so the viewer can size the canvas)
    let pointHeight: Double
    let displayID: UInt32
    let scaleFactor: Double
    let encoding: VideoEncoding
    let targetFPS: Int
}
