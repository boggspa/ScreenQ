//
//  IOSSessionControlSurface.swift
//  Screen Q
//
//  iPhone/iPad in-session controls. Phase 3 refactor:
//   - Toolbar chrome lives in `SQInSessionToolbar` (Theme/InSession).
//   - Modifier-key rendering lives in `SQModifierBar`.
//   - Positioning / placement / floating-vs-docked logic STAYS here so
//     each viewer can keep its scope-specific preferences.
//
//  Behaviour change: none. Same controls, same callbacks, same menus.
//

import SwiftUI

#if os(iOS)
struct IOSSessionControlSurface: View {

    @ObservedObject var session: ViewerSession
    @ObservedObject var preferences: ViewerControlPreferences
    @ObservedObject var modifiers: ModifierLatchController

    @Binding var touchMode: TouchMode
    @Binding var fitMode: Bool
    @Binding var showStats: Bool
    @Binding var isKeyboardActive: Bool
    @Binding var controlsVisible: Bool

    let viewport: ViewportTransform
    let resetViewport: () -> Void
    let onDisconnect: () -> Void

    @State private var dragStartOffset: CGSize?
    @State private var showGestureHelp = false
    @State private var showToolbarCustomization = false
    @State private var showShareTargetPicker = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if controlsVisible {
                    if usesFloatingToolbar(in: proxy.size) {
                        floatingToolbar(in: proxy.size)
                    } else {
                        dockedToolbar(in: proxy.size)
                    }
                } else {
                    revealButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(12)
                }
            }
        }
        .allowsHitTesting(true)
        .sheet(isPresented: $showGestureHelp) {
            SQGestureHelpSheet(isPresented: $showGestureHelp)
        }
        .sheet(isPresented: $showToolbarCustomization) {
            SQToolbarCustomizationSheet(preferences: preferences, isPresented: $showToolbarCustomization)
        }
    }

    // MARK: - Reveal button (visible when toolbar is hidden)

    private var revealButton: some View {
        Button {
            SQHaptics.tap()
            controlsVisible = true
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.65))
                Circle().stroke(Color.white.opacity(0.30), lineWidth: 0.75)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: Color.black.opacity(0.30), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show controls")
    }

    // MARK: - Floating toolbar

    private func floatingToolbar(in size: CGSize) -> some View {
        let base = floatingBasePosition(in: size)
        let placement = resolvedToolbarPlacement(in: size)
        let vertical = placement == .leading || placement == .trailing
        let safeOffset = preferences.toolbarCondensed
            ? .zero
            : clampedOffset(preferences.toolbarOffset, in: size, base: base, vertical: vertical)
        return toolbarBody(placement: toolbarPlacement(for: placement))
            .position(base)
            .offset(safeOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartOffset == nil { dragStartOffset = safeOffset }
                        let start = dragStartOffset ?? .zero
                        preferences.toolbarOffset = clampedOffset(
                            CGSize(width: start.width + value.translation.width,
                                   height: start.height + value.translation.height),
                            in: size, base: base, vertical: vertical
                        )
                    }
                    .onEnded { _ in dragStartOffset = nil }
            )
            .onAppear { clampStoredToolbarOffset(in: size, base: base, vertical: vertical) }
            .onChange(of: size) { _, _ in
                let nextPlacement = resolvedToolbarPlacement(in: size)
                clampStoredToolbarOffset(
                    in: size,
                    base: floatingBasePosition(in: size),
                    vertical: nextPlacement == .leading || nextPlacement == .trailing
                )
            }
            .onChange(of: preferences.toolbarPlacement) { _, _ in resetToolbarOffset() }
            .onChange(of: preferences.toolbarStyle)     { _, _ in resetToolbarOffset() }
            .onChange(of: preferences.toolbarCondensed) { _, _ in
                let nextPlacement = resolvedToolbarPlacement(in: size)
                clampStoredToolbarOffset(
                    in: size,
                    base: floatingBasePosition(in: size),
                    vertical: nextPlacement == .leading || nextPlacement == .trailing
                )
            }
    }

    private func dockedToolbar(in size: CGSize) -> some View {
        let placement = resolvedToolbarPlacement(in: size)
        return toolbarBody(placement: toolbarPlacement(for: placement))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dockedAlignment(for: placement))
            .padding(dockedPadding(for: placement))
    }

    // MARK: - Toolbar body (delegates chrome to SQInSessionToolbar)

    @ViewBuilder
    private func toolbarBody(placement: SQInSessionToolbarPlacement) -> some View {
        if preferences.toolbarCondensed {
            SQInSessionToolbar(
                placement: placement,
                style: .condensed,
                onCustomize: { showToolbarCustomization = true }
            ) {
                AnyView(
                    HStack(spacing: 4) {
                        SQToolbarButton(systemName: "plus", label: "Expand controls") {
                            preferences.toolbarCondensed = false
                        }
                        disconnectButton
                    }
                )
            }
            .fixedSize()
        } else {
            expandedToolbarBody(placement: placement)
        }
    }

    private var isVertical: Bool {
        switch preferences.toolbarPlacement {
        case .leading, .trailing: return true
        case .top, .bottom:       return false
        }
    }

    @ViewBuilder
    private func expandedToolbarBody(placement: SQInSessionToolbarPlacement) -> some View {
        let vertical = (placement == .leading || placement == .trailing)
        let axis: Axis.Set = vertical ? .vertical : .horizontal
        ScrollView(axis, showsIndicators: false) {
            SQInSessionToolbar(
                placement: placement,
                style: .floating,
                modifiers: modifierSnapshotIfEnabled,
                modifiersEnabled: canControl,
                stickyModifierOnLongPress: preferences.stickyModifierOnLongPress,
                onModifierToggle: { mod, gesture in
                    guard canControl else { return }
                    modifiers.apply(mod, gesture: gesture)
                },
                onCustomize: { showToolbarCustomization = true }
            ) {
                AnyView(toolbarItemsStack(vertical: vertical))
            }
        }
        .frame(
            maxWidth:  vertical ? 80  : min(UIScreen.main.bounds.width - 20, isPad ? 940 : 760),
            maxHeight: vertical ? min(UIScreen.main.bounds.height - 20, 660) : 70
        )
    }

    @ViewBuilder
    private func toolbarItemsStack(vertical: Bool) -> some View {
        if vertical {
            VStack(spacing: 6) { toolbarItemContent }
        } else {
            HStack(spacing: 6) { toolbarItemContent }
        }
    }

    @ViewBuilder
    private var toolbarItemContent: some View {
        SQToolbarButton(systemName: "minus", label: "Condense controls") {
            preferences.toolbarCondensed = true
        }
        statusPill
        ForEach(visibleToolbarItems, id: \.self) { item in
            toolbarItem(item)
        }
        disconnectButton
    }

    // MARK: - Toolbar item map (only items that don't live in the modifier slot)

    private var visibleToolbarItems: [ViewerToolbarItem] {
        preferences.toolbarItems.filter { item in
            guard item != .modifiers else { return false }      // rendered inline
            guard item != .disconnect else { return false }     // rendered after
            return toolbarItemIsAvailable(item)
        }
    }

    private var modifierSnapshotIfEnabled: SQModifierBar.Snapshot? {
        guard preferences.isToolbarItemVisible(.modifiers) else { return nil }
        return modifiers.sqModifierSnapshot
    }

    @ViewBuilder
    private func toolbarItem(_ item: ViewerToolbarItem) -> some View {
        switch item {
        case .touchMode:     touchModeMenu
        case .fitMode:       fitModeButton
        case .resetZoom:     resetZoomButton
        case .displays:      displayMenu
        case .shareTargets:  shareTargetMenu
        case .quality:       qualityButton
        case .keyboard:      keyboardButton
        case .modifiers:     EmptyView()          // already rendered inline
        case .arrows:        arrowsMenu
        case .specialKeys:   specialKeysMenu
        case .functionKeys:  functionKeysMenu
        case .shortcuts:     shortcutsMenu
        case .moreActions:   actionMenu
        case .disconnect:    EmptyView()          // already rendered after
        }
    }

    private func toolbarItemIsAvailable(_ item: ViewerToolbarItem) -> Bool {
        guard preferences.isToolbarItemVisible(item) else { return false }
        switch item {
        case .resetZoom:    return !viewport.isIdentity
        case .displays:     return shouldShowLegacyDisplayPicker
        case .shareTargets: return session.shareTargets.count > 1
        default:            return true
        }
    }

    // MARK: - Individual toolbar items

    private var statusPill: some View {
        ZStack {
            Circle().fill(statusPillTint.opacity(0.18))
            Circle().stroke(statusPillTint.opacity(0.55), lineWidth: 0.75)
            Image(systemName: canControl ? "cursorarrow.click" : "eye")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusPillTint)
            if session.encryptionStatusKnown && session.encryptionEnabled {
                Circle()
                    .fill(ScreenQTheme.cosmicMint)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.30), lineWidth: 0.5))
                    .offset(x: 12, y: -12)
            }
        }
        .frame(width: 38, height: 38)
        .accessibilityLabel(canControl ? "Control enabled" : "Observe only")
    }

    private var statusPillTint: Color {
        canControl ? ScreenQTheme.cosmicMint : ScreenQTheme.cosmicAmber
    }

    private var keyboardButton: some View {
        SQToolbarButton(
            systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
            label: isKeyboardActive ? "Hide keyboard" : "Show keyboard",
            isDisabled: !canControl
        ) {
            isKeyboardActive.toggle()
        }
    }

    private var fitModeButton: some View {
        SQToolbarButton(
            systemName: fitMode ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward",
            label: fitMode ? "Fill screen" : "Fit to screen"
        ) {
            fitMode.toggle()
            preferences.fitMode = fitMode
        }
    }

    private var resetZoomButton: some View {
        SQToolbarButton(systemName: "minus.magnifyingglass", label: "Reset zoom") {
            resetViewport()
        }
    }

    private var qualityButton: some View {
        StreamQualityButton(
            quality: $preferences.streamQuality,
            profile: $preferences.streamProfile,
            stats: session.stats,
            protocolName: "Screen Q Native",
            detail: "Controls native host bitrate, frame cadence, viewport-aware detail, and compression."
        )
    }

    private var disconnectButton: some View {
        Button {
            SQHaptics.warning()
            onDisconnect()
        } label: {
            ZStack {
                Circle().fill(ScreenQTheme.cosmicRose.opacity(0.90))
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: ScreenQTheme.cosmicRose.opacity(0.45), radius: 6, x: 0, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Disconnect")
    }

    // MARK: - Menus

    private var touchModeMenu: some View {
        Menu {
            ForEach(TouchMode.allCases) { mode in
                Button { touchMode = mode; preferences.touchMode = mode } label: {
                    Label(mode.label, systemImage: mode.icon)
                }
            }
            Divider()
            Button {
                preferences.showCursorOverlay.toggle()
            } label: {
                Label(
                    preferences.showCursorOverlay ? "Hide Overlay Cursor" : "Show Overlay Cursor",
                    systemImage: preferences.showCursorOverlay ? "eye.slash" : "cursorarrow.rays"
                )
            }
        } label: {
            Image(systemName: touchMode.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Touch mode")
    }

    @ViewBuilder
    private var displayMenu: some View {
        if shouldShowLegacyDisplayPicker {
            Menu {
                ForEach(session.remoteDisplays) { display in
                    Button {
                        Task { await session.switchDisplay(display.id) }
                    } label: {
                        if display.id == session.activeDisplayID {
                            Label(display.name, systemImage: "checkmark")
                        } else {
                            Text(display.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "display.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Displays")
        }
    }

    @ViewBuilder
    private var shareTargetMenu: some View {
        if session.shareTargets.count > 1 {
            Button {
                showShareTargetPicker.toggle()
            } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share target")
            .popover(isPresented: $showShareTargetPicker) {
                ShareTargetPickerContent(session: session) { showShareTargetPicker = false }
            }
        }
    }

    private var arrowsMenu: some View {
        Menu {
            Button("Up")    { send(.arrowUp)    }
            Button("Down")  { send(.arrowDown)  }
            Button("Left")  { send(.arrowLeft)  }
            Button("Right") { send(.arrowRight) }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
        }
        .disabled(!canControl)
        .buttonStyle(.plain)
        .accessibilityLabel("Arrow keys")
    }

    private var specialKeysMenu: some View {
        Menu {
            ForEach(KeyboardMapping.specialKeys, id: \.label) { entry in
                Button(entry.label) { send(entry.code) }
            }
        } label: {
            Image(systemName: "command.square")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
        }
        .disabled(!canControl)
        .buttonStyle(.plain)
        .accessibilityLabel("Special keys")
    }

    private var functionKeysMenu: some View {
        Menu {
            ForEach(KeyboardMapping.functionKeys, id: \.label) { entry in
                Button(entry.label) { send(entry.code) }
            }
        } label: {
            Text("F")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
        }
        .disabled(!canControl)
        .buttonStyle(.plain)
        .accessibilityLabel("Function keys")
    }

    private var shortcutsMenu: some View {
        Menu {
            ForEach(KeyboardMapping.shortcutKeys, id: \.label) { entry in
                Button(entry.label) { send(entry.code, modifiers: entry.modifiers) }
            }
        } label: {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
        }
        .disabled(!canControl)
        .buttonStyle(.plain)
        .accessibilityLabel("Shortcuts")
    }

    private var actionMenu: some View {
        Menu {
            Button(showStats ? "Hide Stats" : "Show Stats") {
                showStats.toggle()
                preferences.showStats = showStats
            }
            Button(session.recorder.isRecording ? "Stop Recording" : "Start Recording") {
                toggleRecording()
            }
            .disabled(!session.recorder.isRecording && !canStartRecording)
            Button("Clear Modifiers") { modifiers.clearAll() }
            Button("Gesture Help") { showGestureHelp = true }
            Button("Customize Toolbar") { showToolbarCustomization = true }
            Button("Condense Controls") { preferences.toolbarCondensed = true }
            Button("Hide Controls") { controlsVisible = false }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
    }

    // MARK: - Helpers

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var canControl: Bool {
        session.inputMapper.isControlEnabled
    }

    private var canStartRecording: Bool {
        session.renderer.currentImage != nil || session.renderer.format != nil
    }

    private func toggleRecording() {
        if session.recorder.isRecording {
            session.recorder.stop()
            return
        }
        if let image = session.renderer.currentImage {
            session.recorder.start(width: image.width, height: image.height)
        } else if let format = session.renderer.format {
            session.recorder.start(width: format.pixelWidth, height: format.pixelHeight)
        }
    }

    private var shouldShowLegacyDisplayPicker: Bool {
        session.shareTargets.isEmpty && session.remoteDisplays.count > 1
    }

    private func send(_ key: KeyCode, modifiers explicitModifiers: KeyModifiers = []) {
        guard canControl else { return }
        session.inputMapper.sendKey(key, modifiers: explicitModifiers)
    }

    // MARK: - Placement / geometry (delegate to SQToolbarLayout)

    private func toolbarPlacement(for placement: ViewerToolbarPlacement) -> SQInSessionToolbarPlacement {
        SQToolbarLayout.placement(for: placement)
    }

    private func usesFloatingToolbar(in size: CGSize) -> Bool {
        SQToolbarLayout.usesFloatingToolbar(style: preferences.toolbarStyle, isPad: isPad)
    }

    private func resolvedToolbarPlacement(in size: CGSize) -> ViewerToolbarPlacement {
        SQToolbarLayout.resolvedPlacement(
            style: preferences.toolbarStyle,
            placement: preferences.toolbarPlacement,
            size: size,
            isPad: isPad
        )
    }

    private func floatingBasePosition(in size: CGSize) -> CGPoint {
        SQToolbarLayout.basePosition(
            placement: resolvedToolbarPlacement(in: size),
            condensed: preferences.toolbarCondensed,
            in: size,
            isPad: isPad
        )
    }

    private func dockedAlignment(for placement: ViewerToolbarPlacement) -> Alignment {
        SQToolbarLayout.dockedAlignment(for: placement, condensed: preferences.toolbarCondensed)
    }

    private func dockedPadding(for placement: ViewerToolbarPlacement) -> EdgeInsets {
        SQToolbarLayout.dockedPadding(for: placement, condensed: preferences.toolbarCondensed)
    }

    private func clampedOffset(_ offset: CGSize, in size: CGSize, base: CGPoint, vertical: Bool) -> CGSize {
        SQToolbarLayout.clampedOffset(
            offset, in: size, base: base, vertical: vertical,
            condensed: preferences.toolbarCondensed, isPad: isPad
        )
    }

    private func clampStoredToolbarOffset(in size: CGSize, base: CGPoint, vertical: Bool) {
        let clamped = clampedOffset(preferences.toolbarOffset, in: size, base: base, vertical: vertical)
        guard abs(preferences.toolbarOffset.width  - clamped.width)  > 0.5 ||
              abs(preferences.toolbarOffset.height - clamped.height) > 0.5 else { return }
        preferences.toolbarOffset = clamped
    }

    private func resetToolbarOffset() {
        dragStartOffset = nil
        preferences.toolbarOffset = .zero
    }
}

#endif
