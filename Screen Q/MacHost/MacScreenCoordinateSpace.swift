//
//  MacScreenCoordinateSpace.swift
//  Screen Q
//
//  Shared conversion helpers for macOS screen coordinates. AppKit reports the
//  current mouse position in bottom-left screen coordinates, while
//  ScreenCaptureKit frames and CGEvent injection use top-left global display
//  coordinates.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

enum MacScreenCoordinateSpace {
    static func topLeftMouseLocation() -> CGPoint {
        topLeftPoint(fromAppKitScreenPoint: NSEvent.mouseLocation)
    }

    static func topLeftPoint(fromAppKitScreenPoint point: CGPoint) -> CGPoint {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
           let displayID = displayID(for: screen) {
            return topLeftPoint(point, in: screen, displayID: displayID)
        }

        let appKitUnion = NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }
        let cgUnion = DisplaySelectionService.cgDisplayBoundsUnion() ?? appKitUnion
        guard !appKitUnion.isNull, !appKitUnion.isEmpty else {
            return point
        }
        return CGPoint(
            x: cgUnion.minX + (point.x - appKitUnion.minX),
            y: cgUnion.minY + (appKitUnion.maxY - point.y)
        )
    }

    private static func topLeftPoint(_ point: CGPoint, in screen: NSScreen, displayID: CGDirectDisplayID) -> CGPoint {
        let appKitFrame = screen.frame
        let cgFrame = CGDisplayBounds(displayID)
        return CGPoint(
            x: cgFrame.minX + (point.x - appKitFrame.minX),
            y: cgFrame.minY + (appKitFrame.maxY - point.y)
        )
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let displayID = screen.deviceDescription[key] as? CGDirectDisplayID {
            return displayID
        }
        if let displayID = screen.deviceDescription[key] as? UInt32 {
            return CGDirectDisplayID(displayID)
        }
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return nil
    }
}
#endif
