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
    case docked
    case floating
    case native

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dockedFloating: return "Automatic"
        case .docked: return "Docked"
        case .floating: return "Floating"
        case .native: return "Native"
        }
    }
}

enum ViewerToolbarPlacement: String, CaseIterable, Identifiable {
    case bottom
    case top
    case leading
    case trailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        case .leading: return "Left"
        case .trailing: return "Right"
        }
    }

    var icon: String {
        switch self {
        case .bottom: return "rectangle.bottomthird.inset.filled"
        case .top: return "rectangle.topthird.inset.filled"
        case .leading: return "rectangle.leadingthird.inset.filled"
        case .trailing: return "rectangle.trailingthird.inset.filled"
        }
    }
}

enum ViewerKeyboardInputMode: String, CaseIterable, Identifiable {
    case unicode
    case keystrokes

    var id: String { rawValue }
}

enum ViewerToolbarItem: String, CaseIterable, Identifiable {
    case touchMode
    case fitMode
    case resetZoom
    case displays
    case shareTargets
    case quality
    case keyboard
    case modifiers
    case arrows
    case specialKeys
    case functionKeys
    case shortcuts
    case moreActions
    case disconnect

    var id: String { rawValue }

    var label: String {
        switch self {
        case .touchMode: return "Touch Mode"
        case .fitMode: return "Fit or Fill"
        case .resetZoom: return "Reset Zoom"
        case .displays: return "Displays"
        case .shareTargets: return "Share Target"
        case .quality: return "Quality"
        case .keyboard: return "Keyboard"
        case .modifiers: return "Modifiers"
        case .arrows: return "Arrow Keys"
        case .specialKeys: return "Special Keys"
        case .functionKeys: return "Function Keys"
        case .shortcuts: return "Shortcuts"
        case .moreActions: return "More Actions"
        case .disconnect: return "Disconnect"
        }
    }

    var icon: String {
        switch self {
        case .touchMode: return "hand.tap"
        case .fitMode: return "rectangle.arrowtriangle.2.inward"
        case .resetZoom: return "minus.magnifyingglass"
        case .displays: return "display.2"
        case .shareTargets: return "rectangle.on.rectangle"
        case .quality: return "slider.horizontal.3"
        case .keyboard: return "keyboard"
        case .modifiers: return "command"
        case .arrows: return "arrow.up.and.down.and.arrow.left.and.right"
        case .specialKeys: return "command.square"
        case .functionKeys: return "f.square"
        case .shortcuts: return "sparkles.rectangle.stack"
        case .moreActions: return "ellipsis.circle"
        case .disconnect: return "xmark.circle"
        }
    }

    var isRequired: Bool {
        switch self {
        case .moreActions:
            return true
        default:
            return false
        }
    }

    static let defaultOrder: [ViewerToolbarItem] = [
        .touchMode,
        .fitMode,
        .resetZoom,
        .displays,
        .shareTargets,
        .quality,
        .keyboard,
        .modifiers,
        .arrows,
        .specialKeys,
        .functionKeys,
        .shortcuts,
        .moreActions,
        .disconnect
    ]
}

@MainActor
final class ViewerControlPreferences: ObservableObject {

    @Published var touchMode: TouchMode {
        didSet { defaults.set(touchMode.rawValue, forKey: keys.touchMode) }
    }
    @Published var toolbarStyle: ViewerToolbarStyle {
        didSet { defaults.set(toolbarStyle.rawValue, forKey: keys.toolbarStyle) }
    }
    @Published var toolbarPlacement: ViewerToolbarPlacement {
        didSet { defaults.set(toolbarPlacement.rawValue, forKey: keys.toolbarPlacement) }
    }
    @Published var toolbarCondensed: Bool {
        didSet { defaults.set(toolbarCondensed, forKey: keys.toolbarCondensed) }
    }
    @Published var fitMode: Bool {
        didSet { defaults.set(fitMode, forKey: keys.fitMode) }
    }
    @Published var showStats: Bool {
        didSet { defaults.set(showStats, forKey: keys.showStats) }
    }
    @Published var showCursorOverlay: Bool {
        didSet { defaults.set(showCursorOverlay, forKey: keys.showCursorOverlay) }
    }
    @Published var streamQuality: Double {
        didSet { defaults.set(streamQuality, forKey: keys.streamQuality) }
    }
    @Published var streamProfile: StreamProfile {
        didSet { defaults.setCodable(streamProfile, forKey: keys.streamProfile) }
    }
    @Published var toolbarOffset: CGSize {
        didSet {
            defaults.set(Double(toolbarOffset.width), forKey: keys.toolbarOffsetX)
            defaults.set(Double(toolbarOffset.height), forKey: keys.toolbarOffsetY)
        }
    }
    @Published var preferredKeyboardMode: ViewerKeyboardInputMode {
        didSet { defaults.set(preferredKeyboardMode.rawValue, forKey: keys.keyboardMode) }
    }
    @Published var toolbarItems: [ViewerToolbarItem] {
        didSet { defaults.set(toolbarItems.map(\.rawValue), forKey: keys.toolbarItems) }
    }
    @Published var hiddenToolbarItems: Set<ViewerToolbarItem> {
        didSet { defaults.set(hiddenToolbarItems.map(\.rawValue), forKey: keys.hiddenToolbarItems) }
    }

    // MARK: - Phase 3 prefs (modifier auto-release, sticky modifiers, stats HUD anchor)

    /// Seconds before a `.momentary` modifier auto-releases when no
    /// keystroke arrives. Surfaced in the modifier customization sheet.
    @Published var modifierAutoReleaseSeconds: Double {
        didSet { defaults.set(modifierAutoReleaseSeconds, forKey: keys.modifierAutoReleaseSeconds) }
    }

    /// When true, a long-press on a modifier chip locks it (sticky).
    /// When false, modifiers always behave as momentary.
    @Published var stickyModifierOnLongPress: Bool {
        didSet { defaults.set(stickyModifierOnLongPress, forKey: keys.stickyModifierOnLongPress) }
    }

    /// User-positioned anchor for the floating stats HUD chip.
    @Published var statsHUDAnchor: CGPoint {
        didSet {
            defaults.set(Double(statsHUDAnchor.x), forKey: keys.statsHUDAnchorX)
            defaults.set(Double(statsHUDAnchor.y), forKey: keys.statsHUDAnchorY)
        }
    }

    /// When true the stats HUD shows only the FPS chip.
    @Published var statsHUDCollapsed: Bool {
        didSet { defaults.set(statsHUDCollapsed, forKey: keys.statsHUDCollapsed) }
    }

    /// When true the iOS native viewer overlays the floating `SQStatsHUD`
    /// chip in addition to (or instead of) the inline status bar. Disabled
    /// by default so existing behaviour is preserved.
    @Published var floatingStatsHUDEnabled: Bool {
        didSet { defaults.set(floatingStatsHUDEnabled, forKey: keys.floatingStatsHUDEnabled) }
    }

    private let defaults: UserDefaults
    private let keys: PreferenceKeys

    init(defaults: UserDefaults = .standard, scope: ViewerControlPreferenceScope? = nil) {
        self.defaults = defaults
        self.keys = PreferenceKeys(scope: scope)
        touchMode = TouchMode(rawValue: defaults.string(forKey: keys.touchMode, fallbackKey: PreferenceKeys.global.touchMode) ?? "") ?? .directTouch
        toolbarStyle = ViewerToolbarStyle(rawValue: defaults.string(forKey: keys.toolbarStyle, fallbackKey: PreferenceKeys.global.toolbarStyle) ?? "") ?? .dockedFloating
        toolbarPlacement = ViewerToolbarPlacement(rawValue: defaults.string(forKey: keys.toolbarPlacement, fallbackKey: PreferenceKeys.global.toolbarPlacement) ?? "") ?? .bottom
        toolbarCondensed = defaults.bool(forKey: keys.toolbarCondensed, fallbackKey: PreferenceKeys.global.toolbarCondensed) ?? false
        fitMode = defaults.bool(forKey: keys.fitMode, fallbackKey: PreferenceKeys.global.fitMode) ?? true
        showStats = defaults.bool(forKey: keys.showStats, fallbackKey: PreferenceKeys.global.showStats) ?? true
        showCursorOverlay = defaults.bool(forKey: keys.showCursorOverlay, fallbackKey: PreferenceKeys.global.showCursorOverlay) ?? true
        let storedStreamQuality = defaults.double(forKey: keys.streamQuality, fallbackKey: PreferenceKeys.global.streamQuality)
            ?? StreamQualityPreference.defaultQuality
        streamQuality = storedStreamQuality
        streamProfile = defaults.codable(StreamProfile.self, forKey: keys.streamProfile, fallbackKey: PreferenceKeys.global.streamProfile)
            ?? StreamQualityPreference(quality: storedStreamQuality).nativeProfile
        toolbarOffset = CGSize(
            width: defaults.double(forKey: keys.toolbarOffsetX, fallbackKey: PreferenceKeys.global.toolbarOffsetX) ?? 0,
            height: defaults.double(forKey: keys.toolbarOffsetY, fallbackKey: PreferenceKeys.global.toolbarOffsetY) ?? 0
        )
        preferredKeyboardMode = ViewerKeyboardInputMode(rawValue: defaults.string(forKey: keys.keyboardMode, fallbackKey: PreferenceKeys.global.keyboardMode) ?? "") ?? .unicode
        toolbarItems = Self.sanitizedToolbarItems(defaults.stringArray(forKey: keys.toolbarItems) ?? defaults.stringArray(forKey: PreferenceKeys.global.toolbarItems))
        hiddenToolbarItems = Self.sanitizedHiddenToolbarItems(defaults.stringArray(forKey: keys.hiddenToolbarItems) ?? defaults.stringArray(forKey: PreferenceKeys.global.hiddenToolbarItems))

        // Phase 3 prefs
        modifierAutoReleaseSeconds = defaults.double(
            forKey: keys.modifierAutoReleaseSeconds,
            fallbackKey: PreferenceKeys.global.modifierAutoReleaseSeconds
        ) ?? 4.0
        if let stickyOverride = defaults.bool(
            forKey: keys.stickyModifierOnLongPress,
            fallbackKey: PreferenceKeys.global.stickyModifierOnLongPress
        ) {
            stickyModifierOnLongPress = stickyOverride
        } else {
            stickyModifierOnLongPress = true
        }
        statsHUDAnchor = CGPoint(
            x: defaults.double(forKey: keys.statsHUDAnchorX, fallbackKey: PreferenceKeys.global.statsHUDAnchorX) ?? 0,
            y: defaults.double(forKey: keys.statsHUDAnchorY, fallbackKey: PreferenceKeys.global.statsHUDAnchorY) ?? 0
        )
        statsHUDCollapsed = defaults.bool(
            forKey: keys.statsHUDCollapsed,
            fallbackKey: PreferenceKeys.global.statsHUDCollapsed
        ) ?? false
        floatingStatsHUDEnabled = defaults.bool(
            forKey: keys.floatingStatsHUDEnabled,
            fallbackKey: PreferenceKeys.global.floatingStatsHUDEnabled
        ) ?? false
    }

    func isToolbarItemVisible(_ item: ViewerToolbarItem) -> Bool {
        item.isRequired || !hiddenToolbarItems.contains(item)
    }

    func setToolbarItem(_ item: ViewerToolbarItem, visible: Bool) {
        guard !item.isRequired else { return }
        if visible {
            hiddenToolbarItems.remove(item)
        } else {
            hiddenToolbarItems.insert(item)
        }
    }

    func moveToolbarItems(from source: IndexSet, to destination: Int) {
        let movingItems = source.map { toolbarItems[$0] }
        var remainingItems = toolbarItems
        for index in source.sorted(by: >) {
            remainingItems.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        let insertionIndex = min(max(adjustedDestination, 0), remainingItems.count)
        remainingItems.insert(contentsOf: movingItems, at: insertionIndex)
        toolbarItems = remainingItems
    }

    func resetToolbarItems() {
        toolbarItems = ViewerToolbarItem.defaultOrder
        hiddenToolbarItems = []
    }

    private static func sanitizedToolbarItems(_ rawItems: [String]?) -> [ViewerToolbarItem] {
        var seen = Set<ViewerToolbarItem>()
        var items = (rawItems ?? []).compactMap(ViewerToolbarItem.init(rawValue:)).filter { item in
            seen.insert(item).inserted
        }
        for item in ViewerToolbarItem.defaultOrder where !seen.contains(item) {
            items.append(item)
        }
        return items
    }

    private static func sanitizedHiddenToolbarItems(_ rawItems: [String]?) -> Set<ViewerToolbarItem> {
        Set((rawItems ?? [])
            .compactMap(ViewerToolbarItem.init(rawValue:))
            .filter { !$0.isRequired })
    }

    private struct PreferenceKeys {
        static let global = PreferenceKeys(prefix: "viewer.controls")

        let touchMode: String
        let toolbarStyle: String
        let toolbarPlacement: String
        let toolbarCondensed: String
        let fitMode: String
        let showStats: String
        let showCursorOverlay: String
        let streamQuality: String
        let streamProfile: String
        let toolbarOffsetX: String
        let toolbarOffsetY: String
        let keyboardMode: String
        let toolbarItems: String
        let hiddenToolbarItems: String
        let modifierAutoReleaseSeconds: String
        let stickyModifierOnLongPress: String
        let statsHUDAnchorX: String
        let statsHUDAnchorY: String
        let statsHUDCollapsed: String
        let floatingStatsHUDEnabled: String

        init(scope: ViewerControlPreferenceScope?) {
            if let scope {
                self.init(prefix: "viewer.controls.connection.\(scope.storageIdentifier)")
            } else {
                self.init(prefix: "viewer.controls")
            }
        }

        private init(prefix: String) {
            touchMode = "\(prefix).touchMode"
            toolbarStyle = "\(prefix).toolbarStyle"
            toolbarPlacement = "\(prefix).toolbarPlacement"
            toolbarCondensed = "\(prefix).toolbarCondensed"
            fitMode = "\(prefix).fitMode"
            showStats = "\(prefix).showStats"
            showCursorOverlay = "\(prefix).showCursorOverlay"
            streamQuality = "\(prefix).streamQuality"
            streamProfile = "\(prefix).streamProfile"
            toolbarOffsetX = "\(prefix).toolbarOffsetX"
            toolbarOffsetY = "\(prefix).toolbarOffsetY"
            keyboardMode = "\(prefix).keyboardMode"
            toolbarItems = "\(prefix).toolbarItems"
            hiddenToolbarItems = "\(prefix).hiddenToolbarItems"
            modifierAutoReleaseSeconds = "\(prefix).modifierAutoReleaseSeconds"
            stickyModifierOnLongPress  = "\(prefix).stickyModifierOnLongPress"
            statsHUDAnchorX            = "\(prefix).statsHUDAnchorX"
            statsHUDAnchorY            = "\(prefix).statsHUDAnchorY"
            statsHUDCollapsed          = "\(prefix).statsHUDCollapsed"
            floatingStatsHUDEnabled    = "\(prefix).floatingStatsHUDEnabled"
        }
    }
}

nonisolated struct ViewerControlPreferenceScope: Hashable, Sendable {
    var connectionProtocol: RemoteConnectionProtocol
    var host: String
    var port: UInt16

    var storageIdentifier: String {
        [
            connectionProtocol.rawValue,
            Self.storageComponent(host),
            String(port)
        ].joined(separator: ".")
    }

    private static func storageComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "unknown" }
        return String(trimmed.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_" ? character : "-"
        })
    }
}

private extension UserDefaults {
    func string(forKey key: String, fallbackKey: String) -> String? {
        string(forKey: key) ?? string(forKey: fallbackKey)
    }

    func bool(forKey key: String, fallbackKey: String) -> Bool? {
        if object(forKey: key) != nil {
            return bool(forKey: key)
        }
        if object(forKey: fallbackKey) != nil {
            return bool(forKey: fallbackKey)
        }
        return nil
    }

    func double(forKey key: String, fallbackKey: String) -> Double? {
        if object(forKey: key) != nil {
            return double(forKey: key)
        }
        if object(forKey: fallbackKey) != nil {
            return double(forKey: fallbackKey)
        }
        return nil
    }

    func setCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            set(data, forKey: key)
        }
    }

    func codable<T: Decodable>(_ type: T.Type, forKey key: String, fallbackKey: String) -> T? {
        if let data = data(forKey: key), let decoded = try? JSONDecoder().decode(type, from: data) {
            return decoded
        }
        if let data = data(forKey: fallbackKey), let decoded = try? JSONDecoder().decode(type, from: data) {
            return decoded
        }
        return nil
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
