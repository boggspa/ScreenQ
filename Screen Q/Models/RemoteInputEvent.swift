//
//  RemoteInputEvent.swift
//  Screen Q
//
//  Wire-format input events sent from a viewer to a controllable host.
//  All pointer coordinates are normalised to 0...1 against the displayed
//  remote frame on the viewer side. The host maps them back to the pixel
//  coordinates of the currently selected display.
//

import Foundation

nonisolated enum RemoteInputEvent: Codable, Sendable, Hashable {
    case pointerMove(NormalisedPoint, modifiers: KeyModifiers)
    case pointerDown(NormalisedPoint, button: PointerButton, modifiers: KeyModifiers)
    case pointerUp(NormalisedPoint, button: PointerButton, modifiers: KeyModifiers)
    case scroll(deltaX: Double, deltaY: Double, at: NormalisedPoint, modifiers: KeyModifiers)
    case keyDown(KeyCode, modifiers: KeyModifiers)
    case keyUp(KeyCode, modifiers: KeyModifiers)
    case textInput(String)            // for unicode strings on macOS via CGEvent.keyboardSetUnicodeString

    enum CodingKeys: String, CodingKey {
        case kind, point, button, deltaX, deltaY, key, modifiers, text
    }

    enum Kind: String, Codable {
        case pointerMove, pointerDown, pointerUp, scroll, keyDown, keyUp, textInput
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pointerMove(let p, let m):
            try c.encode(Kind.pointerMove, forKey: .kind)
            try c.encode(p, forKey: .point)
            try c.encode(m, forKey: .modifiers)
        case .pointerDown(let p, let b, let m):
            try c.encode(Kind.pointerDown, forKey: .kind)
            try c.encode(p, forKey: .point)
            try c.encode(b, forKey: .button)
            try c.encode(m, forKey: .modifiers)
        case .pointerUp(let p, let b, let m):
            try c.encode(Kind.pointerUp, forKey: .kind)
            try c.encode(p, forKey: .point)
            try c.encode(b, forKey: .button)
            try c.encode(m, forKey: .modifiers)
        case .scroll(let dx, let dy, let p, let m):
            try c.encode(Kind.scroll, forKey: .kind)
            try c.encode(dx, forKey: .deltaX)
            try c.encode(dy, forKey: .deltaY)
            try c.encode(p, forKey: .point)
            try c.encode(m, forKey: .modifiers)
        case .keyDown(let k, let m):
            try c.encode(Kind.keyDown, forKey: .kind)
            try c.encode(k, forKey: .key)
            try c.encode(m, forKey: .modifiers)
        case .keyUp(let k, let m):
            try c.encode(Kind.keyUp, forKey: .kind)
            try c.encode(k, forKey: .key)
            try c.encode(m, forKey: .modifiers)
        case .textInput(let s):
            try c.encode(Kind.textInput, forKey: .kind)
            try c.encode(s, forKey: .text)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .pointerMove:
            self = .pointerMove(
                try c.decode(NormalisedPoint.self, forKey: .point),
                modifiers: try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []
            )
        case .pointerDown:
            self = .pointerDown(
                try c.decode(NormalisedPoint.self, forKey: .point),
                button: try c.decode(PointerButton.self, forKey: .button),
                modifiers: try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []
            )
        case .pointerUp:
            self = .pointerUp(
                try c.decode(NormalisedPoint.self, forKey: .point),
                button: try c.decode(PointerButton.self, forKey: .button),
                modifiers: try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []
            )
        case .scroll:
            self = .scroll(
                deltaX: try c.decode(Double.self, forKey: .deltaX),
                deltaY: try c.decode(Double.self, forKey: .deltaY),
                at: try c.decode(NormalisedPoint.self, forKey: .point),
                modifiers: try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []
            )
        case .keyDown:
            self = .keyDown(
                try c.decode(KeyCode.self, forKey: .key),
                modifiers: try c.decode(KeyModifiers.self, forKey: .modifiers)
            )
        case .keyUp:
            self = .keyUp(
                try c.decode(KeyCode.self, forKey: .key),
                modifiers: try c.decode(KeyModifiers.self, forKey: .modifiers)
            )
        case .textInput:
            self = .textInput(try c.decode(String.self, forKey: .text))
        }
    }
}

/// Normalised coordinate in the displayed remote frame, 0...1.
nonisolated struct NormalisedPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = max(0, min(1, x))
        self.y = max(0, min(1, y))
    }

    static let zero = NormalisedPoint(x: 0, y: 0)
}

nonisolated enum PointerButton: String, Codable, Hashable, Sendable {
    case left
    case right
    case middle
}

/// Logical key codes. We avoid leaking platform-specific keycodes over the
/// wire and let the host translate to its native input layer.
nonisolated enum KeyCode: String, Codable, Hashable, Sendable {
    case returnKey
    case escape
    case tab
    case backspace
    case delete
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case spacebar
    case capsLock
    case home
    case end
    case pageUp
    case pageDown
    case a
    case c
    case d
    case f
    case h
    case l
    case m
    case q
    case v
    case w
    case x
    case z
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
}

nonisolated struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }
    static let shift   = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option  = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
    static let function = KeyModifiers(rawValue: 1 << 4)
}
