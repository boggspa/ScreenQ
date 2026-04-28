//
//  ViewerControlPreferences.swift
//  Screen Q
//
//  Persisted viewer-side control preferences for iPhone and iPad sessions.
//

import Foundation
import CoreGraphics
import Combine

enum ViewerToolbarStyle: String, CaseIterable, Identifiable {
    case dockedFloating
    case native

    var id: String { rawValue }
}

enum ViewerKeyboardInputMode: String, CaseIterable, Identifiable {
    case unicode
    case keystrokes

    var id: String { rawValue }
}

@MainActor
final class ViewerControlPreferences: ObservableObject {

    @Published var touchMode: TouchMode {
        didSet { defaults.set(touchMode.rawValue, forKey: Keys.touchMode) }
    }
    @Published var toolbarStyle: ViewerToolbarStyle {
        didSet { defaults.set(toolbarStyle.rawValue, forKey: Keys.toolbarStyle) }
    }
    @Published var fitMode: Bool {
        didSet { defaults.set(fitMode, forKey: Keys.fitMode) }
    }
    @Published var showStats: Bool {
        didSet { defaults.set(showStats, forKey: Keys.showStats) }
    }
    @Published var toolbarOffset: CGSize {
        didSet {
            defaults.set(Double(toolbarOffset.width), forKey: Keys.toolbarOffsetX)
            defaults.set(Double(toolbarOffset.height), forKey: Keys.toolbarOffsetY)
        }
    }
    @Published var preferredKeyboardMode: ViewerKeyboardInputMode {
        didSet { defaults.set(preferredKeyboardMode.rawValue, forKey: Keys.keyboardMode) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        touchMode = TouchMode(rawValue: defaults.string(forKey: Keys.touchMode) ?? "") ?? .directTouch
        toolbarStyle = ViewerToolbarStyle(rawValue: defaults.string(forKey: Keys.toolbarStyle) ?? "") ?? .dockedFloating
        fitMode = defaults.object(forKey: Keys.fitMode) as? Bool ?? true
        showStats = defaults.object(forKey: Keys.showStats) as? Bool ?? true
        toolbarOffset = CGSize(
            width: defaults.double(forKey: Keys.toolbarOffsetX),
            height: defaults.double(forKey: Keys.toolbarOffsetY)
        )
        preferredKeyboardMode = ViewerKeyboardInputMode(rawValue: defaults.string(forKey: Keys.keyboardMode) ?? "") ?? .unicode
    }

    private enum Keys {
        static let touchMode = "viewer.controls.touchMode"
        static let toolbarStyle = "viewer.controls.toolbarStyle"
        static let fitMode = "viewer.controls.fitMode"
        static let showStats = "viewer.controls.showStats"
        static let toolbarOffsetX = "viewer.controls.toolbarOffsetX"
        static let toolbarOffsetY = "viewer.controls.toolbarOffsetY"
        static let keyboardMode = "viewer.controls.keyboardMode"
    }
}

enum RemoteModifier: CaseIterable, Identifiable {
    case shift
    case control
    case option
    case command

    var id: String { label }

    var label: String {
        switch self {
        case .shift: return "Shift"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "shift"
        case .control: return "control"
        case .option: return "option"
        case .command: return "command"
        }
    }

    var textSymbol: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }

    var keyModifier: KeyModifiers {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }
}

enum ModifierLatchState: String {
    case off
    case momentary
    case locked
}

@MainActor
final class ModifierLatchController: ObservableObject {
    @Published private var states: [RemoteModifier: ModifierLatchState] = Dictionary(
        uniqueKeysWithValues: RemoteModifier.allCases.map { ($0, .off) }
    )

    var activeModifiers: KeyModifiers {
        states.reduce(into: KeyModifiers()) { result, entry in
            if entry.value != .off {
                result.insert(entry.key.keyModifier)
            }
        }
    }

    var hasActiveModifiers: Bool {
        states.values.contains { $0 != .off }
    }

    func state(for modifier: RemoteModifier) -> ModifierLatchState {
        states[modifier] ?? .off
    }

    func toggleMomentary(_ modifier: RemoteModifier) {
        switch state(for: modifier) {
        case .off:
            states[modifier] = .momentary
        case .momentary, .locked:
            states[modifier] = .off
        }
    }

    func toggleLocked(_ modifier: RemoteModifier) {
        states[modifier] = state(for: modifier) == .locked ? .off : .locked
    }

    func clearMomentaryModifiers() {
        var next = states
        for (modifier, state) in states where state == .momentary {
            next[modifier] = .off
        }
        states = next
    }

    func clearAll() {
        states = Dictionary(uniqueKeysWithValues: RemoteModifier.allCases.map { ($0, .off) })
    }
}
