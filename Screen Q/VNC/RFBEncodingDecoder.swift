//
//  RFBEncodingDecoder.swift
//  Screen Q
//
//  Pure framebuffer-encoding decoders for the VNC/RFB client. Network framing
//  stays in RFBConnection; this layer turns supported rectangle encodings into
//  the 32bpp XRGB byte layout consumed by RFBFrameBuffer.
//

import Foundation
import Compression
import CoreGraphics
import ImageIO

nonisolated enum RFBEncodingDecoder {
    static let bytesPerPixel = 4
    #if os(iOS)
    static let maxDecodedRectBytes = 32 * 1024 * 1024
    #else
    static let maxDecodedRectBytes = 256 * 1024 * 1024
    #endif
    private static let tightMinToCompress = 12
    private static let tightExplicitFilter: UInt8 = 0x04
    private static let tightFill: UInt8 = 0x08
    private static let tightJPEG: UInt8 = 0x09
    private static let tightNoZlib: UInt8 = 0x0A
    private static let tightPNG: UInt8 = 0x0A
    private static let tightNoZlibExplicitFilter: UInt8 = 0x0E
    private static let tightFilterCopy: UInt8 = 0x00
    private static let tightFilterPalette: UInt8 = 0x01
    private static let tightFilterGradient: UInt8 = 0x02

    final class TightDecodeState {
        private var streams = (0..<4).map { _ in TightInflateStream() }

        func resetStream(_ index: Int) {
            guard streams.indices.contains(index) else { return }
            streams[index].reset()
        }

        func resetAll() {
            for stream in streams {
                stream.reset()
            }
        }

        func inflate(streamID: Int, compressed: Data, expectedByteCount: Int) throws -> Data {
            guard streams.indices.contains(streamID) else {
                throw RFBError.protocolError("Invalid Tight zlib stream id: \(streamID)")
            }
            return try streams[streamID].inflate(compressed, expectedByteCount: expectedByteCount)
        }
    }

    static func decodedByteCount(width: UInt16, height: UInt16) throws -> Int {
        guard width > 0, height > 0 else {
            throw RFBError.protocolError("Framebuffer rectangle has invalid dimensions: \(width)x\(height)")
        }
        let pixelProduct = Int(width).multipliedReportingOverflow(by: Int(height))
        guard !pixelProduct.overflow else {
            throw RFBError.protocolError("Framebuffer rectangle too large: \(width)x\(height)")
        }
        let byteProduct = pixelProduct.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
        guard !byteProduct.overflow,
              byteProduct.partialValue <= maxDecodedRectBytes else {
            throw RFBError.protocolError("Framebuffer rectangle too large: \(width)x\(height)")
        }
        return byteProduct.partialValue
    }

    static func decodeHextile(
        width: UInt16,
        height: UInt16,
        read: (Int) async throws -> Data
    ) async throws -> Data {
        let outputByteCount = try decodedByteCount(width: width, height: height)
        var output = Data(count: outputByteCount)
        var background = Data(repeating: 0, count: bytesPerPixel)
        var foreground = Data(repeating: 0, count: bytesPerPixel)
        let rectWidth = Int(width)
        let rectHeight = Int(height)

        for tileY in stride(from: 0, to: rectHeight, by: 16) {
            for tileX in stride(from: 0, to: rectWidth, by: 16) {
                let tileWidth = min(16, rectWidth - tileX)
                let tileHeight = min(16, rectHeight - tileY)
                let subencodingData = try await read(1)
                guard let subencoding = subencodingData.first else {
                    throw RFBError.disconnected
                }

                guard subencoding & 0xE0 == 0 else {
                    throw RFBError.protocolError("Invalid Hextile subencoding: \(subencoding)")
                }

                if subencoding & 0x01 != 0 {
                    let rawTile = try await read(tileWidth * tileHeight * bytesPerPixel)
                    copyTile(
                        rawTile,
                        tileWidth: tileWidth,
                        tileHeight: tileHeight,
                        tileX: tileX,
                        tileY: tileY,
                        rectWidth: rectWidth,
                        into: &output
                    )
                    continue
                }

                if subencoding & 0x02 != 0 {
                    background = try await read(bytesPerPixel)
                }
                fillRect(
                    tileX: tileX,
                    tileY: tileY,
                    width: tileWidth,
                    height: tileHeight,
                    color: background,
                    rectWidth: rectWidth,
                    into: &output
                )

                if subencoding & 0x04 != 0 {
                    foreground = try await read(bytesPerPixel)
                }

                guard subencoding & 0x08 != 0 else { continue }
                let subrectCountData = try await read(1)
                guard let subrectCountByte = subrectCountData.first else {
                    throw RFBError.disconnected
                }
                let subrectCount = Int(subrectCountByte)
                let subrectsColoured = subencoding & 0x10 != 0

                for _ in 0..<subrectCount {
                    let color = subrectsColoured ? try await read(bytesPerPixel) : foreground
                    let xyData = try await read(1)
                    let whData = try await read(1)
                    guard let xy = xyData.first, let wh = whData.first else {
                        throw RFBError.disconnected
                    }
                    let subX = Int(xy >> 4)
                    let subY = Int(xy & 0x0F)
                    let subW = Int(wh >> 4) + 1
                    let subH = Int(wh & 0x0F) + 1

                    guard subX + subW <= tileWidth, subY + subH <= tileHeight else {
                        throw RFBError.protocolError("Invalid Hextile subrect bounds")
                    }

                    fillRect(
                        tileX: tileX + subX,
                        tileY: tileY + subY,
                        width: subW,
                        height: subH,
                        color: color,
                        rectWidth: rectWidth,
                        into: &output
                    )
                }
            }
        }

        return output
    }

    static func decodeZRLE(
        width: UInt16,
        height: UInt16,
        compressed: Data,
        pixelFormat: RFBPixelFormat = .xrgb32
    ) throws -> Data {
        try validateZRLEPixelFormat(pixelFormat)
        let outputByteCount = try decodedByteCount(width: width, height: height)
        let rectWidth = Int(width)
        let rectHeight = Int(height)
        let inflated = try inflateZRLE(compressed, width: width, height: height, outputByteCount: outputByteCount)
        var cursor = ByteCursor(data: inflated)
        var output = Data(count: outputByteCount)

        for tileY in stride(from: 0, to: rectHeight, by: 64) {
            for tileX in stride(from: 0, to: rectWidth, by: 64) {
                let tileWidth = min(64, rectWidth - tileX)
                let tileHeight = min(64, rectHeight - tileY)
                let subencoding = try cursor.readUInt8()
                let usesRLE = subencoding & 0x80 != 0
                let paletteSize = Int(subencoding & 0x7F)
                let palette = try cursor.readPixels(paletteSize)

                if usesRLE {
                    if paletteSize == 0 {
                        try decodePlainRLETile(
                            cursor: &cursor,
                            tileX: tileX,
                            tileY: tileY,
                            tileWidth: tileWidth,
                            tileHeight: tileHeight,
                            rectWidth: rectWidth,
                            output: &output
                        )
                    } else {
                        try decodePaletteRLETile(
                            cursor: &cursor,
                            palette: palette,
                            tileX: tileX,
                            tileY: tileY,
                            tileWidth: tileWidth,
                            tileHeight: tileHeight,
                            rectWidth: rectWidth,
                            output: &output
                        )
                    }
                    continue
                }

                switch paletteSize {
                case 0:
                    try decodeRawZRLETile(
                        cursor: &cursor,
                        tileX: tileX,
                        tileY: tileY,
                        tileWidth: tileWidth,
                        tileHeight: tileHeight,
                        rectWidth: rectWidth,
                        output: &output
                    )
                case 1:
                    fillRect(
                        tileX: tileX,
                        tileY: tileY,
                        width: tileWidth,
                        height: tileHeight,
                        pixel: palette[0],
                        rectWidth: rectWidth,
                        into: &output
                    )
                case 2...16:
                    try decodePackedPaletteTile(
                        cursor: &cursor,
                        palette: palette,
                        tileX: tileX,
                        tileY: tileY,
                        tileWidth: tileWidth,
                        tileHeight: tileHeight,
                        rectWidth: rectWidth,
                        output: &output
                    )
                default:
                    throw RFBError.protocolError("Invalid ZRLE palette size without RLE: \(paletteSize)")
                }
            }
        }

        guard cursor.isAtEnd else {
            throw RFBError.protocolError("Extra ZRLE tile data")
        }

        return output
    }

    static func decodeTight(
        width: UInt16,
        height: UInt16,
        encoding: Int32,
        state: TightDecodeState,
        pixelFormat: RFBPixelFormat = .xrgb32,
        read: (Int) async throws -> Data
    ) async throws -> Data {
        try validateZRLEPixelFormat(pixelFormat)
        _ = try decodedByteCount(width: width, height: height)
        let isTightPNG = encoding == RFBEncoding.tightPNG.rawValue
        let controlData = try await read(1)
        guard let control = controlData.first else { throw RFBError.disconnected }
        let mode = try processTightControl(control, isTightPNG: isTightPNG, state: state)

        switch mode {
        case .fill:
            let rgb = try await read(3)
            return try makeTightFill(width: width, height: height, rgb: rgb)
        case .jpeg:
            let length = try await readTightCompactLength(read: read)
            let data = try await read(length)
            return try decodeTightImage(data, width: width, height: height)
        case .png:
            let length = try await readTightCompactLength(read: read)
            let data = try await read(length)
            return try decodeTightImage(data, width: width, height: height)
        case .basic(let usesZlib, let basicControl):
            return try await decodeTightBasic(
                width: width,
                height: height,
                control: basicControl,
                usesZlib: usesZlib,
                state: state,
                read: read
            )
        }
    }

    static func decodeTightPayload(
        width: UInt16,
        height: UInt16,
        encoding: Int32,
        payload: Data,
        state: TightDecodeState,
        pixelFormat: RFBPixelFormat = .xrgb32
    ) throws -> Data {
        try validateZRLEPixelFormat(pixelFormat)
        _ = try decodedByteCount(width: width, height: height)
        var cursor = ByteCursor(data: payload)
        let isTightPNG = encoding == RFBEncoding.tightPNG.rawValue
        let control = try cursor.readUInt8()
        let mode = try processTightControl(control, isTightPNG: isTightPNG, state: state)
        let output: Data

        switch mode {
        case .fill:
            output = try makeTightFill(width: width, height: height, rgb: cursor.readExact(3))
        case .jpeg:
            let length = try readTightCompactLength(cursor: &cursor)
            output = try decodeTightImage(cursor.readExact(length), width: width, height: height)
        case .png:
            let length = try readTightCompactLength(cursor: &cursor)
            output = try decodeTightImage(cursor.readExact(length), width: width, height: height)
        case .basic(let usesZlib, let basicControl):
            output = try decodeTightBasic(
                width: width,
                height: height,
                control: basicControl,
                usesZlib: usesZlib,
                state: state,
                cursor: &cursor
            )
        }

        guard cursor.isAtEnd else {
            throw RFBError.protocolError("Extra Tight rectangle data")
        }
        return output
    }

    private static func validateZRLEPixelFormat(_ pixelFormat: RFBPixelFormat) throws {
        guard pixelFormat.bitsPerPixel == 32,
              pixelFormat.depth == 24,
              pixelFormat.bigEndian == 0,
              pixelFormat.trueColour == 1,
              pixelFormat.redMax == 255,
              pixelFormat.greenMax == 255,
              pixelFormat.blueMax == 255,
              pixelFormat.redShift == 16,
              pixelFormat.greenShift == 8,
              pixelFormat.blueShift == 0 else {
            throw RFBError.protocolError("ZRLE currently supports Screen Q's negotiated little-endian XRGB32 format only")
        }
    }

    private static func processTightControl(
        _ control: UInt8,
        isTightPNG: Bool,
        state: TightDecodeState
    ) throws -> TightMode {
        for streamID in 0..<4 where control & UInt8(1 << streamID) != 0 {
            state.resetStream(streamID)
        }

        let subencoding = control >> 4
        if subencoding == tightFill {
            return .fill
        }
        if subencoding == tightJPEG {
            return .jpeg
        }
        if isTightPNG {
            if subencoding == tightPNG {
                return .png
            }
            throw RFBError.protocolError("TightPNG rectangle used non-PNG basic compression")
        }
        if subencoding == tightNoZlib || subencoding == tightNoZlibExplicitFilter {
            return .basic(usesZlib: false, control: subencoding & ~tightNoZlib)
        }
        if subencoding & tightFill == 0 {
            return .basic(usesZlib: true, control: subencoding)
        }
        throw RFBError.protocolError("Invalid Tight subencoding: \(subencoding)")
    }

    private static func decodeTightBasic(
        width: UInt16,
        height: UInt16,
        control: UInt8,
        usesZlib: Bool,
        state: TightDecodeState,
        read: (Int) async throws -> Data
    ) async throws -> Data {
        let filter = try await readTightFilter(control: control, read: read)
        let dataSize = try tightFilteredDataSize(width: width, height: height, filter: filter)
        let filteredData: Data

        if dataSize == 0 {
            filteredData = Data()
        } else if dataSize < tightMinToCompress {
            filteredData = try await read(dataSize)
        } else if usesZlib {
            let compressedLength = try await readTightCompactLength(read: read)
            let compressed = try await read(compressedLength)
            filteredData = try state.inflate(streamID: Int(control & 0x03), compressed: compressed, expectedByteCount: dataSize)
        } else {
            let length = try await readTightCompactLength(read: read)
            filteredData = try await read(length)
            guard filteredData.count == dataSize else {
                throw RFBError.protocolError("Unexpected uncompressed Tight payload size: \(filteredData.count), expected \(dataSize)")
            }
        }

        return try decodeTightFilteredData(width: width, height: height, filter: filter, data: filteredData)
    }

    private static func decodeTightBasic(
        width: UInt16,
        height: UInt16,
        control: UInt8,
        usesZlib: Bool,
        state: TightDecodeState,
        cursor: inout ByteCursor
    ) throws -> Data {
        let filter = try readTightFilter(control: control, cursor: &cursor)
        let dataSize = try tightFilteredDataSize(width: width, height: height, filter: filter)
        let filteredData: Data

        if dataSize == 0 {
            filteredData = Data()
        } else if dataSize < tightMinToCompress {
            filteredData = try cursor.readExact(dataSize)
        } else if usesZlib {
            let compressedLength = try readTightCompactLength(cursor: &cursor)
            let compressed = try cursor.readExact(compressedLength)
            filteredData = try state.inflate(streamID: Int(control & 0x03), compressed: compressed, expectedByteCount: dataSize)
        } else {
            let length = try readTightCompactLength(cursor: &cursor)
            filteredData = try cursor.readExact(length)
            guard filteredData.count == dataSize else {
                throw RFBError.protocolError("Unexpected uncompressed Tight payload size: \(filteredData.count), expected \(dataSize)")
            }
        }

        return try decodeTightFilteredData(width: width, height: height, filter: filter, data: filteredData)
    }

    private static func readTightFilter(
        control: UInt8,
        read: (Int) async throws -> Data
    ) async throws -> TightFilter {
        guard control & tightExplicitFilter != 0 else { return .copy }
        let filterData = try await read(1)
        guard let filterID = filterData.first else { throw RFBError.disconnected }
        switch filterID {
        case tightFilterCopy:
            return .copy
        case tightFilterPalette:
            let countData = try await read(1)
            guard let countByte = countData.first else { throw RFBError.disconnected }
            let colorCount = Int(countByte) + 1
            guard colorCount >= 2 else {
                throw RFBError.protocolError("Invalid Tight palette size: \(colorCount)")
            }
            let paletteData = try await read(colorCount * 3)
            return .palette(try parseTightPalette(paletteData, colorCount: colorCount))
        case tightFilterGradient:
            return .gradient
        default:
            throw RFBError.protocolError("Unknown Tight filter id: \(filterID)")
        }
    }

    private static func readTightFilter(control: UInt8, cursor: inout ByteCursor) throws -> TightFilter {
        guard control & tightExplicitFilter != 0 else { return .copy }
        let filterID = try cursor.readUInt8()
        switch filterID {
        case tightFilterCopy:
            return .copy
        case tightFilterPalette:
            let colorCount = Int(try cursor.readUInt8()) + 1
            guard colorCount >= 2 else {
                throw RFBError.protocolError("Invalid Tight palette size: \(colorCount)")
            }
            return .palette(try parseTightPalette(try cursor.readExact(colorCount * 3), colorCount: colorCount))
        case tightFilterGradient:
            return .gradient
        default:
            throw RFBError.protocolError("Unknown Tight filter id: \(filterID)")
        }
    }

    private static func tightFilteredDataSize(width: UInt16, height: UInt16, filter: TightFilter) throws -> Int {
        let rectWidth = Int(width)
        let rectHeight = Int(height)
        let rowSize: Int
        switch filter {
        case .copy, .gradient:
            rowSize = rectWidth * 3
        case .palette(let palette):
            rowSize = palette.count == 2 ? (rectWidth + 7) / 8 : rectWidth
        }
        let dataSize = rowSize * rectHeight
        guard dataSize <= maxDecodedRectBytes else {
            throw RFBError.protocolError("Tight rectangle payload too large: \(width)x\(height)")
        }
        return dataSize
    }

    private static func decodeTightFilteredData(width: UInt16, height: UInt16, filter: TightFilter, data: Data) throws -> Data {
        switch filter {
        case .copy:
            return try decodeTightCopy(width: width, height: height, data: data)
        case .palette(let palette):
            return try decodeTightPalette(width: width, height: height, palette: palette, data: data)
        case .gradient:
            return try decodeTightGradient(width: width, height: height, data: data)
        }
    }

    private static func decodeTightCopy(width: UInt16, height: UInt16, data: Data) throws -> Data {
        let rectWidth = Int(width)
        let rectHeight = Int(height)
        let expectedCount = rectWidth * rectHeight * 3
        guard data.count >= expectedCount else {
            throw RFBError.protocolError("Truncated Tight copy-filter data")
        }
        var output = Data(count: try decodedByteCount(width: width, height: height))
        let bytes = Array(data)
        var inputOffset = 0
        for y in 0..<rectHeight {
            for x in 0..<rectWidth {
                let pixel = XRGBPixel(red: bytes[inputOffset], green: bytes[inputOffset + 1], blue: bytes[inputOffset + 2])
                writePixel(pixel, tileX: x, tileY: y, rectWidth: rectWidth, output: &output)
                inputOffset += 3
            }
        }
        return output
    }

    private static func decodeTightPalette(width: UInt16, height: UInt16, palette: [XRGBPixel], data: Data) throws -> Data {
        let rectWidth = Int(width)
        let rectHeight = Int(height)
        var output = Data(count: try decodedByteCount(width: width, height: height))
        let bytes = Array(data)

        if palette.count == 2 {
            let rowSize = (rectWidth + 7) / 8
            guard bytes.count >= rowSize * rectHeight else {
                throw RFBError.protocolError("Truncated Tight 1-bit palette data")
            }
            for y in 0..<rectHeight {
                for x in 0..<rectWidth {
                    let byte = bytes[y * rowSize + x / 8]
                    let bit = 7 - (x % 8)
                    let index = Int((byte >> UInt8(bit)) & 1)
                    writePixel(palette[index], tileX: x, tileY: y, rectWidth: rectWidth, output: &output)
                }
            }
        } else {
            guard bytes.count >= rectWidth * rectHeight else {
                throw RFBError.protocolError("Truncated Tight palette data")
            }
            for y in 0..<rectHeight {
                for x in 0..<rectWidth {
                    let index = Int(bytes[y * rectWidth + x])
                    guard index < palette.count else {
                        throw RFBError.protocolError("Tight palette index out of bounds")
                    }
                    writePixel(palette[index], tileX: x, tileY: y, rectWidth: rectWidth, output: &output)
                }
            }
        }

        return output
    }

    private static func decodeTightGradient(width: UInt16, height: UInt16, data: Data) throws -> Data {
        let rectWidth = Int(width)
        let rectHeight = Int(height)
        let expectedCount = rectWidth * rectHeight * 3
        guard data.count >= expectedCount else {
            throw RFBError.protocolError("Truncated Tight gradient data")
        }
        let bytes = Array(data)
        var output = Data(count: try decodedByteCount(width: width, height: height))
        var previousRow = Array(repeating: 0, count: rectWidth * 3)
        var currentRow = Array(repeating: 0, count: rectWidth * 3)
        var inputOffset = 0

        for y in 0..<rectHeight {
            var left = [0, 0, 0]
            for x in 0..<rectWidth {
                var rgb = [0, 0, 0]
                for component in 0..<3 {
                    let above = previousRow[x * 3 + component]
                    let aboveLeft = x == 0 ? 0 : previousRow[(x - 1) * 3 + component]
                    let prediction = x == 0 ? above : min(255, max(0, above + left[component] - aboveLeft))
                    let value = (Int(bytes[inputOffset]) + prediction) & 0xFF
                    rgb[component] = value
                    currentRow[x * 3 + component] = value
                    inputOffset += 1
                }
                left = rgb
                writePixel(
                    XRGBPixel(red: UInt8(rgb[0]), green: UInt8(rgb[1]), blue: UInt8(rgb[2])),
                    tileX: x,
                    tileY: y,
                    rectWidth: rectWidth,
                    output: &output
                )
            }
            previousRow = currentRow
        }

        return output
    }

    private static func parseTightPalette(_ data: Data, colorCount: Int) throws -> [XRGBPixel] {
        guard data.count >= colorCount * 3 else {
            throw RFBError.protocolError("Truncated Tight palette")
        }
        let bytes = Array(data)
        var palette: [XRGBPixel] = []
        palette.reserveCapacity(colorCount)
        for index in 0..<colorCount {
            let offset = index * 3
            palette.append(XRGBPixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2]))
        }
        return palette
    }

    private static func makeTightFill(width: UInt16, height: UInt16, rgb: Data) throws -> Data {
        guard rgb.count >= 3 else {
            throw RFBError.protocolError("Truncated Tight fill colour")
        }
        let bytes = Array(rgb)
        let pixel = XRGBPixel(red: bytes[0], green: bytes[1], blue: bytes[2])
        let rectWidth = Int(width)
        let rectHeight = Int(height)
        var output = Data(count: try decodedByteCount(width: width, height: height))
        fillRect(tileX: 0, tileY: 0, width: rectWidth, height: rectHeight, pixel: pixel, rectWidth: rectWidth, into: &output)
        return output
    }

    private static func decodeTightImage(_ imageData: Data, width: UInt16, height: UInt16) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RFBError.protocolError("Unable to decode Tight image payload")
        }

        let rectWidth = Int(width)
        let rectHeight = Int(height)
        let bitmapInfos = [
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ]

        for bitmapInfo in bitmapInfos {
            var output = Data(count: try decodedByteCount(width: width, height: height))
            let didDraw = output.withUnsafeMutableBytes { rawBuffer -> Bool in
                guard let baseAddress = rawBuffer.baseAddress,
                      let context = CGContext(
                        data: baseAddress,
                        width: rectWidth,
                        height: rectHeight,
                        bitsPerComponent: 8,
                        bytesPerRow: rectWidth * bytesPerPixel,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: bitmapInfo
                      ) else {
                    return false
                }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: rectWidth, height: rectHeight))
                return true
            }
            if didDraw {
                for index in stride(from: 3, to: output.count, by: bytesPerPixel) {
                    output[index] = 0
                }
                return output
            }
        }

        throw RFBError.protocolError("Unable to create Tight image decode context")
    }

    private static func readTightCompactLength(read: (Int) async throws -> Data) async throws -> Int {
        let firstData = try await read(1)
        guard let first = firstData.first else { throw RFBError.disconnected }
        var value = Int(first & 0x7F)
        if first & 0x80 != 0 {
            let secondData = try await read(1)
            guard let second = secondData.first else { throw RFBError.disconnected }
            value |= Int(second & 0x7F) << 7
            if second & 0x80 != 0 {
                let thirdData = try await read(1)
                guard let third = thirdData.first else { throw RFBError.disconnected }
                value |= Int(third) << 14
            }
        }
        guard value <= maxDecodedRectBytes else {
            throw RFBError.protocolError("Tight compact length too large: \(value)")
        }
        return value
    }

    private static func readTightCompactLength(cursor: inout ByteCursor) throws -> Int {
        let first = try cursor.readUInt8()
        var value = Int(first & 0x7F)
        if first & 0x80 != 0 {
            let second = try cursor.readUInt8()
            value |= Int(second & 0x7F) << 7
            if second & 0x80 != 0 {
                value |= Int(try cursor.readUInt8()) << 14
            }
        }
        guard value <= maxDecodedRectBytes else {
            throw RFBError.protocolError("Tight compact length too large: \(value)")
        }
        return value
    }

    private static func inflateZRLE(
        _ compressed: Data,
        width: UInt16,
        height: UInt16,
        outputByteCount: Int
    ) throws -> Data {
        guard !compressed.isEmpty else {
            throw RFBError.protocolError("Empty ZRLE rectangle")
        }
        let tileColumns = (Int(width) + 63) / 64
        let tileRows = (Int(height) + 63) / 64
        let tileCount = tileColumns * tileRows
        let minimumCapacity = max(1024, outputByteCount)
        let overhead = min(maxDecodedRectBytes - minimumCapacity, tileCount * 512 + 1024)
        let maxInflatedBytes = minimumCapacity + max(0, overhead)
        var capacity = minimumCapacity
        let source = Array(compressed)

        while capacity <= maxInflatedBytes {
            var destination = [UInt8](repeating: 0, count: capacity)
            let decodedCount = source.withUnsafeBufferPointer { sourcePtr in
                destination.withUnsafeMutableBufferPointer { destinationPtr in
                    compression_decode_buffer(
                        destinationPtr.baseAddress!,
                        destinationPtr.count,
                        sourcePtr.baseAddress!,
                        sourcePtr.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            if decodedCount > 0 {
                return Data(destination.prefix(decodedCount))
            }

            if capacity == maxInflatedBytes {
                break
            }
            capacity = min(maxInflatedBytes, capacity * 2)
        }

        throw RFBError.protocolError("Unable to inflate ZRLE rectangle")
    }

    private static func decodeRawZRLETile(
        cursor: inout ByteCursor,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int,
        rectWidth: Int,
        output: inout Data
    ) throws {
        for row in 0..<tileHeight {
            for column in 0..<tileWidth {
                let pixel = try cursor.readPixel()
                writePixel(
                    pixel,
                    tileX: tileX + column,
                    tileY: tileY + row,
                    rectWidth: rectWidth,
                    output: &output
                )
            }
        }
    }

    private static func decodePackedPaletteTile(
        cursor: inout ByteCursor,
        palette: [XRGBPixel],
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int,
        rectWidth: Int,
        output: inout Data
    ) throws {
        let bitsPerIndex: Int
        switch palette.count {
        case 2:
            bitsPerIndex = 1
        case 3...4:
            bitsPerIndex = 2
        case 5...16:
            bitsPerIndex = 4
        default:
            throw RFBError.protocolError("Invalid ZRLE packed palette size: \(palette.count)")
        }

        let mask = UInt8((1 << bitsPerIndex) - 1)
        for row in 0..<tileHeight {
            var bitsRemaining = 0
            var currentByte: UInt8 = 0
            for column in 0..<tileWidth {
                if bitsRemaining == 0 {
                    currentByte = try cursor.readUInt8()
                    bitsRemaining = 8
                }

                bitsRemaining -= bitsPerIndex
                let index = Int((currentByte >> UInt8(bitsRemaining)) & mask)
                guard index < palette.count else {
                    throw RFBError.protocolError("ZRLE palette index out of bounds")
                }
                writePixel(
                    palette[index],
                    tileX: tileX + column,
                    tileY: tileY + row,
                    rectWidth: rectWidth,
                    output: &output
                )
            }
        }
    }

    private static func decodePlainRLETile(
        cursor: inout ByteCursor,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int,
        rectWidth: Int,
        output: inout Data
    ) throws {
        let totalPixels = tileWidth * tileHeight
        var pixelIndex = 0

        while pixelIndex < totalPixels {
            let pixel = try cursor.readPixel()
            let runLength = try cursor.readRunLength()
            try writeRun(
                pixel,
                runLength: runLength,
                pixelIndex: &pixelIndex,
                totalPixels: totalPixels,
                tileX: tileX,
                tileY: tileY,
                tileWidth: tileWidth,
                rectWidth: rectWidth,
                output: &output
            )
        }
    }

    private static func decodePaletteRLETile(
        cursor: inout ByteCursor,
        palette: [XRGBPixel],
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int,
        rectWidth: Int,
        output: inout Data
    ) throws {
        let totalPixels = tileWidth * tileHeight
        var pixelIndex = 0

        while pixelIndex < totalPixels {
            let header = try cursor.readUInt8()
            let index = Int(header & 0x7F)
            guard index < palette.count else {
                throw RFBError.protocolError("ZRLE palette RLE index out of bounds")
            }

            let runLength = header & 0x80 == 0 ? 1 : try cursor.readRunLength()
            try writeRun(
                palette[index],
                runLength: runLength,
                pixelIndex: &pixelIndex,
                totalPixels: totalPixels,
                tileX: tileX,
                tileY: tileY,
                tileWidth: tileWidth,
                rectWidth: rectWidth,
                output: &output
            )
        }
    }

    private static func writeRun(
        _ pixel: XRGBPixel,
        runLength: Int,
        pixelIndex: inout Int,
        totalPixels: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        rectWidth: Int,
        output: inout Data
    ) throws {
        guard runLength > 0, pixelIndex + runLength <= totalPixels else {
            throw RFBError.protocolError("ZRLE run length exceeds tile bounds")
        }

        for offset in 0..<runLength {
            let linear = pixelIndex + offset
            let row = linear / tileWidth
            let column = linear % tileWidth
            writePixel(
                pixel,
                tileX: tileX + column,
                tileY: tileY + row,
                rectWidth: rectWidth,
                output: &output
            )
        }
        pixelIndex += runLength
    }

    private static func copyTile(
        _ tile: Data,
        tileWidth: Int,
        tileHeight: Int,
        tileX: Int,
        tileY: Int,
        rectWidth: Int,
        into output: inout Data
    ) {
        let rowBytes = tileWidth * bytesPerPixel
        for row in 0..<tileHeight {
            let sourceStart = row * rowBytes
            let destinationStart = ((tileY + row) * rectWidth + tileX) * bytesPerPixel
            output.replaceSubrange(
                destinationStart..<(destinationStart + rowBytes),
                with: tile[sourceStart..<(sourceStart + rowBytes)]
            )
        }
    }

    private static func fillRect(
        tileX: Int,
        tileY: Int,
        width: Int,
        height: Int,
        color: Data,
        rectWidth: Int,
        into output: inout Data
    ) {
        for row in tileY..<(tileY + height) {
            for column in tileX..<(tileX + width) {
                let start = (row * rectWidth + column) * bytesPerPixel
                output.replaceSubrange(start..<(start + bytesPerPixel), with: color)
            }
        }
    }

    private static func fillRect(
        tileX: Int,
        tileY: Int,
        width: Int,
        height: Int,
        pixel: XRGBPixel,
        rectWidth: Int,
        into output: inout Data
    ) {
        for row in tileY..<(tileY + height) {
            for column in tileX..<(tileX + width) {
                writePixel(pixel, tileX: column, tileY: row, rectWidth: rectWidth, output: &output)
            }
        }
    }

    private static func writePixel(
        _ pixel: XRGBPixel,
        tileX: Int,
        tileY: Int,
        rectWidth: Int,
        output: inout Data
    ) {
        let start = (tileY * rectWidth + tileX) * bytesPerPixel
        output[start] = pixel.blue
        output[start + 1] = pixel.green
        output[start + 2] = pixel.red
        output[start + 3] = pixel.padding
    }
}

private nonisolated enum TightMode {
    case fill
    case jpeg
    case png
    case basic(usesZlib: Bool, control: UInt8)
}

private nonisolated enum TightFilter {
    case copy
    case palette([XRGBPixel])
    case gradient
}

private nonisolated final class TightInflateStream {
    private let dummySource: UnsafeMutablePointer<UInt8>
    private let dummyDestination: UnsafeMutablePointer<UInt8>
    private var stream: compression_stream
    private var isInitialized = false

    init() {
        dummySource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        dummyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        dummySource.initialize(to: 0)
        dummyDestination.initialize(to: 0)
        stream = compression_stream(
            dst_ptr: dummyDestination,
            dst_size: 0,
            src_ptr: UnsafePointer(dummySource),
            src_size: 0,
            state: nil
        )
    }

    deinit {
        reset()
        dummySource.deinitialize(count: 1)
        dummyDestination.deinitialize(count: 1)
        dummySource.deallocate()
        dummyDestination.deallocate()
    }

    func reset() {
        if isInitialized {
            compression_stream_destroy(&stream)
            isInitialized = false
        }
        stream = compression_stream(
            dst_ptr: dummyDestination,
            dst_size: 0,
            src_ptr: UnsafePointer(dummySource),
            src_size: 0,
            state: nil
        )
    }

    func inflate(_ compressed: Data, expectedByteCount: Int) throws -> Data {
        guard expectedByteCount > 0 else { return Data() }
        guard !compressed.isEmpty else {
            throw RFBError.protocolError("Empty Tight zlib payload")
        }
        try ensureInitialized()

        let input = Array(compressed)
        var output = [UInt8](repeating: 0, count: expectedByteCount)
        var scratch = [UInt8](repeating: 0, count: 64)
        var produced = 0
        var reachedEnd = false

        try input.withUnsafeBufferPointer { inputBuffer in
            guard let inputBase = inputBuffer.baseAddress else {
                throw RFBError.protocolError("Empty Tight zlib input")
            }
            stream.src_ptr = inputBase
            stream.src_size = inputBuffer.count

            while stream.src_size > 0 || produced < expectedByteCount {
                let priorSourceSize = stream.src_size
                var wrote = 0
                let status: compression_status

                if produced < expectedByteCount {
                    status = output.withUnsafeMutableBufferPointer { outputBuffer in
                        let available = expectedByteCount - produced
                        stream.dst_ptr = outputBuffer.baseAddress!.advanced(by: produced)
                        stream.dst_size = available
                        let result = compression_stream_process(&stream, 0)
                        wrote = available - stream.dst_size
                        return result
                    }
                    produced += wrote
                } else {
                    status = scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                        stream.dst_ptr = scratchBuffer.baseAddress!
                        stream.dst_size = scratchBuffer.count
                        let result = compression_stream_process(&stream, 0)
                        wrote = scratchBuffer.count - stream.dst_size
                        return result
                    }
                    if wrote > 0 {
                        throw RFBError.protocolError("Tight zlib stream produced more data than expected")
                    }
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    if wrote == 0 && stream.src_size == priorSourceSize {
                        throw RFBError.protocolError("Tight zlib stream made no progress")
                    }
                case COMPRESSION_STATUS_END:
                    reachedEnd = true
                    break
                default:
                    throw RFBError.protocolError("Unable to inflate Tight rectangle")
                }

                if reachedEnd {
                    break
                }
            }
        }

        guard produced == expectedByteCount else {
            throw RFBError.protocolError("Tight zlib decoded \(produced) bytes, expected \(expectedByteCount)")
        }
        guard stream.src_size == 0 else {
            throw RFBError.protocolError("Tight zlib payload was not fully consumed")
        }

        if reachedEnd {
            reset()
        }

        return Data(output)
    }

    private func ensureInitialized() throws {
        guard !isInitialized else { return }
        let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw RFBError.protocolError("Unable to initialize Tight zlib stream")
        }
        isInitialized = true
    }
}

private nonisolated struct XRGBPixel {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
    let padding: UInt8

    init(blue: UInt8, green: UInt8, red: UInt8, padding: UInt8 = 0) {
        self.blue = blue
        self.green = green
        self.red = red
        self.padding = padding
    }

    init(red: UInt8, green: UInt8, blue: UInt8, padding: UInt8 = 0) {
        self.blue = blue
        self.green = green
        self.red = red
        self.padding = padding
    }
}

private nonisolated struct ByteCursor {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else {
            throw RFBError.protocolError("Truncated RFB encoding data")
        }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func readExact(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= bytes.count else {
            throw RFBError.protocolError("Truncated RFB encoding data")
        }
        let start = offset
        offset += count
        return Data(bytes[start..<offset])
    }

    mutating func readPixel() throws -> XRGBPixel {
        let blue = try readUInt8()
        let green = try readUInt8()
        let red = try readUInt8()
        return XRGBPixel(blue: blue, green: green, red: red, padding: 0)
    }

    mutating func readPixels(_ count: Int) throws -> [XRGBPixel] {
        var pixels: [XRGBPixel] = []
        pixels.reserveCapacity(count)
        for _ in 0..<count {
            pixels.append(try readPixel())
        }
        return pixels
    }

    mutating func readRunLength() throws -> Int {
        var runLength = 1
        while true {
            let byte = try readUInt8()
            runLength += Int(byte)
            if byte != 255 {
                return runLength
            }
        }
    }
}
