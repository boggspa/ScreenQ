//
//  MetalCanvasView.swift
//  Screen Q
//
//  CAMetalLayer-backed views for macOS and iOS that replace the
//  CGImage → SwiftUI Image display path. On macOS this wraps an
//  NSView; on iOS a UIView. Both use MetalFrameBufferRenderer
//  for GPU-composited frame display.
//

import SwiftUI
import Metal
import QuartzCore

// MARK: - Shared render timer

@MainActor
final class MetalDisplayLink {
    private var timer: Timer?
    private var renderCallback: (() -> Void)?

    func start(fps: Int = 60, renderCallback: @escaping () -> Void) {
        stop()
        self.renderCallback = renderCallback
        let interval = 1.0 / Double(max(1, fps))
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            renderCallback()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        renderCallback = nil
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - iOS Metal Canvas

#if os(iOS)
import UIKit

final class MetalCanvasUIView: UIView {
    let renderer: MetalFrameBufferRenderer
    private(set) var metalLayer: CAMetalLayer

    override class var layerClass: AnyClass { CAMetalLayer.self }

    init(renderer: MetalFrameBufferRenderer) {
        self.renderer = renderer
        self.metalLayer = CAMetalLayer()
        super.init(frame: .zero)
        metalLayer = self.layer as! CAMetalLayer
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = UIScreen.main.scale
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.drawableSize = CGSize(
            width: bounds.width * contentScaleFactor,
            height: bounds.height * contentScaleFactor
        )
    }

    func renderFrame() {
        renderer.render(to: metalLayer)
    }
}

struct MetalCanvasViewiOS: UIViewRepresentable {
    let renderer: MetalFrameBufferRenderer
    let onRender: ((MetalCanvasUIView) -> Void)?

    init(renderer: MetalFrameBufferRenderer, onRender: ((MetalCanvasUIView) -> Void)? = nil) {
        self.renderer = renderer
        self.onRender = onRender
    }

    func makeUIView(context: Context) -> MetalCanvasUIView {
        let view = MetalCanvasUIView(renderer: renderer)
        return view
    }

    func updateUIView(_ uiView: MetalCanvasUIView, context: Context) {
        onRender?(uiView)
    }
}
#endif

// MARK: - macOS Metal Canvas

#if os(macOS)
import AppKit

class MetalCanvasNSView: NSView {
    let renderer: MetalFrameBufferRenderer
    private(set) var metalLayer: CAMetalLayer

    init(renderer: MetalFrameBufferRenderer) {
        self.renderer = renderer
        self.metalLayer = CAMetalLayer()
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        if let screen = NSScreen.main {
            metalLayer.contentsScale = screen.backingScaleFactor
        }
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
    }

    override var isFlipped: Bool { true }

    func renderFrame() {
        renderer.render(to: metalLayer)
    }

    // MARK: - Coordinate Mapping

    func scaledRect() -> (CGRect, CGFloat) {
        guard let size = renderer.currentTextureSize,
              size.width > 0, size.height > 0 else {
            return (bounds, 1.0)
        }
        let scale = min(bounds.width / CGFloat(size.width),
                        bounds.height / CGFloat(size.height), 1.0)
        let w = CGFloat(size.width) * scale
        let h = CGFloat(size.height) * scale
        let x = (bounds.width - w) / 2
        let y = (bounds.height - h) / 2
        return (CGRect(x: x, y: y, width: w, height: h), scale)
    }

    func remotePoint(from windowLocation: CGPoint) -> (Int, Int) {
        guard let size = renderer.currentTextureSize else { return (0, 0) }
        let local = convert(windowLocation, from: nil)
        let (rect, scale) = scaledRect()
        let remoteX = Int((local.x - rect.origin.x) / scale)
        let remoteY = Int((local.y - rect.origin.y) / scale)
        return (max(0, min(size.width - 1, remoteX)),
                max(0, min(size.height - 1, remoteY)))
    }
}

struct MetalCanvasViewMac: NSViewRepresentable {
    let renderer: MetalFrameBufferRenderer
    let onRender: ((MetalCanvasNSView) -> Void)?

    init(renderer: MetalFrameBufferRenderer, onRender: ((MetalCanvasNSView) -> Void)? = nil) {
        self.renderer = renderer
        self.onRender = onRender
    }

    func makeNSView(context: Context) -> MetalCanvasNSView {
        MetalCanvasNSView(renderer: renderer)
    }

    func updateNSView(_ nsView: MetalCanvasNSView, context: Context) {
        onRender?(nsView)
    }
}
#endif
