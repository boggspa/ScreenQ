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
    private var lastPoint: CGPoint = .zero
    private var lastCursorType: String = "arrow"
    private var lastCursorImageBase64: String?
    private var lastHotSpot: NSPoint = .zero
    private var sendHandlers: [UUID: (CursorUpdateMessage) -> Void] = [:]
    private var displayID: CGDirectDisplayID = 0
    private var displayFrame: CGRect = .zero

    func start(displayID: CGDirectDisplayID, subscriberID: UUID, handler: @escaping (CursorUpdateMessage) -> Void) {
        if timer == nil || self.displayID != displayID {
            stop()
            self.displayID = displayID
            self.displayFrame = appKitFrame(for: displayID) ?? CGDisplayBounds(displayID)
            lastPoint = .zero
            lastCursorType = "arrow"
            lastCursorImageBase64 = nil
            lastHotSpot = .zero
        }
        sendHandlers[subscriberID] = handler

        // Poll at 120Hz for responsive cursor — much cheaper than sending video frames.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
        }
    }

    func removeSubscriber(_ id: UUID) {
        sendHandlers.removeValue(forKey: id)
        if sendHandlers.isEmpty {
            stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sendHandlers.removeAll()
    }

    private func tick() {
        let mouseLocation = NSEvent.mouseLocation
        // NSEvent reports AppKit screen coordinates. Use the selected
        // NSScreen frame, then flip y into the protocol's top-left space.
        let cgPoint = CGPoint(
            x: mouseLocation.x - displayFrame.minX,
            y: displayFrame.height - (mouseLocation.y - displayFrame.minY)
        )

        // Normalise to 0..1
        let nx = displayFrame.width > 0 ? cgPoint.x / displayFrame.width : 0
        let ny = displayFrame.height > 0 ? cgPoint.y / displayFrame.height : 0

        let cursorType = currentCursorTypeName()

        // Only send if position changed significantly or cursor type changed.
        let dx = abs(cgPoint.x - lastPoint.x)
        let dy = abs(cgPoint.y - lastPoint.y)
        guard dx > 0.5 || dy > 0.5 || cursorType != lastCursorType else { return }

        let cursorChanged = cursorType != lastCursorType

        // Update bitmap cache when cursor type changes.
        if cursorChanged {
            let (b64, hotSpot) = captureCursorBitmap()
            lastCursorImageBase64 = b64
            lastHotSpot = hotSpot
        }

        lastPoint = cgPoint
        lastCursorType = cursorType

        let msg = CursorUpdateMessage(
            x: Double(nx).clamped01(),
            y: Double(ny).clamped01(),
            visible: true,
            cursorType: cursorType,
            imageData: cursorChanged ? lastCursorImageBase64 : nil,
            hotSpotX: cursorChanged ? Double(lastHotSpot.x) : nil,
            hotSpotY: cursorChanged ? Double(lastHotSpot.y) : nil
        )
        for handler in sendHandlers.values {
            handler(msg)
        }
    }

    private func appKitFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenNumber == displayID
        }?.frame
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
