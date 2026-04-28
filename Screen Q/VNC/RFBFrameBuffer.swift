//
//  RFBFrameBuffer.swift
//  Screen Q
//
//  Maintains an in-memory RGBA pixel buffer that receives incremental
//  updates from the RFB server and produces CGImage snapshots for display.
//

import Foundation
import CoreGraphics

final class RFBFrameBuffer: @unchecked Sendable {

    private(set) var width: Int
    private(set) var height: Int
    private var pixels: Data // 32bpp XRGB, row-major
    private let lock = NSLock()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = Data(count: width * height * 4)
    }

    // MARK: - Apply updates

    func apply(_ rects: [RFBRect]) {
        lock.lock()
        defer { lock.unlock() }
        for rect in rects {
            switch rect.encoding {
            case RFBEncoding.raw.rawValue:
                applyRaw(rect)
            case RFBEncoding.copyRect.rawValue:
                applyCopyRect(rect)
            default:
                break
            }
        }
    }

    func resize(width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.width = width
        self.height = height
        self.pixels = Data(count: width * height * 4)
    }

    // MARK: - CGImage output

    func makeCGImage() -> CGImage? {
        lock.lock()
        let snapshot = pixels
        let w = width
        let h = height
        lock.unlock()

        guard w > 0 && h > 0 else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: snapshot as CFData) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Private: Raw encoding

    private func applyRaw(_ rect: RFBRect) {
        let rx = Int(rect.x)
        let ry = Int(rect.y)
        let rw = Int(rect.width)
        let rh = Int(rect.height)
        let stride = width * 4
        let srcStride = rw * 4

        guard rect.data.count >= rw * rh * 4 else { return }

        for row in 0..<rh {
            let dstY = ry + row
            guard dstY < height else { continue }
            let dstOffset = dstY * stride + rx * 4
            let srcOffset = row * srcStride
            let copyLen = min(srcStride, (width - rx) * 4)
            guard dstOffset + copyLen <= pixels.count,
                  srcOffset + copyLen <= rect.data.count else { continue }

            pixels.replaceSubrange(dstOffset..<(dstOffset + copyLen),
                                   with: rect.data[srcOffset..<(srcOffset + copyLen)])
        }
    }

    // MARK: - Private: CopyRect encoding

    private func applyCopyRect(_ rect: RFBRect) {
        guard rect.data.count >= 4 else { return }
        let srcX = Int(UInt16(rect.data[0]) << 8 | UInt16(rect.data[1]))
        let srcY = Int(UInt16(rect.data[2]) << 8 | UInt16(rect.data[3]))
        let rw = Int(rect.width)
        let rh = Int(rect.height)
        let dstX = Int(rect.x)
        let dstY = Int(rect.y)
        let stride = width * 4

        // Copy to temp buffer to handle overlapping regions.
        var tmp = Data(count: rw * rh * 4)
        for row in 0..<rh {
            let sy = srcY + row
            guard sy < height else { continue }
            let srcOff = sy * stride + srcX * 4
            let tmpOff = row * rw * 4
            let copyLen = min(rw * 4, (width - srcX) * 4)
            guard srcOff + copyLen <= pixels.count else { continue }
            tmp.replaceSubrange(tmpOff..<(tmpOff + copyLen),
                                with: pixels[srcOff..<(srcOff + copyLen)])
        }
        for row in 0..<rh {
            let dy = dstY + row
            guard dy < height else { continue }
            let dstOff = dy * stride + dstX * 4
            let tmpOff = row * rw * 4
            let copyLen = min(rw * 4, (width - dstX) * 4)
            guard dstOff + copyLen <= pixels.count else { continue }
            pixels.replaceSubrange(dstOff..<(dstOff + copyLen),
                                   with: tmp[tmpOff..<(tmpOff + copyLen)])
        }
    }
}
