//
//  KeyboardMapping.swift
//  Screen Q
//
//  Static mapping helpers for special keys + modifier translation between
//  SwiftUI's KeyEquivalent / EventModifiers and our wire-level KeyCode /
//  KeyModifiers types. Used by ViewerView's keyboard handlers.
//

import Foundation
import SwiftUI

enum KeyboardMapping {

    static func keyCode(forSwiftUI key: KeyEquivalent) -> KeyCode? {
        switch key.character.unicodeScalars.first?.value {
        case 0x000D: return .returnKey
        case 0x001B: return .escape
        case 0x0009: return .tab
        case 0x0008: return .backspace
        case 0xF728: return .delete
        case 0xF700: return .arrowUp
        case 0xF701: return .arrowDown
        case 0xF702: return .arrowLeft
        case 0xF703: return .arrowRight
        case 0x0020: return .spacebar
        case 0xF729: return .home
        case 0xF72B: return .end
        case 0xF72C: return .pageUp
        case 0xF72D: return .pageDown
        default: return nil
        }
    }

    static func modifiers(from event: EventModifiers) -> KeyModifiers {
        var m: KeyModifiers = []
        if event.contains(.shift)   { m.insert(.shift) }
        if event.contains(.control) { m.insert(.control) }
        if event.contains(.option)  { m.insert(.option) }
        if event.contains(.command) { m.insert(.command) }
        return m
    }

    /// Convenience: list of common special keys exposed via the viewer toolbar.
    static let specialKeys: [(label: String, code: KeyCode)] = [
        ("Return",   .returnKey),
        ("Escape",   .escape),
        ("Tab",      .tab),
        ("Backspace", .backspace),
        ("Delete",   .delete),
        ("Up",       .arrowUp),
        ("Down",     .arrowDown),
        ("Left",     .arrowLeft),
        ("Right",    .arrowRight),
        ("Home",     .home),
        ("End",      .end),
        ("Page Up",  .pageUp),
        ("Page Down", .pageDown)
    ]

    static let functionKeys: [(label: String, code: KeyCode)] = [
        ("F1", .f1),
        ("F2", .f2),
        ("F3", .f3),
        ("F4", .f4),
        ("F5", .f5),
        ("F6", .f6),
        ("F7", .f7),
        ("F8", .f8),
        ("F9", .f9),
        ("F10", .f10),
        ("F11", .f11),
        ("F12", .f12)
    ]

    static let shortcutKeys: [(label: String, code: KeyCode, modifiers: KeyModifiers)] = [
        ("Mission Control", .arrowUp, [.control]),
        ("Application Windows", .arrowDown, [.control]),
        ("Space Left", .arrowLeft, [.control]),
        ("Space Right", .arrowRight, [.control]),
        ("Copy", .c, [.command]),
        ("Paste", .v, [.command]),
        ("Cut", .x, [.command]),
        ("Select All", .a, [.command]),
        ("Undo", .z, [.command]),
        ("Find", .f, [.command]),
        ("Hide App", .h, [.command]),
        ("Minimize", .m, [.command]),
        ("Close Window", .w, [.command]),
        ("Quit App", .q, [.command]),
        ("Force Quit", .escape, [.command, .option])
    ]
}
