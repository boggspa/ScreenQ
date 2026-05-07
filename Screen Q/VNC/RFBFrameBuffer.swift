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
    private static let bytesPerPixel = 4
    #if os(iOS)
    private static let maxBackingBytes = 128 * 1024 * 1024
    #else
    private static let maxBackingBytes = 512 * 1024 * 1024
    #endif

    private(set) var width: Int
    private(set) var height: Int
    private(set) var originX: Int
    private(set) var originY: Int
    private var pixels: Data // 32bpp XRGB, row-major
    private let lock = NSLock()
    private(set) var dirtyRegion = DirtyRegion()

    init(width: Int, height: Int, originX: Int = 0, originY: Int = 0) {
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        self.pixels = Data(count: Self.validatedByteCount(width: width, height: height) ?? 0)
        if pixels.isEmpty {
            self.width = 0
            self.height = 0
        }
    }

    // MARK: - Apply updates

    func apply(_ rects: [RFBRect]) {
        lock.lock()
        defer { lock.unlock() }
        for rect in rects {
            switch rect.encoding {
            case RFBEncoding.raw.rawValue:
                applyRaw(rect)
                trackDirty(rect)
            case RFBEncoding.copyRect.rawValue:
                applyCopyRect(rect)
                trackDirty(rect)
            default:
                break
            }
        }
    }

    private func trackDirty(_ rect: RFBRect) {
        let rx = max(0, Int(rect.x) - originX)
        let ry = max(0, Int(rect.y) - originY)
        let rw = min(Int(rect.width), width - rx)
        let rh = min(Int(rect.height), height - ry)
        guard rw > 0, rh > 0 else { return }
        dirtyRegion.add(x: rx, y: ry, width: rw, height: rh)
    }

    func resize(width: Int, height: Int, originX: Int = 0, originY: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        dirtyRegion.addFullFrame(width: width, height: height)
        guard let byteCount = Self.validatedByteCount(width: width, height: height) else {
            self.width = 0
            self.height = 0
            self.pixels = Data()
            return
        }
        if pixels.count == byteCount {
            pixels.resetBytes(in: pixels.startIndex..<pixels.endIndex)
        } else {
            self.pixels = Data(count: byteCount)
        }
    }

    // MARK: - Metal upload

    /// Upload pixel data to a MetalFrameBufferRenderer, using only the
    /// dirty region when available. Returns true if an upload was made.
    @discardableResult
    func uploadToMetal(_ renderer: MetalFrameBufferRenderer) -> Bool {
        lock.lock()
        let w = width
        let h = height
        guard w > 0, h > 0,
              let byteCount = Self.validatedByteCount(width: w, height: h),
              pixels.count == byteCount,
              dirtyRegion.isDirty else {
            lock.unlock()
            return false
        }
        let dirty = dirtyRegion
        dirtyRegion.reset()
        let bytesPerRow = w * Self.bytesPerPixel
        pixels.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else {
                lock.unlock()
                return
            }
            renderer.uploadPixels(base, width: w, height: h, bytesPerRow: bytesPerRow, dirtyRegion: dirty)
        }
        lock.unlock()
        return true
    }

    // MARK: - CGImage output

    func makeCGImage(maxDimension: Int? = nil) -> CGImage? {
        lock.lock()
        let w = width
        let h = height
        guard w > 0 && h > 0,
              let byteCount = Self.validatedByteCount(width: w, height: h),
              pixels.count == byteCount else {
            lock.unlock()
            return nil
        }

        let bitmapInfo = Self.bitmapInfo
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let maxDimension,
           maxDimension > 0,
           max(w, h) > maxDimension,
           let scaled = makeScaledCGImageLocked(
                width: w,
                height: h,
                maxDimension: maxDimension,
                bitmapInfo: bitmapInfo,
                colorSpace: colorSpace
           ) {
            lock.unlock()
            return scaled
        }

        let snapshot = pixels
        lock.unlock()

        guard let provider = CGDataProvider(data: snapshot as CFData) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - Private: Raw encoding

    private func applyRaw(_ rect: RFBRect) {
        let rx = Int(rect.x) - originX
        let ry = Int(rect.y) - originY
        let rw = Int(rect.width)
        let rh = Int(rect.height)
        let stride = width * Self.bytesPerPixel
        let srcStride = rw * Self.bytesPerPixel

        guard rw > 0, rh > 0,
              rect.data.count >= rw * rh * Self.bytesPerPixel else { return }

        let srcStartX = max(0, -rx)
        let srcStartY = max(0, -ry)
        let dstStartX = max(0, rx)
        let dstStartY = max(0, ry)
        let copyWidth = min(rw - srcStartX, width - dstStartX)
        let copyHeight = min(rh - srcStartY, height - dstStartY)
        guard copyWidth > 0, copyHeight > 0 else { return }
        let pixelByteCount = pixels.count
        let rectDataByteCount = rect.data.count

        pixels.withUnsafeMutableBytes { dstRaw in
            rect.data.withUnsafeBytes { srcRaw in
                guard let dstBase = dstRaw.baseAddress,
                      let srcBase = srcRaw.baseAddress else {
                    return
                }

                for row in 0..<copyHeight {
                    let dstY = dstStartY + row
                    let srcY = srcStartY + row
                    let dstOffset = dstY * stride + dstStartX * Self.bytesPerPixel
                    let srcOffset = srcY * srcStride + srcStartX * Self.bytesPerPixel
                    let copyLen = copyWidth * Self.bytesPerPixel
                    guard dstOffset + copyLen <= pixelByteCount,
                          srcOffset + copyLen <= rectDataByteCount else { continue }

                    dstBase
                        .advanced(by: dstOffset)
                        .copyMemory(from: srcBase.advanced(by: srcOffset), byteCount: copyLen)
                }
            }
        }
    }

    // MARK: - Private: CopyRect encoding

    private func applyCopyRect(_ rect: RFBRect) {
        guard rect.data.count >= 4 else { return }
        let srcX = Int(UInt16(rect.data[0]) << 8 | UInt16(rect.data[1])) - originX
        let srcY = Int(UInt16(rect.data[2]) << 8 | UInt16(rect.data[3])) - originY
        let rw = Int(rect.width)
        let rh = Int(rect.height)
        let dstX = Int(rect.x) - originX
        let dstY = Int(rect.y) - originY
        let stride = width * Self.bytesPerPixel
        guard rw > 0, rh > 0,
              srcX >= 0, srcY >= 0, dstX >= 0, dstY >= 0,
              srcX + rw <= width, srcY + rh <= height,
              dstX + rw <= width, dstY + rh <= height else {
            return
        }

        // Copy to temp buffer to handle overlapping regions.
        guard let tmpByteCount = Self.validatedByteCount(width: rw, height: rh) else { return }
        var tmp = Data(count: tmpByteCount)
        let pixelByteCount = pixels.count
        tmp.withUnsafeMutableBytes { tmpRaw in
            pixels.withUnsafeBytes { srcRaw in
                guard let tmpBase = tmpRaw.baseAddress,
                      let srcBase = srcRaw.baseAddress else {
                    return
                }

                for row in 0..<rh {
                    let sy = srcY + row
                    guard sy < height else { continue }
                    let srcOff = sy * stride + srcX * Self.bytesPerPixel
                    let tmpOff = row * rw * Self.bytesPerPixel
                    let copyLen = min(rw * Self.bytesPerPixel, (width - srcX) * Self.bytesPerPixel)
                    guard srcOff + copyLen <= pixelByteCount,
                          tmpOff + copyLen <= tmpByteCount else { continue }

                    tmpBase
                        .advanced(by: tmpOff)
                        .copyMemory(from: srcBase.advanced(by: srcOff), byteCount: copyLen)
                }
            }
        }

        pixels.withUnsafeMutableBytes { dstRaw in
            tmp.withUnsafeBytes { tmpRaw in
                guard let dstBase = dstRaw.baseAddress,
                      let tmpBase = tmpRaw.baseAddress else {
                    return
                }

                for row in 0..<rh {
                    let dy = dstY + row
                    guard dy < height else { continue }
                    let dstOff = dy * stride + dstX * Self.bytesPerPixel
                    let tmpOff = row * rw * Self.bytesPerPixel
                    let copyLen = min(rw * Self.bytesPerPixel, (width - dstX) * Self.bytesPerPixel)
                    guard dstOff + copyLen <= pixelByteCount,
                          tmpOff + copyLen <= tmpByteCount else { continue }

                    dstBase
                        .advanced(by: dstOff)
                        .copyMemory(from: tmpBase.advanced(by: tmpOff), byteCount: copyLen)
                }
            }
        }
    }

    private static var bitmapInfo: CGBitmapInfo {
        CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func validatedByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let pixelProduct = width.multipliedReportingOverflow(by: height)
        guard !pixelProduct.overflow else { return nil }
        let byteProduct = pixelProduct.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
        guard !byteProduct.overflow,
              byteProduct.partialValue <= maxBackingBytes else {
            return nil
        }
        return byteProduct.partialValue
    }

    private func makeScaledCGImageLocked(
        width sourceWidth: Int,
        height sourceHeight: Int,
        maxDimension: Int,
        bitmapInfo: CGBitmapInfo,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        let scale = CGFloat(maxDimension) / CGFloat(max(sourceWidth, sourceHeight))
        let scaledWidth = max(1, Int((CGFloat(sourceWidth) * scale).rounded(.down)))
        let scaledHeight = max(1, Int((CGFloat(sourceHeight) * scale).rounded(.down)))

        // Build full-res CGImage from current pixels (lock already held).
        let snapshot = pixels
        guard let provider = CGDataProvider(data: snapshot as CFData) else { return nil }
        guard let sourceImage = CGImage(
            width: sourceWidth,
            height: sourceHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: sourceWidth * Self.bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        // Use Core Graphics high-quality interpolation for downscaling.
        let scaledBytesPerRow = scaledWidth * Self.bytesPerPixel
        guard let ctx = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: scaledBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(sourceImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        return ctx.makeImage()
    }
}
