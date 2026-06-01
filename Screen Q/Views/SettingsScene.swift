//
//  SettingsScene.swift
//  Screen Q
//
//  Unified Settings pane that consolidates Stream Quality, iCloud Sync,
//  Security & Trust, Diagnostics, Hosting, Toolbar / Gestures, About into
//  a single tabbed surface.
//
//  Entry points:
//    macOS — `Settings { SettingsScene().environmentObject(app) }` in
//            `Screen_QApp`. Opens with ⌘,.
//    iOS  — a `.sheet` presented from `HomeView`'s gear toolbar item.
//
//  Deployment targets: macOS 11.5+, iOS 17+.
//  Avoided APIs: `.tint(_:)`, two-arg `.onChange(of:_) { _, _ in }` outside
//  `#if os(iOS)`, trailing-closure `.overlay(alignment:)`, `.ultraThinMaterial`,
//  `.borderedProminent`, `.indigo`, `.teal`.
//

import SwiftUI

struct SettingsScene: View {

    // MARK: - Tab definition

    enum Tab: String, CaseIterable, Identifiable {
        case general
        case streamQuality
        case hosting
        case iCloudSync
        case security
        case toolbar
        case diagnostics
        case about

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general:       return "General"
            case .streamQuality: return "Stream & Quality"
            case .hosting:       return "Hosting"
            case .iCloudSync:    return "iCloud Sync"
            case .security:      return "Security & Trust"
            case .toolbar:       return "Toolbar & Gestures"
            case .diagnostics:   return "Diagnostics"
            case .about:         return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .general:       return "gear"
            case .streamQuality: return "slider.horizontal.3"
            case .hosting:       return "display"
            case .iCloudSync:    return "icloud.fill"
            case .security:      return "lock.shield"
            case .toolbar:       return "rectangle.bottomthird.inset.filled"
            case .diagnostics:   return "wrench.and.screwdriver"
            case .about:         return "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .general:       return ScreenQTheme.cosmicCyan
            case .streamQuality: return ScreenQTheme.cosmicTeal
            case .hosting:       return ScreenQTheme.cosmicMint
            case .iCloudSync:    return ScreenQTheme.cosmicCyan
            case .security:      return ScreenQTheme.cosmicViolet
            case .toolbar:       return ScreenQTheme.cosmicAmber
            case .diagnostics:   return ScreenQTheme.cosmicRose
            case .about:         return ScreenQTheme.cosmicViolet
            }
        }
    }

    // MARK: - State

    @EnvironmentObject private var app: AppState
    @State private var selection: Tab
    var initialTab: Tab?

    init(initialTab: Tab? = nil) {
        self.initialTab = initialTab
        _selection = State(initialValue: initialTab ?? .general)
    }

    var body: some View {
        #if os(macOS)
        macBody
            .onAppear {
                if let initialTab { selection = initialTab }
            }
        #else
        iOSBody
            .onAppear {
                if let initialTab { selection = initialTab }
            }
        #endif
    }

    // MARK: - macOS layout

    #if os(macOS)
    private var macBody: some View {
        NavigationView {
            sidebar
            tabBody(selection)
                .frame(minWidth: 560, minHeight: 480)
        }
        .frame(minWidth: 880, minHeight: 540)
    }

    private var sidebar: some View {
        List {
            ForEach(Tab.allCases) { tab in
                Button {
                    SQHaptics.tap()
                    selection = tab
                } label: {
                    sidebarRow(tab)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            selection == tab
                                ? tab.tint.opacity(0.15)
                                : Color.clear
                        )
                )
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
    }

    private func sidebarRow(_ tab: Tab) -> some View {
        SQSettingsRow(
            icon: tab.systemImage,
            iconTint: tab.tint,
            title: tab.label
        )
    }
    #endif

    // MARK: - iOS layout

    #if os(iOS)
    private var iOSBody: some View {
        List {
            ForEach(Tab.allCases) { tab in
                NavigationLink(
                    destination: tabBody(tab)
                        .navigationTitle(tab.label)
                        .navigationBarTitleDisplayMode(.inline)
                ) {
                    SQSettingsRow(
                        icon: tab.systemImage,
                        iconTint: tab.tint,
                        title: tab.label
                    ) {
                        SQSettingsChevron()
                    }
                    .simultaneousGesture(TapGesture().onEnded { SQHaptics.tap() })
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }
    #endif

    // MARK: - Tab bodies dispatcher

    @ViewBuilder
    private func tabBody(_ tab: Tab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch tab {
                case .general:       generalTab
                case .streamQuality: streamQualityTab
                case .hosting:       hostingTab
                case .iCloudSync:    iCloudSyncTab
                case .security:      securityTab
                case .toolbar:       toolbarTab
                case .diagnostics:   diagnosticsTab
                case .about:         aboutTab
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
    }

    // MARK: - General

    @AppStorage("ScreenQ.Preferences.Appearance")
    private var appearanceRaw: String = AppearancePreference.system.rawValue

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
            set: { newValue in
                SQHaptics.tap()
                appearanceRaw = newValue.rawValue
            }
        )
    }

    @AppStorage("ScreenQ.Preferences.Locale")
    private var localeRaw: String = "system"

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SQSettingsSection("Appearance", subtitle: "Pick a theme.") {
                SQSettingsRow(
                    icon: "paintpalette.fill",
                    iconTint: ScreenQTheme.cosmicCyan,
                    title: "Theme",
                    subtitle: "Match system, or force light or dark."
                ) {
                    Picker("Theme", selection: appearanceBinding) {
                        ForEach(AppearancePreference.allCases) { pref in
                            Text(pref.label).tag(pref)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                }
            }

            SQSettingsSection("Language", subtitle: "Locale and text direction.") {
                // TODO: surface a real locale picker once we ship localized strings.
                SQSettingsRow(
                    icon: "globe",
                    iconTint: ScreenQTheme.cosmicMint,
                    title: "App Language",
                    subtitle: "Follows the system language for now."
                ) {
                    SQSettingsDetail(value: "System")
                }
            }
        }
    }

    // MARK: - Stream & Quality

    private var streamQualityTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SQSettingsSection("Default Stream Quality", subtitle: "Starting point for new sessions.") {
                StreamQualityPanelDefaults()
                    .padding(.vertical, 4)
            }

            SQSettingsSection("In-Session Behaviour") {
                SQSettingsRow(
                    icon: "bolt.fill",
                    iconTint: ScreenQTheme.cosmicAmber,
                    title: "Per-session overrides",
                    subtitle: "Each active connection keeps its own slider while connected; closing the session does not affect this default."
                )
            }
        }
    }

    // MARK: - Hosting

    @AppStorage("ScreenQ.Hosting.LaunchAtLogin")
    private var launchAtLogin: Bool = false
    @AppStorage("ScreenQ.Hosting.CurtainModeDefault")
    private var curtainModeDefault: Bool = false

    private var hostingTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SQSettingsSection("App Behaviour", subtitle: "How Screen Q runs in the background.") {
                SQSettingsRow(
                    icon: "menubar.rectangle",
                    iconTint: ScreenQTheme.cosmicMint,
                    title: "Run as menu-bar accessory",
                    subtitle: "Hides the Dock icon. Window stays available from the status item."
                ) {
                    Toggle("", isOn: menuBarBinding)
                        .labelsHidden()
                }

                Divider().opacity(0.4)

                #if os(macOS)
                LaunchAtLoginSettingsRow()
                #else
                SQSettingsRow(
                    icon: "power",
                    iconTint: ScreenQTheme.cosmicAmber,
                    title: "Launch at login",
                    subtitle: "macOS-only feature."
                )
                #endif
            }

            SQSettingsSection("Privacy") {
                SQSettingsRow(
                    icon: "eye.slash",
                    iconTint: ScreenQTheme.cosmicViolet,
                    title: "Curtain Mode default",
                    subtitle: "Blank the host display automatically when sharing starts. Hides remote activity from anyone physically present."
                ) {
                    Toggle("", isOn: $curtainModeDefault)
                        .labelsHidden()
                        .screenQOnChange(of: curtainModeDefault) { _ in
                            SQHaptics.tap()
                        }
                }
            }

            SQSettingsSection("Shortcuts") {
                #if os(macOS)
                MenuBarShortcutSettingsRow()
                #endif
            }
        }
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { app.menuBarOnlyMode },
            set: { value in
                SQHaptics.tap()
                app.menuBarOnlyMode = value
            }
        )
    }

    // MARK: - iCloud Sync

    private var iCloudStatusInfo: (text: String, kind: SQStatus) {
        switch app.iCloudSync.status.phase {
        case .disabled:    return ("Off", .muted)
        case .unavailable: return ("Sign in to iCloud", .attention)
        case .idle:        return ("Synced", .healthy)
        case .syncing:     return ("Syncing", .info)
        case .error:       return ("Error", .error)
        }
    }

    private var lastSyncedText: String {
        guard let date = app.iCloudSync.status.lastSyncedAt else {
            return "Not synced yet"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var iCloudEnabledBinding: Binding<Bool> {
        Binding(
            get: { app.iCloudSync.isEnabled },
            set: { value in
                SQHaptics.tap()
                app.iCloudSync.isEnabled = value
            }
        )
    }

    private var iCloudSyncTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SQSettingsSection("iCloud Library Sync", subtitle: "Keep saved connections and viewer preferences in sync.") {
                SQSettingsRow(
                    icon: "icloud.fill",
                    iconTint: ScreenQTheme.cosmicCyan,
                    title: "Enable iCloud sync",
                    subtitle: "Credentials, fingerprints, and thumbnails stay local on each device."
                ) {
                    Toggle("", isOn: iCloudEnabledBinding)
                        .labelsHidden()
                }

                Divider().opacity(0.4)

                SQSettingsRow(
                    icon: "checkmark.icloud",
                    iconTint: ScreenQTheme.cosmicMint,
                    title: "Status",
                    subtitle: app.iCloudSync.status.message
                ) {
                    SQPill(text: iCloudStatusInfo.text, status: iCloudStatusInfo.kind, compact: true)
                }

                Divider().opacity(0.4)

                SQSettingsRow(
                    icon: "clock.arrow.circlepath",
                    iconTint: ScreenQTheme.cosmicAmber,
                    title: "Last synced",
                    subtitle: lastSyncedText
                ) {
                    Button {
                        SQHaptics.tap()
                        app.iCloudSync.syncNow(markPreferencesChanged: false)
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            .font(.sqCallout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundColor(.white)
                            .background(Capsule().fill(ScreenQTheme.accent(ScreenQTheme.cosmicCyan)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.iCloudSync.isEnabled)
                    .opacity(app.iCloudSync.isEnabled ? 1 : 0.55)
                }
            }
        }
    }

    // MARK: - Security & Trust

    private var securityTab: some View {
        SecurityTrustSettingsContent()
            .environmentObject(app)
            .padding(.bottom, 8)
    }

    // MARK: - Toolbar & Gestures

    // The following properties are scheduled to land in
    // `ViewerControlPreferences` from Phase 3:
    //   - modifierAutoReleaseSeconds: Double
    //   - stickyModifierOnLongPress: Bool
    //   - statsHUDAnchor: enum (top-leading / top-trailing / bottom-leading / bottom-trailing)
    //   - statsHUDCollapsed: Bool
    //
    // Until they land, we surface the same UI here against local @AppStorage
    // shims so the Settings UI ships today; Phase 3 swaps the bindings.
    @AppStorage("viewer.controls.modifierAutoReleaseSeconds")
    private var modifierAutoReleaseSeconds: Double = 1.5
    @AppStorage("viewer.controls.stickyModifierOnLongPress")
    private var stickyModifierOnLongPress: Bool = true
    @AppStorage("viewer.controls.statsHUDCollapsed")
    private var statsHUDCollapsed: Bool = false
    @AppStorage("viewer.controls.statsHUDAnchor")
    private var statsHUDAnchorRaw: String = "topTrailing"

    private var toolbarTab: some View {
        // Toolbar / Gestures binds against a local ViewerControlPreferences
        // instance whose UserDefaults-backed properties survive between
        // sessions. Each viewer session reads the same defaults on launch.
        ToolbarGesturesSettings(
            modifierAutoReleaseSeconds: $modifierAutoReleaseSeconds,
            stickyModifierOnLongPress: $stickyModifierOnLongPress,
            statsHUDCollapsed: $statsHUDCollapsed,
            statsHUDAnchorRaw: $statsHUDAnchorRaw
        )
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        DiagnosticsSettingsContent()
            .padding(.bottom, 8)
    }

    // MARK: - About

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    private var appBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                ScreenQBrandMark(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Q")
                        .font(.sqTitle)
                    Text("Your remote desktop, anywhere.")
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                    Text("Version \(appVersion) (\(appBuild))")
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .screenQCard(tint: ScreenQTheme.cosmicViolet)

            SQSettingsSection("Resources") {
                SQSettingsRow(
                    icon: "questionmark.circle",
                    iconTint: ScreenQTheme.cosmicCyan,
                    title: "Help & Support",
                    subtitle: "Browse the Screen Q documentation."
                ) {
                    if let url = URL(string: "https://screenq.app/help") {
                        Link(destination: url) {
                            Text("Open")
                                .font(.sqCallout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundColor(.white)
                                .background(Capsule().fill(ScreenQTheme.accent(ScreenQTheme.cosmicCyan)))
                        }
                        .simultaneousGesture(TapGesture().onEnded { SQHaptics.tap() })
                    }
                }
            }

            Text("© Screen Q. All rights reserved.")
                .font(.sqCaption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - AppearancePreference

/// Local appearance preference. Stored under `ScreenQ.Preferences.Appearance`.
/// Wiring a `preferredColorScheme` at root is left for follow-up work; this
/// enum is here so the picker has stable values to read/write today.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

// MARK: - Toolbar & Gestures sub-view

private struct ToolbarGesturesSettings: View {

    @Binding var modifierAutoReleaseSeconds: Double
    @Binding var stickyModifierOnLongPress: Bool
    @Binding var statsHUDCollapsed: Bool
    @Binding var statsHUDAnchorRaw: String

    // Persisted viewer-control preferences (shared global scope).
    @StateObject private var prefs = ViewerControlPreferences()

    private var toolbarStyleBinding: Binding<ViewerToolbarStyle> {
        Binding(
            get: { prefs.toolbarStyle },
            set: { newValue in
                SQHaptics.tap()
                prefs.toolbarStyle = newValue
            }
        )
    }

    private var toolbarPlacementBinding: Binding<ViewerToolbarPlacement> {
        Binding(
            get: { prefs.toolbarPlacement },
            set: { newValue in
                SQHaptics.tap()
                prefs.toolbarPlacement = newValue
            }
        )
    }

    private var toolbarCondensedBinding: Binding<Bool> {
        Binding(
            get: { prefs.toolbarCondensed },
            set: { newValue in
                SQHaptics.tap()
                prefs.toolbarCondensed = newValue
            }
        )
    }

    private var statsAnchorBinding: Binding<StatsHUDAnchor> {
        Binding(
            get: { StatsHUDAnchor(rawValue: statsHUDAnchorRaw) ?? .topTrailing },
            set: { newValue in
                SQHaptics.tap()
                statsHUDAnchorRaw = newValue.rawValue
            }
        )
    }

    private var floatingStatsHUDBinding: Binding<Bool> {
        Binding(
            get: { prefs.floatingStatsHUDEnabled },
            set: { newValue in
                SQHaptics.tap()
                prefs.floatingStatsHUDEnabled = newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {

            SQSettingsSection("Toolbar Layout", subtitle: "How the viewer toolbar is presented.") {
                SQSettingsRow(
                    icon: "rectangle.bottomthird.inset.filled",
                    iconTint: ScreenQTheme.cosmicAmber,
                    title: "Style",
                    subtitle: "Automatic adapts to screen size and orientation."
                ) {
                    Picker("Style", selection: toolbarStyleBinding) {
                        ForEach(ViewerToolbarStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }

                Divider().opacity(0.4)

                SQSettingsRow(
                    icon: "arrow.up.and.down.and.arrow.left.and.right",
                    iconTint: ScreenQTheme.cosmicCyan,
                    title: "Placement",
                    subtitle: "Where the toolbar docks on screen."
                ) {
                    Picker("Placement", selection: toolbarPlacementBinding) {
                        ForEach(ViewerToolbarPlacement.allCases) { placement in
                            Text(placement.label).tag(placement)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                }

                Divider().opacity(0.4)

                SQSettingsRow(
                    icon: "rectangle.compress.vertical",
                    iconTint: ScreenQTheme.cosmicViolet,
                    title: "Condensed",
                    subtitle: "Shrink the toolbar to icon-only chips."
                ) {
                    Toggle("", isOn: toolbarCondensedBinding)
                        .labelsHidden()
                }
            }

            SQSettingsSection("Modifier Keys", subtitle: "How sticky modifiers behave on touch.") {
                SQSettingsRow(
                    icon: "timer",
                    iconTint: ScreenQTheme.cosmicAmber,
                    title: "Auto-release after",
                    subtitle: String(format: "%.1f seconds idle before momentary modifiers clear.", modifierAutoReleaseSeconds)
                ) {
                    Stepper(
                        "Auto-release seconds",
                        value: $modifierAutoReleaseSeconds,
                        in: 0.5...8.0,
                        step: 0.5
                    )
                    .labelsHidden()
                    .screenQOnChange(of: modifierAutoReleaseSeconds) { _ in
                        SQHaptics.tap()
                    }
                }

                Divider().opacity(0.4)

                SQSettingsRow(
                    icon: "hand.tap",
                    iconTint: ScreenQTheme.cosmicMint,
                    title: "Long-press locks modifier",
                    subtitle: "Hold a modifier chip to keep it engaged for the next combo."
                ) {
                    Toggle("", isOn: $stickyModifierOnLongPress)
                        .labelsHidden()
                        .screenQOnChange(of: stickyModifierOnLongPress) { _ in
                            SQHaptics.tap()
                        }
                }
            }

            SQSettingsSection("Stats HUD", subtitle: "On-screen latency and bitrate readout.") {
                SQSettingsRow(
                    icon: "chart.bar.doc.horizontal",
                    iconTint: ScreenQTheme.cosmicMint,
                    title: "Floating HUD",
                    subtitle: "Show a draggable chip with FPS, bitrate, and RTT inside the viewer."
                ) {
                    Toggle("", isOn: floatingStatsHUDBinding)
                        .labelsHidden()
                }

                Divider().opacity(0.4)

                SQSettingsRow(
                    icon: "rectangle.compress.vertical",
                    iconTint: ScreenQTheme.cosmicRose,
                    title: "Collapsed by default",
                    subtitle: "Show the HUD as a tiny indicator until tapped."
                ) {
                    Toggle("", isOn: $statsHUDCollapsed)
                        .labelsHidden()
                        .screenQOnChange(of: statsHUDCollapsed) { _ in
                            SQHaptics.tap()
                        }
                }

                Divider().opacity(0.4)

                SQSettingsRow(
                    icon: "rectangle.dashed",
                    iconTint: ScreenQTheme.cosmicCyan,
                    title: "Reset HUD position",
                    subtitle: "Move the floating chip back to its starting corner."
                ) {
                    Button {
                        SQHaptics.bump()
                        prefs.statsHUDAnchor = .zero
                    } label: {
                        Text("Reset")
                            .font(.sqCallout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .foregroundColor(.white)
                            .background(Capsule().fill(ScreenQTheme.cosmicCyan))
                    }
                    .buttonStyle(.plain)
                }
            }

            SQSettingsSection("Reset", subtitle: "Restore toolbar layout to defaults.") {
                SQSettingsRow(
                    icon: "arrow.uturn.backward",
                    iconTint: ScreenQTheme.cosmicRose,
                    title: "Reset toolbar items",
                    subtitle: "Returns the toolbar item order and visibility to factory defaults."
                ) {
                    Button {
                        SQHaptics.bump()
                        prefs.resetToolbarItems()
                    } label: {
                        Text("Reset")
                            .font(.sqCallout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundColor(.white)
                            .background(Capsule().fill(ScreenQTheme.cosmicRose))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Launch-at-login (SMAppService)

#if os(macOS)
/// Row binding the launch-at-login toggle to `LaunchAtLoginService`.
/// macOS 13+ uses real SMAppService registration; older OS shows the
/// toggle disabled with a "Requires macOS 13+" note.
private struct LaunchAtLoginSettingsRow: View {

    @ObservedObject private var service = LaunchAtLoginService.shared

    var body: some View {
        SQSettingsRow(
            icon: "power",
            iconTint: ScreenQTheme.cosmicAmber,
            title: "Launch at login",
            subtitle: LaunchAtLoginService.isSupported
                ? "Auto-start Screen Q after sign-in."
                : "Requires macOS 13 or later."
        ) {
            HStack(spacing: 8) {
                SQPill(text: service.statusText,
                       status: service.isEnabled ? .healthy : .muted,
                       compact: true)
                Toggle("", isOn: launchBinding)
                    .labelsHidden()
                    .disabled(!LaunchAtLoginService.isSupported)
            }
        }
        .onAppear { service.refresh() }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { service.isEnabled },
            set: { newValue in
                SQHaptics.tap()
                _ = service.setEnabled(newValue)
            }
        )
    }
}
#endif

// MARK: - Menu bar shortcut picker

#if os(macOS)
/// Row binding the menu-bar global shortcut to `GlobalShortcutManager`'s
/// shared instance. Lives in `Settings → Hosting → Shortcuts`.
private struct MenuBarShortcutSettingsRow: View {

    @ObservedObject private var manager = GlobalShortcutManager.shared

    var body: some View {
        SQSettingsRow(
            icon: "command.square",
            iconTint: ScreenQTheme.cosmicCyan,
            title: "Menu-bar shortcut",
            subtitle: manager.isEnabled
                ? "Global shortcut to surface the Screen Q popover from anywhere."
                : "Shortcut disabled. Pick a combination to enable."
        ) {
            Picker("", selection: $manager.current) {
                ForEach(GlobalShortcutManager.Preset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .screenQOnChange(of: manager.current) { _ in
                SQHaptics.tap()
            }
        }
    }
}
#endif

/// Lightweight anchor enum for the in-session stats HUD. Mirrors the values
/// Phase 3 ships against `ViewerControlPreferences.statsHUDAnchor`.
enum StatsHUDAnchor: String, CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeading:     return "Top Left"
        case .topTrailing:    return "Top Right"
        case .bottomLeading:  return "Bottom Left"
        case .bottomTrailing: return "Bottom Right"
        }
    }
}

#Preview {
    SettingsScene()
        .environmentObject(AppState())
}
