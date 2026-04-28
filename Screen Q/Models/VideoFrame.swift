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
