//
//  MacInputInjectionService.swift
//  Screen Q
//
//  Maps inbound RemoteInputEvents to CGEvent injection. Gated by:
//   - Accessibility trust (AXIsProcessTrustedWithOptions)
//   - The host being in `.streaming` state with control enabled
//   - Bounds clamped to the selected display
//
//  Note: macOS App Sandbox blocks `CGEvent.post` by design. The macOS
//  Screen Q host build disables `ENABLE_APP_SANDBOX` for `[sdk=macosx*]`
//  in the project settings so this code can post system events.
//

#if os(macOS)
import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Combine

@MainActor
final class MacInputInjectionService: ObservableObject {

    @Published var enabled: Bool = false {
        didSet {
            if oldValue && !enabled {
                resetTransientState()
            }
        }
    }
    @Published var viewOnly: Bool = false {
        didSet {
            if viewOnly {
                resetTransientState()
            }
        }
    }

    private let displaySelection: DisplaySelectionService
    private let permissions: MacPermissionsService
    private let captureTargetSelection: AnyObject?

    private var lastPointerSendTime: TimeInterval = 0
    private let pointerThrottleSeconds: TimeInterval = 1.0 / 240.0
    private var lastActivatedProcessID: pid_t?
    private var lastActivationTime: TimeInterval = 0
    private var activePointerButtons: Set<PointerButton> = []
    private var activeKeys: Set<KeyCode> = []
    private var lastPointerLocation: CGPoint?

    init(
        displaySelection: DisplaySelectionService,
        permissions: MacPermissionsService,
        captureTargetSelection: AnyObject? = nil
    ) {
        self.displaySelection = displaySelection
        self.permissions = permissions
        self.captureTargetSelection = captureTargetSelection
    }

    /// True only if every gate is open: enabled, not view-only, accessibility,
    /// and a selected display exists.
    var canInject: Bool {
        permissions.refresh()
        return enabled && !viewOnly && permissions.accessibilityGranted && currentDisplayBounds() != nil
    }

    func handle(
        _ event: RemoteInputEvent,
        displayID: CGDirectDisplayID? = nil,
        inputConstraint: CaptureInputConstraint? = nil
    ) {
        guard canInject(displayID: displayID, inputConstraint: inputConstraint) else { return }
        switch event {
        case .pointerMove(let p, let mods):
            postPointer(p, type: .mouseMoved, button: .left, isDown: nil, modifiers: mods, displayID: displayID, inputConstraint: inputConstraint)
        case .pointerDown(let p, let b, let mods):
            postPointer(p, type: cgType(for: b, isDown: true), button: b, isDown: true, modifiers: mods, displayID: displayID, inputConstraint: inputConstraint)
        case .pointerUp(let p, let b, let mods):
            postPointer(p, type: cgType(for: b, isDown: false), button: b, isDown: false, modifiers: mods, displayID: displayID, inputConstraint: inputConstraint)
        case .scroll(let dx, let dy, let point, let mods):
            guard screenPoint(from: point, displayID: displayID, inputConstraint: inputConstraint) != nil else { return }
            postScroll(dx: dx, dy: dy, modifiers: mods)
        case .keyDown(let key, let mods):
            activateTargetApplicationIfNeeded(inputConstraint: inputConstraint)
            postKey(key, modifiers: mods, isDown: true)
        case .keyUp(let key, let mods):
            activateTargetApplicationIfNeeded(inputConstraint: inputConstraint)
            postKey(key, modifiers: mods, isDown: false)
        case .textInput(let text):
            activateTargetApplicationIfNeeded(inputConstraint: inputConstraint)
            postText(text)
        }
    }

    func resetTransientState() {
        let point = lastPointerLocation ?? NSEvent.mouseLocation
        for button in activePointerButtons {
            postPointerRelease(button: button, at: point)
        }
        activePointerButtons.removeAll()

        for key in activeKeys {
            postKeyRelease(key)
        }
        activeKeys.removeAll()
        lastPointerSendTime = 0
        lastActivatedProcessID = nil
        lastActivationTime = 0
    }

    // MARK: - Geometry

    private func currentDisplayBounds() -> CGRect? {
        displaySelection.selectedCGBounds()
    }

    private func currentDisplayBounds(displayID: CGDirectDisplayID?) -> CGRect? {
        guard let displayID else { return currentDisplayBounds() }
        if displayID == DisplaySelectionService.allDisplaysID {
            return DisplaySelectionService.cgDisplayBoundsUnion()
        }
        return CGDisplayBounds(displayID)
    }

    private func canInject(displayID: CGDirectDisplayID?, inputConstraint: CaptureInputConstraint?) -> Bool {
        permissions.refresh()
        return enabled &&
            !viewOnly &&
            permissions.accessibilityGranted &&
            (inputConstraint?.mappingFrame != nil || currentDisplayBounds(displayID: displayID) != nil)
    }

    private func screenPoint(
        from normalised: NormalisedPoint,
        displayID: CGDirectDisplayID? = nil,
        inputConstraint: CaptureInputConstraint? = nil
    ) -> CGPoint? {
        let constraint = inputConstraint ?? activeInputConstraint()
        let point: CGPoint

        if let frame = constraint?.mappingFrame {
            point = self.point(in: frame, from: normalised)
        } else {
            guard let bounds = currentDisplayBounds(displayID: displayID) else { return nil }
            let x = bounds.origin.x + bounds.size.width  * CGFloat(normalised.x)
            let y = bounds.origin.y + bounds.size.height * CGFloat(normalised.y)
            point = CGPoint(x: x, y: y)
        }

        if let constraint,
           !constraint.allowedFrames.isEmpty,
           !constraint.allowedFrames.contains(where: { $0.contains(point) }) {
            return nil
        }
        return point
    }

    private func point(in frame: CGRect, from normalised: NormalisedPoint) -> CGPoint {
        CGPoint(
            x: frame.origin.x + frame.size.width * CGFloat(normalised.x),
            y: frame.origin.y + frame.size.height * CGFloat(normalised.y)
        )
    }

    private func activeInputConstraint() -> CaptureInputConstraint? {
        guard #available(macOS 12.3, *),
              let service = captureTargetSelection as? CaptureTargetSelectionService else {
            return nil
        }
        return service.activeInputConstraint()
    }

    private func activateTargetApplicationIfNeeded(inputConstraint: CaptureInputConstraint? = nil) {
        guard let pid = (inputConstraint ?? activeInputConstraint())?.processID else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            lastActivatedProcessID = pid
            return
        }
        let now = Date().timeIntervalSince1970
        if lastActivatedProcessID == pid, now - lastActivationTime < 0.75 {
            return
        }
        lastActivatedProcessID = pid
        lastActivationTime = now
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: - Mouse

    private func cgType(for button: PointerButton, isDown: Bool) -> CGEventType {
        switch button {
        case .left:    return isDown ? .leftMouseDown   : .leftMouseUp
        case .right:   return isDown ? .rightMouseDown  : .rightMouseUp
        case .middle:  return isDown ? .otherMouseDown  : .otherMouseUp
        }
    }

    private func cgButton(for b: PointerButton) -> CGMouseButton {
        switch b {
        case .left:    return .left
        case .right:   return .right
        case .middle:  return .center
        }
    }

    private func postPointer(
        _ p: NormalisedPoint,
        type: CGEventType,
        button: PointerButton,
        isDown: Bool?,
        modifiers: KeyModifiers,
        displayID: CGDirectDisplayID? = nil,
        inputConstraint: CaptureInputConstraint? = nil
    ) {
        let now = Date().timeIntervalSince1970
        if type == .mouseMoved {
            if now - lastPointerSendTime < pointerThrottleSeconds { return }
            lastPointerSendTime = now
        }
        guard let pt = screenPoint(from: p, displayID: displayID, inputConstraint: inputConstraint) else { return }
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: pt,
            mouseButton: cgButton(for: button)
        ) else { return }
        event.flags = cgFlags(for: modifiers)
        event.post(tap: .cghidEventTap)
        lastPointerLocation = pt
        if let isDown {
            if isDown {
                activePointerButtons.insert(button)
            } else {
                activePointerButtons.remove(button)
            }
        }
    }

    private func postPointerRelease(button: PointerButton, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: cgType(for: button, isDown: false),
            mouseCursorPosition: point,
            mouseButton: cgButton(for: button)
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Double, dy: Double, modifiers: KeyModifiers) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(dy.clamped(to: -1024 ... 1024)),
                                  wheel2: Int32(dx.clamped(to: -1024 ... 1024)),
                                  wheel3: 0) else {
            return
        }
        event.flags = cgFlags(for: modifiers)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private func postKey(_ key: KeyCode, modifiers: KeyModifiers, isDown: Bool) {
        guard let kc = keyCodeForLogicalKey(key) else { return }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: isDown) else { return }
        event.flags = cgFlags(for: modifiers)
        event.post(tap: .cghidEventTap)
        if isDown {
            activeKeys.insert(key)
        } else {
            activeKeys.remove(key)
        }
    }

    private func postKeyRelease(_ key: KeyCode) {
        guard let kc = keyCodeForLogicalKey(key) else { return }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: false) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buf in
            down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func cgFlags(for mods: KeyModifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        if mods.contains(.shift)    { f.insert(.maskShift) }
        if mods.contains(.control)  { f.insert(.maskControl) }
        if mods.contains(.option)   { f.insert(.maskAlternate) }
        if mods.contains(.command)  { f.insert(.maskCommand) }
        if mods.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    private func keyCodeForLogicalKey(_ key: KeyCode) -> CGKeyCode? {
        switch key {
        case .returnKey:  return 0x24
        case .escape:     return 0x35
        case .tab:        return 0x30
        case .backspace:  return 0x33
        case .delete:     return 0x75
        case .arrowUp:    return 0x7E
        case .arrowDown:  return 0x7D
        case .arrowLeft:  return 0x7B
        case .arrowRight: return 0x7C
        case .spacebar:   return 0x31
        case .capsLock:   return 0x39
        case .home:       return 0x73
        case .end:        return 0x77
        case .pageUp:     return 0x74
        case .pageDown:   return 0x79
        case .a:          return 0x00
        case .c:          return 0x08
        case .d:          return 0x02
        case .f:          return 0x03
        case .h:          return 0x04
        case .l:          return 0x25
        case .m:          return 0x2E
        case .q:          return 0x0C
        case .v:          return 0x09
        case .w:          return 0x0D
        case .x:          return 0x07
        case .z:          return 0x06
        case .f1:         return 0x7A
        case .f2:         return 0x78
        case .f3:         return 0x63
        case .f4:         return 0x76
        case .f5:         return 0x60
        case .f6:         return 0x61
        case .f7:         return 0x62
        case .f8:         return 0x64
        case .f9:         return 0x65
        case .f10:        return 0x6D
        case .f11:        return 0x67
        case .f12:        return 0x6F
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
#endif
