//
//  VNCMetalInputView.swift
//  Screen Q
//
//  macOS NSViewRepresentable that renders the VNC framebuffer via Metal
//  and captures keyboard, mouse, and scroll events — drop-in replacement
//  for VNCInputView's CGContext-based VNCCanvasNSView.
//

#if os(macOS)
import SwiftUI
import AppKit

struct VNCMetalInputView: NSViewRepresentable {

    @ObservedObject var session: VNCSession
    let renderer: MetalFrameBufferRenderer

    func makeNSView(context: Context) -> VNCMetalCanvasNSView {
        let view = VNCMetalCanvasNSView(renderer: renderer)
        view.session = session
        return view
    }

    func updateNSView(_ nsView: VNCMetalCanvasNSView, context: Context) {
        nsView.session = session
        nsView.serverWidth = session.viewWidth
        nsView.serverHeight = session.viewHeight
        nsView.applyCursor(image: session.cursorImage, hotspot: session.cursorHotspot)
        nsView.renderFrame()
    }
}

// MARK: - Metal-backed Canvas NSView with Input

final class VNCMetalCanvasNSView: MetalCanvasNSView {

    var session: VNCSession?
    var serverWidth: Int = 1
    var serverHeight: Int = 1

    override var acceptsFirstResponder: Bool { true }

    private var currentButtonMask: UInt8 = 0
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var customCursor: NSCursor?
    private var lastCursorImageHash: Int = 0

    func applyCursor(image: CGImage?, hotspot: CGPoint) {
        guard let image else {
            if customCursor != nil {
                customCursor = nil
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        // Avoid rebuilding the NSCursor on every render frame.
        let identityHash = ObjectIdentifier(image).hashValue
        if identityHash == lastCursorImageHash, customCursor != nil { return }
        lastCursorImageHash = identityHash
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        customCursor = NSCursor(image: nsImage, hotSpot: hotspot)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let customCursor {
            addCursorRect(bounds, cursor: customCursor)
        }
    }

    // MARK: - First responder

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Mouse events

    override func mouseMoved(with event: NSEvent)        { sendPointer(event) }
    override func mouseDragged(with event: NSEvent)      { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent)  { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent)  { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        currentButtonMask |= 0x01
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        currentButtonMask &= ~0x01
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        currentButtonMask |= 0x04
        sendPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        currentButtonMask &= ~0x04
        sendPointer(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        currentButtonMask |= 0x02
        sendPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        currentButtonMask &= ~0x02
        sendPointer(event)
    }

    override func scrollWheel(with event: NSEvent) {
        let (x, y) = vncRemotePoint(event)
        if event.scrollingDeltaY > 0 {
            session?.sendMouseMove(x: x, y: y, buttons: currentButtonMask | 0x08)
            session?.sendMouseMove(x: x, y: y, buttons: currentButtonMask)
        } else if event.scrollingDeltaY < 0 {
            session?.sendMouseMove(x: x, y: y, buttons: currentButtonMask | 0x10)
            session?.sendMouseMove(x: x, y: y, buttons: currentButtonMask)
        }
    }

    private func sendPointer(_ event: NSEvent) {
        let (x, y) = vncRemotePoint(event)
        session?.sendMouseMove(x: x, y: y, buttons: currentButtonMask)
    }

    // MARK: - Keyboard events

    override func keyDown(with event: NSEvent) {
        guard let keysym = x11Keysym(from: event) else { return }
        session?.sendKey(code: keysym, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let keysym = x11Keysym(from: event) else { return }
        session?.sendKey(code: keysym, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        sendModifier(event, flag: .shift,   keysym: 0xFFE1)
        sendModifier(event, flag: .control, keysym: 0xFFE3)
        sendModifier(event, flag: .option,  keysym: 0xFFE9)
        sendModifier(event, flag: .command, keysym: 0xFFE7)
        lastModifiers = event.modifierFlags
    }

    private func sendModifier(_ event: NSEvent, flag: NSEvent.ModifierFlags, keysym: UInt32) {
        let wasDown = lastModifiers.contains(flag)
        let isDown = event.modifierFlags.contains(flag)
        if wasDown != isDown {
            session?.sendKey(code: keysym, isDown: isDown)
        }
    }

    // MARK: - Coordinate mapping

    private func vncRemotePoint(_ event: NSEvent) -> (Int, Int) {
        let local = convert(event.locationInWindow, from: nil)
        let (rect, scale) = scaledRect()
        let remoteX = Int((local.x - rect.origin.x) / scale)
        let remoteY = Int((local.y - rect.origin.y) / scale)
        return (max(0, min(serverWidth - 1, remoteX)),
                max(0, min(serverHeight - 1, remoteY)))
    }

    // MARK: - Keysym mapping

    private func x11Keysym(from event: NSEvent) -> UInt32? {
        if let chars = event.characters, let scalar = chars.unicodeScalars.first {
            let v = scalar.value
            if v >= 0x20 && v <= 0x7E { return v }
        }
        return macKeyCodeToKeysym[event.keyCode]
    }

    private let macKeyCodeToKeysym: [UInt16: UInt32] = [
        0x24: 0xFF0D, // Return
        0x30: 0xFF09, // Tab
        0x35: 0xFF1B, // Escape
        0x33: 0xFF08, // Backspace
        0x75: 0xFFFF, // Forward Delete
        0x31: 0x0020, // Space
        0x7B: 0xFF51, // Left Arrow
        0x7C: 0xFF53, // Right Arrow
        0x7E: 0xFF52, // Up Arrow
        0x7D: 0xFF54, // Down Arrow
        0x73: 0xFF50, // Home
        0x77: 0xFF57, // End
        0x74: 0xFF55, // Page Up
        0x79: 0xFF56, // Page Down
        0x7A: 0xFFBE, // F1
        0x78: 0xFFBF, // F2
        0x63: 0xFFC0, // F3
        0x76: 0xFFC1, // F4
        0x60: 0xFFC2, // F5
        0x61: 0xFFC3, // F6
        0x62: 0xFFC4, // F7
        0x64: 0xFFC5, // F8
        0x65: 0xFFC6, // F9
        0x6D: 0xFFC7, // F10
        0x67: 0xFFC8, // F11
        0x6F: 0xFFC9, // F12
        0x39: 0xFFE5, // Caps Lock
    ]
}

#endif
