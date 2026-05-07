//
//  MetalFrameBufferRenderer.swift
//  Screen Q
//
//  GPU-accelerated frame renderer using Metal. Replaces the CPU-side
//  CGImage → SwiftUI Image display path with a CAMetalLayer-backed
//  pipeline for both VNC framebuffer updates and native H.264/JPEG
//  decoded frames. Double-buffered textures avoid tearing; dirty-region
//  uploads minimise bus traffic for incremental VNC updates.
//

import Foundation
import Metal
import MetalKit
import CoreGraphics
import CoreVideo
import QuartzCore

// MARK: - Dirty Region Tracking

nonisolated struct DirtyRegion: Sendable {
    var x: Int = 0
    var y: Int = 0
    var width: Int = 0
    var height: Int = 0
    var isDirty: Bool = false

    mutating func add(x: Int, y: Int, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if !isDirty {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            isDirty = true
        } else {
            let minX = min(self.x, x)
            let minY = min(self.y, y)
            let maxX = max(self.x + self.width, x + width)
            let maxY = max(self.y + self.height, y + height)
            self.x = minX
            self.y = minY
            self.width = maxX - minX
            self.height = maxY - minY
        }
    }

    mutating func addFullFrame(width: Int, height: Int) {
        self.x = 0
        self.y = 0
        self.width = width
        self.height = height
        isDirty = true
    }

    mutating func reset() {
        x = 0
        y = 0
        width = 0
        height = 0
        isDirty = false
    }
}

// MARK: - Metal Renderer

/// Manages Metal textures and renders frames to a CAMetalLayer.
/// Thread-safe for upload calls from any queue; rendering must happen
/// on the main thread (CAMetalLayer requirement).
final class MetalFrameBufferRenderer {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    // Double-buffered textures — upload to back, render from front.
    private var textures: [MTLTexture?] = [nil, nil]
    private var frontIndex = 0
    private var textureWidth = 0
    private var textureHeight = 0
    private let textureLock = NSLock()

    // CVMetalTextureCache for zero-copy CVPixelBuffer → MTLTexture.
    private var textureCache: CVMetalTextureCache?

    private(set) var isAvailable: Bool

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue

        // Build the render pipeline from embedded shader source.
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunc = library.makeFunction(name: "vertexPassthrough"),
              let fragmentFunc = library.makeFunction(name: "fragmentTexture") else {
            return nil
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragmentFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDesc) else {
            return nil
        }
        self.pipelineState = pipeline

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            return nil
        }
        self.sampler = sampler

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache

        self.isAvailable = true
    }

    // MARK: - Texture Management

    /// Ensure textures match the given dimensions. Call when framebuffer size changes.
    func ensureTextureSize(width: Int, height: Int) {
        textureLock.lock()
        defer { textureLock.unlock() }
        guard width != textureWidth || height != textureHeight else { return }
        guard width > 0, height > 0 else {
            textures = [nil, nil]
            textureWidth = 0
            textureHeight = 0
            return
        }
        textureWidth = width
        textureHeight = height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        textures[0] = device.makeTexture(descriptor: desc)
        textures[1] = device.makeTexture(descriptor: desc)
        frontIndex = 0
    }

    // MARK: - Upload: Raw Pixels (VNC framebuffer)

    /// Upload raw BGRA pixels to the back texture, then swap to front.
    /// `dirtyRegion` allows partial upload for incremental VNC updates.
    func uploadPixels(
        _ pointer: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        dirtyRegion: DirtyRegion? = nil
    ) {
        textureLock.lock()
        if width != textureWidth || height != textureHeight {
            textureLock.unlock()
            ensureTextureSize(width: width, height: height)
            textureLock.lock()
        }
        let backIndex = 1 - frontIndex
        guard let texture = textures[backIndex] else {
            textureLock.unlock()
            return
        }

        let region: MTLRegion
        let sourceOffset: Int
        if let dirty = dirtyRegion, dirty.isDirty,
           dirty.x >= 0, dirty.y >= 0,
           dirty.x + dirty.width <= width,
           dirty.y + dirty.height <= height {
            region = MTLRegionMake2D(dirty.x, dirty.y, dirty.width, dirty.height)
            sourceOffset = dirty.y * bytesPerRow + dirty.x * 4
        } else {
            region = MTLRegionMake2D(0, 0, width, height)
            sourceOffset = 0
        }

        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: pointer.advanced(by: sourceOffset),
            bytesPerRow: bytesPerRow
        )

        frontIndex = backIndex
        textureLock.unlock()
    }

    // MARK: - Upload: CGImage

    /// Upload a CGImage (from JPEG decode or H.264 → CIContext).
    func uploadCGImage(_ image: CGImage) {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return }

        let bytesPerRow = w * 4
        let byteCount = bytesPerRow * h
        guard let context = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return }
        uploadPixels(data, width: w, height: h, bytesPerRow: bytesPerRow)
    }

    // MARK: - Upload: CVPixelBuffer (zero-copy when possible)

    /// Upload a CVPixelBuffer directly. Uses CVMetalTextureCache for
    /// zero-copy GPU access when the pixel buffer is IOSurface-backed.
    func uploadPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return }

        // Try zero-copy via texture cache.
        if let cache = textureCache {
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                w,
                h,
                0,
                &cvTexture
            )
            if status == kCVReturnSuccess, let cvTex = cvTexture,
               let metalTexture = CVMetalTextureGetTexture(cvTex) {
                textureLock.lock()
                ensureTextureSizeLocked(width: w, height: h)
                // For zero-copy, we store the CV-backed texture as front.
                let backIndex = 1 - frontIndex
                textures[backIndex] = metalTexture
                frontIndex = backIndex
                textureLock.unlock()
                return
            }
        }

        // Fallback: lock and upload manually.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        uploadPixels(baseAddress, width: w, height: h, bytesPerRow: bytesPerRow)
    }

    private func ensureTextureSizeLocked(width: Int, height: Int) {
        // Called with textureLock already held.
        guard width != textureWidth || height != textureHeight else { return }
        guard width > 0, height > 0 else {
            textures = [nil, nil]
            textureWidth = 0
            textureHeight = 0
            return
        }
        textureWidth = width
        textureHeight = height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        textures[0] = device.makeTexture(descriptor: desc)
        textures[1] = device.makeTexture(descriptor: desc)
        frontIndex = 0
    }

    // MARK: - Render to CAMetalLayer

    /// Draw the current front texture into the given CAMetalLayer with
    /// aspect-fit scaling. Call from the main thread.
    func render(to layer: CAMetalLayer) {
        textureLock.lock()
        let texture = textures[frontIndex]
        textureLock.unlock()
        guard let texture else { return }

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true

        guard let drawable = layer.nextDrawable() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)

        // Compute aspect-fit vertices.
        let drawableW = Float(drawable.texture.width)
        let drawableH = Float(drawable.texture.height)
        let texW = Float(texture.width)
        let texH = Float(texture.height)

        let scaleX = drawableW / texW
        let scaleY = drawableH / texH
        let scale = min(scaleX, scaleY)
        let quadW = (texW * scale) / drawableW
        let quadH = (texH * scale) / drawableH

        // NDC vertices: position (x, y), texCoord (u, v)
        var vertices: [Float] = [
            -quadW,  quadH, 0, 0,  // top-left
             quadW,  quadH, 1, 0,  // top-right
            -quadW, -quadH, 0, 1,  // bottom-left
             quadW, -quadH, 1, 1,  // bottom-right
        ]

        encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Returns the current front texture dimensions, or nil if no texture.
    var currentTextureSize: (width: Int, height: Int)? {
        textureLock.lock()
        defer { textureLock.unlock() }
        guard textureWidth > 0, textureHeight > 0 else { return nil }
        return (textureWidth, textureHeight)
    }

    // MARK: - Metal Shaders (embedded)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut vertexPassthrough(uint vid [[vertex_id]],
                                       constant float4 *vertexData [[buffer(0)]]) {
        // Each vertex is packed as (x, y, u, v) in a float4.
        float4 v = vertexData[vid];
        VertexOut out;
        out.position = float4(v.x, v.y, 0.0, 1.0);
        out.texCoord = float2(v.z, v.w);
        return out;
    }

    fragment float4 fragmentTexture(VertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler smp [[sampler(0)]]) {
        float4 color = tex.sample(smp, in.texCoord);
        return float4(color.rgb, 1.0);
    }
    """
}
