//
//  CursorTracker.swift
//  Screen Q
//
//  Tracks the macOS cursor position and type, sending CursorUpdateMessages
//  to connected viewers so they can render a low-latency cursor overlay
//  independently of the video frame stream.
//

#if os(macOS)
import Foundation
import AppKit
import CoreGraphics

@MainActor
final class CursorTracker {

    private var timer: Timer?
    private var subscribers: [UUID: CursorSubscriber] = [:]

    private struct CursorSubscriber {
        var displayID: CGDirectDisplayID
        var displayFrame: CGRect
        var lastPoint: CGPoint = .zero
        var lastVisible: Bool = false
        var lastCursorType: String = "arrow"
        var lastCursorImageBase64: String?
        var lastHotSpot: NSPoint = .zero
        var handler: (CursorUpdateMessage) -> Void
    }

    func start(
        displayID: CGDirectDisplayID,
        subscriberID: UUID,
        frame: CGRect? = nil,
        handler: @escaping (CursorUpdateMessage) -> Void
    ) {
        let nextFrame: CGRect
        if let frame {
            nextFrame = frame
        } else if displayID == DisplaySelectionService.allDisplaysID {
            nextFrame = DisplaySelectionService.cgDisplayBoundsUnion() ?? .zero
        } else {
            nextFrame = CGDisplayBounds(displayID)
        }

        subscribers[subscriberID] = CursorSubscriber(
            displayID: displayID,
            displayFrame: nextFrame,
            handler: handler
        )

        // Poll at 120Hz for responsive cursor — much cheaper than sending video frames.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.tick()
                }
            }
        }
    }

    func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty {
            stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        subscribers.removeAll()
    }

    private func tick() {
        let mouseLocation = MacScreenCoordinateSpace.topLeftMouseLocation()
        let cursorType = currentCursorTypeName()
        var cursorBitmap: (String?, NSPoint)?

        for id in Array(subscribers.keys) {
            guard var subscriber = subscribers[id] else { continue }
            let displayFrame = subscriber.displayFrame
            guard !displayFrame.isNull, !displayFrame.isEmpty else { continue }
            let cgPoint = CGPoint(
                x: mouseLocation.x - displayFrame.minX,
                y: mouseLocation.y - displayFrame.minY
            )

            let nx = displayFrame.width > 0 ? cgPoint.x / displayFrame.width : 0
            let ny = displayFrame.height > 0 ? cgPoint.y / displayFrame.height : 0
            let dx = abs(cgPoint.x - subscriber.lastPoint.x)
            let dy = abs(cgPoint.y - subscriber.lastPoint.y)
            let isVisible = displayFrame.contains(mouseLocation)
            guard dx > 0.5 || dy > 0.5 || isVisible != subscriber.lastVisible || cursorType != subscriber.lastCursorType else {
                continue
            }

            let cursorChanged = cursorType != subscriber.lastCursorType
            if cursorChanged {
                if cursorBitmap == nil {
                    cursorBitmap = captureCursorBitmap()
                }
                subscriber.lastCursorImageBase64 = cursorBitmap?.0
                subscriber.lastHotSpot = cursorBitmap?.1 ?? .zero
            }
            subscriber.lastPoint = cgPoint
            subscriber.lastVisible = isVisible
            subscriber.lastCursorType = cursorType

            let msg = CursorUpdateMessage(
                x: Double(nx).clamped01(),
                y: Double(ny).clamped01(),
                visible: isVisible,
                cursorType: cursorType,
                imageData: cursorChanged ? subscriber.lastCursorImageBase64 : nil,
                hotSpotX: cursorChanged ? Double(subscriber.lastHotSpot.x) : nil,
                hotSpotY: cursorChanged ? Double(subscriber.lastHotSpot.y) : nil
            )
            let handler = subscriber.handler
            subscribers[id] = subscriber
            handler(msg)
        }
    }

    private func captureCursorBitmap() -> (String?, NSPoint) {
        let cursor = NSCursor.current
        let image = cursor.image
        let hotSpot = cursor.hotSpot
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return (nil, hotSpot)
        }
        return (png.base64EncodedString(), hotSpot)
    }

    private func currentCursorTypeName() -> String {
        let cursor = NSCursor.current
        if cursor == NSCursor.iBeam { return "iBeam" }
        if cursor == NSCursor.pointingHand { return "pointingHand" }
        if cursor == NSCursor.crosshair { return "crosshair" }
        if cursor == NSCursor.openHand { return "openHand" }
        if cursor == NSCursor.closedHand { return "closedHand" }
        if cursor == NSCursor.resizeLeft { return "resizeLeft" }
        if cursor == NSCursor.resizeRight { return "resizeRight" }
        if cursor == NSCursor.resizeUp { return "resizeUp" }
        if cursor == NSCursor.resizeDown { return "resizeDown" }
        if cursor == NSCursor.resizeLeftRight { return "resizeLeftRight" }
        if cursor == NSCursor.resizeUpDown { return "resizeUpDown" }
        return "arrow"
    }
}

private extension Double {
    func clamped01() -> Double {
        return Swift.min(1.0, Swift.max(0.0, self))
    }
}
#endif
