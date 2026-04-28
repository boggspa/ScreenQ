//
//  MacKeyboardCapture.swift
//  Screen Q
//
//  Intercepts keyboard events (including system shortcuts like Cmd+Tab)
//  on macOS viewers using a local NSEvent monitor. When active, keyboard
//  events are forwarded to the remote host instead of being handled locally.
//

#if os(macOS)
import Foundation
import AppKit
import Combine

@MainActor
final class MacKeyboardCapture: ObservableObject {

    @Published var isCapturing = false

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var sendEvent: ((RemoteInputEvent) -> Void)?

    func start(sendEvent: @escaping (RemoteInputEvent) -> Void) {
        guard !isCapturing else { return }
        self.sendEvent = sendEvent

        // Local monitor captures events sent to our app's windows.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            self.handleKeyEvent(event)
            return nil  // swallow — we sent it to remote
        }

        isCapturing = true
        Logger.shared.info("Keyboard capture started")
    }

    func stop() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        globalMonitor = nil
        sendEvent = nil
        isCapturing = false
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let mods = translateModifiers(event.modifierFlags)

        if event.type == .flagsChanged {
            // Modifier-only key event — we don't have a clean way to tell if
            // up or down, so skip (modifiers are sent with the next key event).
            return
        }

        let isDown = event.type == .keyDown

        // Try to map special keys first.
        if let keyCode = mapSpecialKey(event.keyCode) {
            let wireEvent: RemoteInputEvent = isDown
                ? .keyDown(keyCode, modifiers: mods)
                : .keyUp(keyCode, modifiers: mods)
            sendEvent?(wireEvent)
            return
        }

        // For character keys, send as textInput on keyDown.
        if isDown, let chars = event.characters, !chars.isEmpty {
            sendEvent?(.textInput(chars))
        }
    }

    private func mapSpecialKey(_ keyCode: UInt16) -> KeyCode? {
        switch keyCode {
        case 0x24: return .returnKey
        case 0x35: return .escape
        case 0x30: return .tab
        case 0x33: return .backspace
        case 0x75: return .delete
        case 0x7E: return .arrowUp
        case 0x7D: return .arrowDown
        case 0x7B: return .arrowLeft
        case 0x7C: return .arrowRight
        case 0x31: return .spacebar
        case 0x39: return .capsLock
        case 0x73: return .home
        case 0x77: return .end
        case 0x74: return .pageUp
        case 0x79: return .pageDown
        default:   return nil
        }
    }

    private func translateModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.shift)   { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option)  { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }
}
#endif
