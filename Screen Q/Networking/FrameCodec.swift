//
//  FrameCodec.swift
//  Screen Q
//
//  Encodes / decodes Screen Q wire frames. See ScreenQProtocol.swift for
//  the full byte layout. The codec is intentionally pure — no IO. Pass
//  bytes in, get frames or partial state out, so it is trivially testable.
//

import Foundation

/// Errors produced by encoding/decoding Screen Q frames.
nonisolated enum FrameCodecError: Error, Equatable, Sendable {
    case badMagic
    case badVersion
    case bodyTooLarge
    case truncatedBody
    case malformedJSON
    case unknownMessageType(UInt16)
}

/// Maximum body size we will accept. Conservative cap — JPEG/H.264 frames
/// from a 6K display compressed do not exceed this in practice. Tunable.
nonisolated let kScreenQMaxBodyBytes: Int = 32 * 1024 * 1024  // 32 MiB

/// A decoded incoming frame: header + raw body bytes (still encoded).
nonisolated struct DecodedFrame: Sendable, Equatable {
    let header: ScreenQHeader
    let body: Data
}

nonisolated enum FrameCodec {

    // MARK: - Header

    static func encodeHeader(_ h: ScreenQHeader) -> Data {
        var out = Data(count: ScreenQProtocol.headerSize)
        out.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!
            putUInt32(p, 0,  h.magic)
            putUInt16(p, 4,  h.version)
            putUInt16(p, 6,  h.type.rawValue)
            putUInt16(p, 8,  h.flags)
            putUInt16(p, 10, h.reserved)
            putUInt64(p, 12, h.sequence)
            putUInt32(p, 20, h.bodyLength)
        }
        return out
    }

    static func decodeHeader(_ data: Data) throws -> ScreenQHeader {
        precondition(data.count >= ScreenQProtocol.headerSize)
        return try data.withUnsafeBytes { raw in
            let p = raw.baseAddress!
            let magic   = readUInt32(p, 0)
            let version = readUInt16(p, 4)
            let typeRaw = readUInt16(p, 6)
            let flags   = readUInt16(p, 8)
            let reserved = readUInt16(p, 10)
            let sequence = readUInt64(p, 12)
            let bodyLen  = readUInt32(p, 20)
            guard magic == ScreenQProtocol.magic else { throw FrameCodecError.badMagic }
            guard version == ScreenQProtocol.version else { throw FrameCodecError.badVersion }
            guard let mt = MessageType(rawValue: typeRaw) else { throw FrameCodecError.unknownMessageType(typeRaw) }
            guard Int(bodyLen) <= kScreenQMaxBodyBytes else { throw FrameCodecError.bodyTooLarge }
            return ScreenQHeader(
                magic: magic,
                version: version,
                type: mt,
                flags: flags,
                reserved: reserved,
                sequence: sequence,
                bodyLength: bodyLen
            )
        }
    }

    // MARK: - Whole-frame encode

    static func encodeJSONMessage<T: Encodable>(
        type: MessageType,
        sequence: UInt64,
        message: T,
        encoder: JSONEncoder = .screenQDefault
    ) throws -> Data {
        let json = try encoder.encode(message)
        var header = ScreenQHeader(type: type, sequence: sequence, bodyLength: UInt32(json.count))
        header.bodyLength = UInt32(json.count)
        var data = encodeHeader(header)
        data.append(json)
        return data
    }

    static func encodeVideoFrame(
        sequence: UInt64,
        meta: VideoFrameMeta,
        payload: Data,
        encoder: JSONEncoder = .screenQDefault
    ) throws -> Data {
        let metaJSON = try encoder.encode(meta)
        var body = Data()
        var len = UInt32(metaJSON.count).bigEndian
        body.append(Data(bytes: &len, count: MemoryLayout<UInt32>.size))
        body.append(metaJSON)
        body.append(payload)
        let header = ScreenQHeader(type: .videoFrame, sequence: sequence, bodyLength: UInt32(body.count))
        var data = encodeHeader(header)
        data.append(body)
        return data
    }

    /// Pull (header, payload) out of a videoFrame body.
    static func decodeVideoFrame(body: Data, decoder: JSONDecoder = .screenQDefault) throws -> (VideoFrameMeta, Data) {
        guard body.count >= 4 else { throw FrameCodecError.truncatedBody }
        let metaLen = body.withUnsafeBytes { raw -> UInt32 in
            let p = raw.baseAddress!
            return readUInt32(p, 0)
        }
        guard 4 + Int(metaLen) <= body.count else { throw FrameCodecError.truncatedBody }
        let metaSlice = body.subdata(in: 4..<(4 + Int(metaLen)))
        let payload = body.subdata(in: (4 + Int(metaLen))..<body.count)
        do {
            let meta = try decoder.decode(VideoFrameMeta.self, from: metaSlice)
            return (meta, payload)
        } catch {
            throw FrameCodecError.malformedJSON
        }
    }
}

// MARK: - Streaming Decoder

/// Buffers bytes from the network and emits decoded frames as they become
/// complete. Not thread-safe; the owning actor/queue must serialise calls.
nonisolated final class FrameStreamDecoder {
    private var buffer = Data()

    func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Try to pull one complete frame out of the buffer. Returns nil if the
    /// buffer doesn't yet contain a full header+body.
    func nextFrame() throws -> DecodedFrame? {
        guard buffer.count >= ScreenQProtocol.headerSize else { return nil }
        let headerData = buffer.prefix(ScreenQProtocol.headerSize)
        let header = try FrameCodec.decodeHeader(headerData)
        let total = ScreenQProtocol.headerSize + Int(header.bodyLength)
        guard buffer.count >= total else { return nil }
        let body = buffer.subdata(in: ScreenQProtocol.headerSize..<total)
        buffer.removeSubrange(0..<total)
        return DecodedFrame(header: header, body: body)
    }

    func reset() { buffer.removeAll(keepingCapacity: false) }
    var bufferedByteCount: Int { buffer.count }
}

// MARK: - JSON helpers

extension JSONEncoder {
    nonisolated static var screenQDefault: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    nonisolated static var screenQDefault: JSONDecoder { JSONDecoder() }
}

// MARK: - Big-endian primitives

@inline(__always)
nonisolated private func putUInt16(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt16) {
    let be = v.bigEndian
    (p + off).bindMemory(to: UInt16.self, capacity: 1).pointee = be
}
@inline(__always)
nonisolated private func putUInt32(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt32) {
    let be = v.bigEndian
    (p + off).bindMemory(to: UInt32.self, capacity: 1).pointee = be
}
@inline(__always)
nonisolated private func putUInt64(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt64) {
    let be = v.bigEndian
    (p + off).bindMemory(to: UInt64.self, capacity: 1).pointee = be
}
@inline(__always)
nonisolated private func readUInt16(_ p: UnsafeRawPointer, _ off: Int) -> UInt16 {
    let v = (p + off).bindMemory(to: UInt16.self, capacity: 1).pointee
    return UInt16(bigEndian: v)
}
@inline(__always)
nonisolated private func readUInt32(_ p: UnsafeRawPointer, _ off: Int) -> UInt32 {
    let v = (p + off).bindMemory(to: UInt32.self, capacity: 1).pointee
    return UInt32(bigEndian: v)
}
@inline(__always)
nonisolated private func readUInt64(_ p: UnsafeRawPointer, _ off: Int) -> UInt64 {
    let v = (p + off).bindMemory(to: UInt64.self, capacity: 1).pointee
    return UInt64(bigEndian: v)
}
