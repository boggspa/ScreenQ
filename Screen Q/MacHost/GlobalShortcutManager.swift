//
//  GlobalShortcutManager.swift
//  Screen Q
//
//  Persists the user's chosen menu-bar global shortcut and exposes a small
//  set of preset bindings. `MacStatusBarController` observes the current
//  preset and re-installs its NSEvent monitors whenever it changes. The
//  unified Settings pane (Hosting tab) writes via a Picker bound to
//  `$current`.
//
//  Globals are NSEvent-monitor based (no third-party deps). The global
//  monitor requires Accessibility permission; the local monitor handles
//  the frontmost-app case without any extra entitlements. See
//  MacStatusBarController.installShortcutMonitors().
//

#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor
final class GlobalShortcutManager: ObservableObject {

    static let shared = GlobalShortcutManager()

    /// Preset menu-bar shortcuts the user can pick between. Keep this list
    /// short — modern macOS reserves a lot of system-wide combinations.
    enum Preset: String, CaseIterable, Identifiable, Codable {
        case none
        case cmdShiftQ
        case cmdShiftM
        case cmdOptQ
        case cmdCtrlQ
        case cmdShiftS

        var id: String { rawValue }

        /// Human-readable label shown in pickers ("⌘⇧Q") and in the
        /// SettingsScene Hosting tab.
        var displayName: String {
            switch self {
            case .none:       return "Disabled"
            case .cmdShiftQ:  return "⌘⇧Q"
            case .cmdShiftM:  return "⌘⇧M"
            case .cmdOptQ:    return "⌘⌥Q"
            case .cmdCtrlQ:   return "⌘⌃Q"
            case .cmdShiftS:  return "⌘⇧S"
            }
        }

        /// Required modifier mask (intersected with `.deviceIndependentFlagsMask`).
        /// `nil` for `.none` (shortcut disabled).
        var modifiers: NSEvent.ModifierFlags? {
            switch self {
            case .none:       return nil
            case .cmdShiftQ:  return [.command, .shift]
            case .cmdShiftM:  return [.command, .shift]
            case .cmdOptQ:    return [.command, .option]
            case .cmdCtrlQ:   return [.command, .control]
            case .cmdShiftS:  return [.command, .shift]
            }
        }

        /// Virtual key code (Carbon HIToolbox kVK_ANSI_*).
        var keyCode: UInt16 {
            switch self {
            case .none:       return 0
            case .cmdShiftQ:  return 12    // Q
            case .cmdShiftM:  return 46    // M
            case .cmdOptQ:    return 12    // Q
            case .cmdCtrlQ:   return 12    // Q
            case .cmdShiftS:  return 1     // S
            }
        }
    }

    private static let defaultsKey = "ScreenQ.Hosting.MenuBarShortcut"

    @Published var current: Preset {
        didSet {
            guard current != oldValue else { return }
            persist()
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let preset = Preset(rawValue: raw) {
            self.current = preset
        } else {
            self.current = .cmdShiftQ
        }
    }

    private func persist() {
        UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
    }

    /// True when the given key-down `NSEvent` matches the active preset.
    /// Returns `false` when the shortcut is disabled.
    func matches(_ event: NSEvent) -> Bool {
        guard let required = current.modifiers else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == required && event.keyCode == current.keyCode
    }

    /// Whether the active preset is enabled (i.e. not `.none`).
    var isEnabled: Bool { current != .none }
}
#endif
