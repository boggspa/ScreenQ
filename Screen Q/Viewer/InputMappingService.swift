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
            scale: nextScale,
            leadingInset: geometry.viewportPanInsets.leading,
            trailingInset: geometry.viewportPanInsets.trailing
        )
        let clampedY = Self.clampedAxis(
            proposed: offset.height,
            canvasLength: geometry.canvasSize.height,
            rectMin: drawRect.minY,
            rectMax: drawRect.maxY,
            scale: nextScale,
            leadingInset: geometry.viewportPanInsets.top,
            trailingInset: geometry.viewportPanInsets.bottom
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
        scale: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat
    ) -> CGFloat {
        let canvasMid = canvasLength / 2
        let lowerBound = canvasLength - max(0, trailingInset) - canvasMid - (rectMax - canvasMid) * scale
        let upperBound = max(0, leadingInset) - canvasMid - (rectMin - canvasMid) * scale
        if lowerBound <= upperBound {
            return min(max(proposed, lowerBound), upperBound)
        }
        return (lowerBound + upperBound) / 2
    }
}

nonisolated struct ViewportPanInsets: Equatable, Sendable {
    static let zero = ViewportPanInsets()

    var top: CGFloat = 0
    var leading: CGFloat = 0
    var bottom: CGFloat = 0
    var trailing: CGFloat = 0

    static func zoomedViewerInsets(for canvasSize: CGSize, keyboardActive: Bool) -> ViewportPanInsets {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let horizontal = min(max(canvasSize.width * 0.12, 48), 140)
        let top = min(max(canvasSize.height * 0.14, 56), 180)
        let bottomRatio: CGFloat = keyboardActive ? 0.42 : 0.28
        let bottomMinimum: CGFloat = keyboardActive ? 180 : 110
        let bottomMaximum: CGFloat = keyboardActive ? 360 : 260
        let bottom = min(max(canvasSize.height * bottomRatio, bottomMinimum), bottomMaximum)
        return ViewportPanInsets(top: top, leading: horizontal, bottom: bottom, trailing: horizontal)
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
    /// Extra local-only panning room around the remote frame while zoomed.
    var viewportPanInsets: ViewportPanInsets

    init(
        canvasSize: CGSize,
        remotePixelSize: CGSize,
        fit: Bool,
        viewport: ViewportTransform = .identity,
        viewportPanInsets: ViewportPanInsets = .zero
    ) {
        self.canvasSize = canvasSize
        self.remotePixelSize = remotePixelSize
        self.fit = fit
        self.viewport = viewport
        self.viewportPanInsets = viewportPanInsets
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

    func visibleRemoteRect() -> NormalisedRect? {
        guard remotePixelSize.width > 0,
              remotePixelSize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return nil
        }

        let drawRect = remoteDrawRect()
        guard drawRect.width > 0, drawRect.height > 0 else { return nil }

        let topLeft = viewport.inverted(point: .zero, in: canvasSize)
        let bottomRight = viewport.inverted(
            point: CGPoint(x: canvasSize.width, y: canvasSize.height),
            in: canvasSize
        )
        let visibleBaseRect = CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
        let intersection = visibleBaseRect.intersection(drawRect)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }

        return NormalisedRect(
            x: Double((intersection.minX - drawRect.minX) / drawRect.width),
            y: Double((intersection.minY - drawRect.minY) / drawRect.height),
            width: Double(intersection.width / drawRect.width),
            height: Double(intersection.height / drawRect.height)
        )
    }

    func normalisedDelta(localDelta: CGSize) -> (dx: Double, dy: Double)? {
        guard remotePixelSize.width > 0,
              remotePixelSize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return nil
        }
        let drawRect = remoteDrawRect()
        let visibleWidth = max(1, drawRect.width * viewport.scale)
        let visibleHeight = max(1, drawRect.height * viewport.scale)
        return (
            dx: Double(localDelta.width / visibleWidth),
            dy: Double(localDelta.height / visibleHeight)
        )
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
    var keepsPredictedPointerVisible: Bool = false
    @Published private(set) var predictedPointer: NormalisedPoint?

    /// Sink set by the viewer screen so events flow to the connection.
    var sendEvent: ((RemoteInputEvent) -> Void)?
    var activeModifiers: (() -> KeyModifiers)?
    var consumeMomentaryModifiers: (() -> Void)?
    private var currentPointer: NormalisedPoint?
    private var lastLocalPointerUpdate = Date.distantPast
    private var predictionClearTask: Task<Void, Never>?
    private var pointerFlushTask: Task<Void, Never>?
    private var pendingPointerMove: RemoteInputEvent?
    private var lastPointerSendTime = Date.distantPast
    private var localInteractionDepth = 0
    private let pointerPredictionHoldInterval: TimeInterval = 0.55
    private let pointerEchoDistanceThreshold = 0.006
    private let pointerOutputInterval: TimeInterval = 1.0 / 60.0

    func send(_ event: RemoteInputEvent) {
        guard isControlEnabled else { return }
        switch event {
        case .pointerMove(let point, _):
            enqueuePointerMove(event, point: point)
        default:
            flushPendingPointerMove()
            sendEvent?(event)
        }
    }

    func cancelPendingInput() {
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        pendingPointerMove = nil
        predictionClearTask?.cancel()
        predictionClearTask = nil
        predictedPointer = nil
        localInteractionDepth = 0
    }

    func updateRemotePointer(_ point: NormalisedPoint) {
        if shouldSuppressRemotePointerEcho(),
           let predictedPointer,
           predictedPointer.distance(to: point) > pointerEchoDistanceThreshold {
            return
        }
        currentPointer = point
        predictedPointer = nil
    }

    func beginLocalInteraction() {
        localInteractionDepth += 1
        lastLocalPointerUpdate = Date()
    }

    func endLocalInteraction() {
        localInteractionDepth = max(0, localInteractionDepth - 1)
        lastLocalPointerUpdate = Date()
    }

    func ensurePredictedPointerVisible() {
        guard keepsPredictedPointerVisible, predictedPointer == nil else { return }
        rememberLocalPointer(currentPointerOrDefault())
    }

    @discardableResult
    func sendPointerMove(localPoint: CGPoint) -> NormalisedPoint? {
        guard let p = canvas.normalised(localPoint: localPoint) else { return nil }
        rememberLocalPointer(p)
        send(.pointerMove(p, modifiers: currentModifiers()))
        return p
    }

    @discardableResult
    func sendPointerDown(localPoint: CGPoint, button: PointerButton = .left) -> NormalisedPoint? {
        guard let p = canvas.normalised(localPoint: localPoint) else { return nil }
        rememberLocalPointer(p)
        send(.pointerDown(p, button: button, modifiers: currentModifiers()))
        return p
    }

    @discardableResult
    func sendPointerUp(localPoint: CGPoint, button: PointerButton = .left) -> NormalisedPoint? {
        guard let p = canvas.normalised(localPoint: localPoint) else { return nil }
        rememberLocalPointer(p)
        send(.pointerUp(p, button: button, modifiers: currentModifiers()))
        consumeMomentaryModifiers?()
        return p
    }

    @discardableResult
    func sendPointerMove(relativeLocalDelta delta: CGSize, sensitivity: CGFloat = 1.0) -> NormalisedPoint? {
        guard let p = pointer(afterRelativeLocalDelta: delta, sensitivity: sensitivity) else { return nil }
        rememberLocalPointer(p)
        send(.pointerMove(p, modifiers: currentModifiers()))
        return p
    }

    func sendPointerDownAtCurrent(button: PointerButton = .left) {
        let p = currentPointerOrDefault()
        rememberLocalPointer(p)
        send(.pointerDown(p, button: button, modifiers: currentModifiers()))
    }

    func sendPointerUpAtCurrent(button: PointerButton = .left) {
        let p = currentPointerOrDefault()
        rememberLocalPointer(p)
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

    func sendTapAtCurrent(button: PointerButton = .left) {
        sendPointerDownAtCurrent(button: button)
        sendPointerUpAtCurrent(button: button)
    }

    func sendDoubleTapAtCurrent() {
        sendTapAtCurrent()
        sendTapAtCurrent()
    }

    func sendScroll(deltaX: Double, deltaY: Double, localPoint: CGPoint) {
        guard let p = canvas.normalised(localPoint: localPoint) else { return }
        send(.scroll(deltaX: deltaX, deltaY: deltaY, at: p, modifiers: currentModifiers()))
        consumeMomentaryModifiers?()
    }

    func sendScrollAtCurrent(deltaX: Double, deltaY: Double) {
        let p = currentPointerOrDefault()
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

    private func pointer(afterRelativeLocalDelta delta: CGSize, sensitivity: CGFloat) -> NormalisedPoint? {
        guard let normalisedDelta = canvas.normalisedDelta(localDelta: CGSize(
            width: delta.width * sensitivity,
            height: delta.height * sensitivity
        )) else {
            return nil
        }
        let base = currentPointerOrDefault()
        return NormalisedPoint(
            x: base.x + normalisedDelta.dx,
            y: base.y + normalisedDelta.dy
        )
    }

    private func enqueuePointerMove(_ event: RemoteInputEvent, point: NormalisedPoint) {
        rememberLocalPointer(point)
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPointerSendTime)
        if elapsed >= pointerOutputInterval {
            pointerFlushTask?.cancel()
            pointerFlushTask = nil
            pendingPointerMove = nil
            lastPointerSendTime = now
            sendEvent?(event)
            return
        }

        pendingPointerMove = event
        schedulePointerFlush(after: pointerOutputInterval - elapsed)
    }

    private func schedulePointerFlush(after delay: TimeInterval) {
        pointerFlushTask?.cancel()
        let nanoseconds = UInt64(max(0.001, delay) * 1_000_000_000)
        pointerFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.flushPendingPointerMove()
        }
    }

    private func flushPendingPointerMove() {
        pointerFlushTask?.cancel()
        pointerFlushTask = nil
        guard isControlEnabled, let event = pendingPointerMove else { return }
        pendingPointerMove = nil
        lastPointerSendTime = Date()
        sendEvent?(event)
    }

    private func rememberLocalPointer(_ point: NormalisedPoint) {
        currentPointer = point
        predictedPointer = point
        lastLocalPointerUpdate = Date()
        schedulePredictionClear()
    }

    private func shouldSuppressRemotePointerEcho() -> Bool {
        guard predictedPointer != nil else { return false }
        if localInteractionDepth > 0 { return true }
        return Date().timeIntervalSince(lastLocalPointerUpdate) < pointerPredictionHoldInterval
    }

    private func schedulePredictionClear() {
        predictionClearTask?.cancel()
        predictionClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(0.65 * 1_000_000_000))
            self?.clearPredictionIfExpired()
        }
    }

    private func clearPredictionIfExpired() {
        guard !keepsPredictedPointerVisible else { return }
        guard Date().timeIntervalSince(lastLocalPointerUpdate) >= pointerPredictionHoldInterval else { return }
        predictedPointer = nil
    }

    private func currentPointerOrDefault() -> NormalisedPoint {
        if let currentPointer {
            return currentPointer
        }
        return canvas.normalised(localPoint: CGPoint(
            x: canvas.canvasSize.width / 2,
            y: canvas.canvasSize.height / 2
        )) ?? NormalisedPoint(x: 0.5, y: 0.5)
    }
}

private extension NormalisedPoint {
    func distance(to other: NormalisedPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
