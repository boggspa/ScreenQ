//
//  InputMappingService.swift
//  Screen Q
//
//  Maps SwiftUI / UIKit / AppKit pointer + keyboard input to the wire-level
//  RemoteInputEvent. The viewer never sends events when the host has
//  declared `supportsControl == false` — that case is gated upstream by
//  the UI hiding the control affordances entirely.
//

import Foundation
import Combine
import CoreGraphics

nonisolated struct ViewportTransform: Equatable, Sendable {
    static let identity = ViewportTransform()
    static let minimumScale: CGFloat = 1.0
    static let maximumScale: CGFloat = 5.0

    var scale: CGFloat = 1.0
    var offset: CGSize = .zero

    var isIdentity: Bool {
        abs(scale - Self.minimumScale) < 0.001 &&
        abs(offset.width) < 0.5 &&
        abs(offset.height) < 0.5
    }

    func applyingMagnification(_ magnification: CGFloat, around anchor: CGPoint, in geometry: CanvasGeometry) -> ViewportTransform {
        guard scale > 0, geometry.canvasSize.width > 0, geometry.canvasSize.height > 0 else { return self }

        let nextScale = min(max(scale * magnification, Self.minimumScale), Self.maximumScale)
        let center = CGPoint(x: geometry.canvasSize.width / 2, y: geometry.canvasSize.height / 2)
        let contentPoint = CGPoint(
            x: (anchor.x - center.x - offset.width) / scale + center.x,
            y: (anchor.y - center.y - offset.height) / scale + center.y
        )
        let nextOffset = CGSize(
            width: anchor.x - center.x - (contentPoint.x - center.x) * nextScale,
            height: anchor.y - center.y - (contentPoint.y - center.y) * nextScale
        )

        return ViewportTransform(scale: nextScale, offset: nextOffset)
            .clamped(in: geometry)
    }

    func translated(by delta: CGSize, in geometry: CanvasGeometry) -> ViewportTransform {
        guard scale > Self.minimumScale + 0.001 else { return .identity }
        return ViewportTransform(
            scale: scale,
            offset: CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        )
        .clamped(in: geometry)
    }

    func clamped(in geometry: CanvasGeometry) -> ViewportTransform {
        let nextScale = min(max(scale, Self.minimumScale), Self.maximumScale)
        guard nextScale > Self.minimumScale + 0.001,
              geometry.canvasSize.width > 0,
              geometry.canvasSize.height > 0 else {
            return .identity
        }

        let drawRect = geometry.remoteDrawRect()
        let clampedX = Self.clampedAxis(
            proposed: offset.width,
            canvasLength: geometry.canvasSize.width,
            rectMin: drawRect.minX,
            rectMax: drawRect.maxX,
            scale: nextScale
        )
        let clampedY = Self.clampedAxis(
            proposed: offset.height,
            canvasLength: geometry.canvasSize.height,
            rectMin: drawRect.minY,
            rectMax: drawRect.maxY,
            scale: nextScale
        )

        return ViewportTransform(scale: nextScale, offset: CGSize(width: clampedX, height: clampedY))
    }

    func apply(to point: CGPoint, in canvasSize: CGSize) -> CGPoint {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return CGPoint(
            x: center.x + (point.x - center.x) * scale + offset.width,
            y: center.y + (point.y - center.y) * scale + offset.height
        )
    }

    func inverted(point: CGPoint, in canvasSize: CGSize) -> CGPoint {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return CGPoint(
            x: (point.x - center.x - offset.width) / scale + center.x,
            y: (point.y - center.y - offset.height) / scale + center.y
        )
    }

    private static func clampedAxis(
        proposed: CGFloat,
        canvasLength: CGFloat,
        rectMin: CGFloat,
        rectMax: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        let canvasMid = canvasLength / 2
        let rectLength = rectMax - rectMin
        let transformedLength = rectLength * scale

        if transformedLength <= canvasLength {
            let rectMid = (rectMin + rectMax) / 2
            return -(rectMid - canvasMid) * scale
        }

        let lowerBound = canvasLength - canvasMid - (rectMax - canvasMid) * scale
        let upperBound = -canvasMid - (rectMin - canvasMid) * scale
        return min(max(proposed, lowerBound), upperBound)
    }
}

nonisolated struct CanvasGeometry: Sendable {
    /// Size in points of the SwiftUI canvas presenting the remote frame.
    var canvasSize: CGSize
    /// Size in pixels of the remote frame as advertised by the host's VideoFormat.
    var remotePixelSize: CGSize
    /// True if the canvas is currently using "fit" (letterbox) instead of "fill".
    var fit: Bool
    /// Local-only zoom/pan used by iOS viewers. Remote input coordinates are
    /// mapped through this so the rendered frame and pointer events stay aligned.
    var viewport: ViewportTransform

    init(
        canvasSize: CGSize,
        remotePixelSize: CGSize,
        fit: Bool,
        viewport: ViewportTransform = .identity
    ) {
        self.canvasSize = canvasSize
        self.remotePixelSize = remotePixelSize
        self.fit = fit
        self.viewport = viewport
    }

    func normalised(localPoint: CGPoint) -> NormalisedPoint? {
        guard remotePixelSize.width > 0, remotePixelSize.height > 0 else { return nil }
        let mappedPoint = viewport.inverted(point: localPoint, in: canvasSize)
        let drawRect = remoteDrawRect()
        guard drawRect.contains(mappedPoint) else { return nil }
        let nx = (mappedPoint.x - drawRect.origin.x) / drawRect.size.width
        let ny = (mappedPoint.y - drawRect.origin.y) / drawRect.size.height
        return NormalisedPoint(x: Double(nx), y: Double(ny))
    }

    func localPoint(for point: NormalisedPoint) -> CGPoint? {
        guard remotePixelSize.width > 0, remotePixelSize.height > 0 else { return nil }
        let drawRect = remoteDrawRect()
        let basePoint = CGPoint(
            x: drawRect.minX + CGFloat(point.x) * drawRect.width,
            y: drawRect.minY + CGFloat(point.y) * drawRect.height
        )
        return viewport.apply(to: basePoint, in: canvasSize)
    }

    func remoteDrawRect() -> CGRect {
        // Compute the rect inside `canvasSize` where the remote frame is drawn.
        let canvasRatio = canvasSize.width / max(1, canvasSize.height)
        let remoteRatio = remotePixelSize.width / max(1, remotePixelSize.height)
        var drawRect = CGRect(origin: .zero, size: canvasSize)
        if fit {
            if canvasRatio > remoteRatio {
                let w = canvasSize.height * remoteRatio
                drawRect = CGRect(x: (canvasSize.width - w) / 2, y: 0, width: w, height: canvasSize.height)
            } else {
                let h = canvasSize.width / remoteRatio
                drawRect = CGRect(x: 0, y: (canvasSize.height - h) / 2, width: canvasSize.width, height: h)
            }
        } else {
            // Fill: clip excess. We still normalise relative to the remote frame.
            if canvasRatio > remoteRatio {
                let h = canvasSize.width / remoteRatio
                drawRect = CGRect(x: 0, y: (canvasSize.height - h) / 2, width: canvasSize.width, height: h)
            } else {
                let w = canvasSize.height * remoteRatio
                drawRect = CGRect(x: (canvasSize.width - w) / 2, y: 0, width: w, height: canvasSize.height)
            }
        }
        return drawRect
    }
}

@MainActor
final class InputMappingService: ObservableObject {

    var isControlEnabled: Bool = false
    var canvas: CanvasGeometry = CanvasGeometry(canvasSize: .zero, remotePixelSize: .zero, fit: true)

    /// Sink set by the viewer screen so events flow to the connection.
    var sendEvent: ((RemoteInputEvent) -> Void)?
    var activeModifiers: (() -> KeyModifiers)?
    var consumeMomentaryModifiers: (() -> Void)?

    func send(_ event: RemoteInputEvent) {
        guard isControlEnabled else { return }
        sendEvent?(event)
    }

    func sendPointerMove(localPoint: CGPoint) {
        guard let p = canvas.normalised(localPoint: localPoint) else { return }
        send(.pointerMove(p, modifiers: currentModifiers()))
    }

    func sendPointerDown(localPoint: CGPoint, button: PointerButton = .left) {
        guard let p = canvas.normalised(localPoint: localPoint) else { return }
        send(.pointerDown(p, button: button, modifiers: currentModifiers()))
    }

    func sendPointerUp(localPoint: CGPoint, button: PointerButton = .left) {
        guard let p = canvas.normalised(localPoint: localPoint) else { return }
        send(.pointerUp(p, button: button, modifiers: currentModifiers()))
        consumeMomentaryModifiers?()
    }

    func sendTap(localPoint: CGPoint, button: PointerButton = .left) {
        sendPointerDown(localPoint: localPoint, button: button)
        sendPointerUp(localPoint: localPoint, button: button)
    }

    func sendDoubleTap(localPoint: CGPoint) {
        sendTap(localPoint: localPoint)
        sendTap(localPoint: localPoint)
    }

    func sendScroll(deltaX: Double, deltaY: Double, localPoint: CGPoint) {
        guard let p = canvas.normalised(localPoint: localPoint) else { return }
        send(.scroll(deltaX: deltaX, deltaY: deltaY, at: p, modifiers: currentModifiers()))
        consumeMomentaryModifiers?()
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        send(.textInput(text))
        consumeMomentaryModifiers?()
    }

    func sendKey(_ key: KeyCode, modifiers: KeyModifiers = []) {
        let mergedModifiers = modifiers.union(currentModifiers())
        send(.keyDown(key, modifiers: mergedModifiers))
        send(.keyUp(key, modifiers: mergedModifiers))
        consumeMomentaryModifiers?()
    }

    private func currentModifiers() -> KeyModifiers {
        activeModifiers?() ?? []
    }
}
