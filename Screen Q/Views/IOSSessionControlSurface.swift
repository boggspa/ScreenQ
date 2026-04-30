//
//  IOSSessionControlSurface.swift
//  Screen Q
//
//  iPhone/iPad in-session controls inspired by mature remote desktop apps:
//  quick mode switching, keyboard, modifiers, shortcuts, display controls,
//  and session actions without relying on the navigation toolbar.
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
    @State private var isCollapsed = false
    @State private var showGestureHelp = false
    @State private var showToolbarCustomization = false

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
            gestureHelp
        }
        .sheet(isPresented: $showToolbarCustomization) {
            toolbarCustomization
        }
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var revealButton: some View {
        Button {
            controlsVisible = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show controls")
    }

    private func floatingToolbar(in size: CGSize) -> some View {
        let base = floatingBasePosition(in: size)
        return toolbarBody(vertical: isCollapsed)
            .position(base)
            .offset(preferences.toolbarOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartOffset == nil {
                            dragStartOffset = preferences.toolbarOffset
                        }
                        let start = dragStartOffset ?? .zero
                        preferences.toolbarOffset = clampedOffset(
                            CGSize(width: start.width + value.translation.width,
                                   height: start.height + value.translation.height),
                            in: size,
                            base: base
                        )
                    }
                    .onEnded { _ in
                        dragStartOffset = nil
                    }
            )
    }

    private func dockedToolbar(in size: CGSize) -> some View {
        let placement = resolvedToolbarPlacement(in: size)
        let vertical = placement == .leading || placement == .trailing
        return toolbarBody(vertical: vertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dockedAlignment(for: placement))
            .padding(dockedPadding(for: placement))
    }

    private func toolbarBody(vertical: Bool) -> some View {
        let axis: Axis.Set = vertical ? .vertical : .horizontal
        return ScrollView(axis, showsIndicators: false) {
            Group {
                if isCollapsed && isPad {
                    stack(vertical: vertical) {
                        toolbarSection(vertical: vertical) {
                            statusPill
                            iconButton(systemName: "chevron.up.chevron.down", label: "Expand controls") {
                                isCollapsed = false
                            }
                        }
                        toolbarSection(vertical: vertical) {
                            if preferences.isToolbarItemVisible(.keyboard) {
                                keyboardButton
                            }
                            if preferences.isToolbarItemVisible(.quality) {
                                qualityButton
                            }
                            if preferences.isToolbarItemVisible(.touchMode) {
                                touchModeMenu
                            }
                        }
                        toolbarSection(vertical: vertical) {
                            actionMenu
                        }
                    }
                } else {
                    stack(vertical: vertical) {
                        toolbarSection(vertical: vertical) {
                            statusPill
                            iconButton(systemName: "minus", label: isPad ? "Collapse controls" : "Hide controls") {
                                if isPad {
                                    isCollapsed = true
                                } else {
                                    controlsVisible = false
                                }
                            }
                        }
                        ForEach(toolbarItemSections, id: \.self) { section in
                            toolbarSection(vertical: vertical, prominent: section.contains(.disconnect)) {
                                ForEach(section) { item in
                                    toolbarItem(item, vertical: vertical)
                                }
                            }
                        }
                    }
                }
            }
            .padding(7)
        }
        .frame(
            maxWidth: vertical ? 68 : min(UIScreen.main.bounds.width - 20, isPad ? 940 : 760),
            maxHeight: vertical ? min(UIScreen.main.bounds.height - 20, 660) : 66
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .contain)
    }

    private var statusPill: some View {
        Image(systemName: canControl ? "cursorarrow.click" : "eye")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(canControl ? .green : .orange)
            .frame(width: 38, height: 38)
            .background(Color.primary.opacity(0.08))
            .clipShape(Circle())
            .accessibilityLabel(canControl ? "Control enabled" : "Observe only")
    }

    private var keyboardButton: some View {
        iconButton(
            systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
            label: isKeyboardActive ? "Hide keyboard" : "Show keyboard",
            disabled: !canControl
        ) {
            isKeyboardActive.toggle()
        }
    }

    private var fitModeButton: some View {
        iconButton(
            systemName: fitMode ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward",
            label: fitMode ? "Fill screen" : "Fit to screen"
        ) {
            fitMode.toggle()
            preferences.fitMode = fitMode
        }
    }

    private var resetZoomButton: some View {
        iconButton(systemName: "minus.magnifyingglass", label: "Reset zoom") {
            resetViewport()
        }
    }

    private var qualityButton: some View {
        StreamQualityButton(
            quality: $preferences.streamQuality,
            profile: $preferences.streamProfile,
            protocolName: "Screen Q Native",
            detail: "Controls native host bitrate, frame cadence, and JPEG fallback compression."
        )
    }

    private var disconnectButton: some View {
        iconButton(systemName: "xmark.circle", label: "Disconnect", tint: .red) {
            onDisconnect()
        }
    }

    private var touchModeMenu: some View {
        Menu {
            ForEach(TouchMode.allCases) { mode in
                Button {
                    touchMode = mode
                    preferences.touchMode = mode
                } label: {
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
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Touch mode")
    }

    @ViewBuilder
    private var displayMenu: some View {
        if session.remoteDisplays.count > 1 {
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
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Displays")
        }
    }

    private func modifierButtons(vertical: Bool) -> some View {
        stack(vertical: vertical) {
            ForEach(RemoteModifier.allCases) { modifier in
                modifierButton(modifier)
            }
        }
    }

    private func modifierButton(_ modifier: RemoteModifier) -> some View {
        let state = modifiers.state(for: modifier)
        return Text(modifier.textSymbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 38, height: 38)
            .foregroundStyle(state == .off ? Color.primary : Color.white)
            .background(modifierBackground(for: state))
            .clipShape(Circle())
            .opacity(canControl ? 1 : 0.35)
            .onTapGesture(count: 2) {
                guard canControl else { return }
                modifiers.toggleLocked(modifier)
            }
            .onTapGesture {
                guard canControl else { return }
                modifiers.toggleMomentary(modifier)
            }
            .accessibilityLabel("\(modifier.label) modifier")
    }

    private func modifierBackground(for state: ModifierLatchState) -> Color {
        switch state {
        case .off: return Color.primary.opacity(0.08)
        case .momentary: return Color.accentColor.opacity(0.72)
        case .locked: return Color.accentColor
        }
    }

    private var arrowsMenu: some View {
        Menu {
            Button("Up") { send(.arrowUp) }
            Button("Down") { send(.arrowDown) }
            Button("Left") { send(.arrowLeft) }
            Button("Right") { send(.arrowRight) }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 17, weight: .semibold))
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
                .font(.system(size: 17, weight: .semibold))
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
                .font(.system(size: 17, weight: .bold, design: .rounded))
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
                .font(.system(size: 17, weight: .semibold))
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
            Button("Clear Modifiers") {
                modifiers.clearAll()
            }
            Button("Gesture Help") {
                showGestureHelp = true
            }
            Menu("Overlay Cursor") {
                Button {
                    preferences.showCursorOverlay = true
                } label: {
                    Label("Show Overlay Cursor", systemImage: preferences.showCursorOverlay ? "checkmark" : "cursorarrow.rays")
                }
                Button {
                    preferences.showCursorOverlay = false
                } label: {
                    Label("Hide Overlay Cursor", systemImage: !preferences.showCursorOverlay ? "checkmark" : "eye.slash")
                }
            }
            Menu("Toolbar Position") {
                Picker("Style", selection: $preferences.toolbarStyle) {
                    Text(ViewerToolbarStyle.dockedFloating.label).tag(ViewerToolbarStyle.dockedFloating)
                    Text(ViewerToolbarStyle.docked.label).tag(ViewerToolbarStyle.docked)
                    Text(ViewerToolbarStyle.floating.label).tag(ViewerToolbarStyle.floating)
                }
                Picker("Placement", selection: $preferences.toolbarPlacement) {
                    ForEach(ViewerToolbarPlacement.allCases) { placement in
                        Label(placement.label, systemImage: placement.icon).tag(placement)
                    }
                }
                Button("Reset Drag Offset") {
                    preferences.toolbarOffset = .zero
                }
            }
            Button("Customize Toolbar") {
                showToolbarCustomization = true
            }
            Button("Hide Controls") {
                controlsVisible = false
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
    }

    private func iconButton(
        systemName: String,
        label: String,
        tint: Color = .primary,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var toolbarItemSections: [[ViewerToolbarItem]] {
        let items = preferences.toolbarItems.filter(toolbarItemIsAvailable)
        var sections: [[ViewerToolbarItem]] = []
        var current: [ViewerToolbarItem] = []
        var currentSection: ToolbarItemSection?

        for item in items {
            let section = toolbarSection(for: item)
            if currentSection == nil || currentSection == section {
                current.append(item)
                currentSection = section
            } else {
                sections.append(current)
                current = [item]
                currentSection = section
            }
        }

        if !current.isEmpty {
            sections.append(current)
        }
        return sections
    }

    private func toolbarItemIsAvailable(_ item: ViewerToolbarItem) -> Bool {
        guard preferences.isToolbarItemVisible(item) else { return false }
        switch item {
        case .resetZoom:
            return !viewport.isIdentity
        case .displays:
            return session.remoteDisplays.count > 1
        default:
            return true
        }
    }

    private func toolbarSection(for item: ViewerToolbarItem) -> ToolbarItemSection {
        switch item {
        case .touchMode:
            return .touch
        case .fitMode, .resetZoom, .displays, .quality:
            return .viewport
        case .disconnect:
            return .disconnect
        case .keyboard, .modifiers, .arrows, .specialKeys, .functionKeys, .shortcuts, .moreActions:
            return .input
        }
    }

    @ViewBuilder
    private func toolbarItem(_ item: ViewerToolbarItem, vertical: Bool) -> some View {
        switch item {
        case .touchMode:
            touchModeMenu
        case .fitMode:
            fitModeButton
        case .resetZoom:
            resetZoomButton
        case .displays:
            displayMenu
        case .quality:
            qualityButton
        case .keyboard:
            keyboardButton
        case .modifiers:
            modifierButtons(vertical: vertical)
        case .arrows:
            arrowsMenu
        case .specialKeys:
            specialKeysMenu
        case .functionKeys:
            functionKeysMenu
        case .shortcuts:
            shortcutsMenu
        case .moreActions:
            actionMenu
        case .disconnect:
            disconnectButton
        }
    }

    private enum ToolbarItemSection {
        case touch
        case viewport
        case input
        case disconnect
    }

    @ViewBuilder
    private func stack<Content: View>(vertical: Bool, @ViewBuilder content: () -> Content) -> some View {
        if vertical {
            VStack(spacing: 7, content: content)
        } else {
            HStack(spacing: 7, content: content)
        }
    }

    private func toolbarSection<Content: View>(
        vertical: Bool,
        prominent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        stack(vertical: vertical, content: content)
            .padding(3)
            .background(
                prominent ? Color.red.opacity(0.14) : Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: vertical ? 22 : 24, style: .continuous)
            )
    }

    private var canControl: Bool {
        session.inputMapper.isControlEnabled
    }

    private func send(_ key: KeyCode, modifiers explicitModifiers: KeyModifiers = []) {
        guard canControl else { return }
        session.inputMapper.sendKey(key, modifiers: explicitModifiers)
    }

    private func clampedOffset(_ offset: CGSize, in size: CGSize, base: CGPoint) -> CGSize {
        let margin: CGFloat = 44
        let minX = margin - base.x
        let maxX = max(minX, size.width - margin - base.x)
        let minY = margin - base.y
        let maxY = max(minY, size.height - margin - base.y)
        return CGSize(
            width: min(max(offset.width, minX), maxX),
            height: min(max(offset.height, minY), maxY)
        )
    }

    private func usesFloatingToolbar(in size: CGSize) -> Bool {
        switch preferences.toolbarStyle {
        case .floating:
            return true
        case .docked:
            return false
        case .native:
            return false
        case .dockedFloating:
            return isPad
        }
    }

    private func resolvedToolbarPlacement(in size: CGSize) -> ViewerToolbarPlacement {
        if preferences.toolbarStyle == .dockedFloating, !isPad, size.width > size.height {
            return .leading
        }
        return preferences.toolbarPlacement
    }

    private func floatingBasePosition(in size: CGSize) -> CGPoint {
        switch resolvedToolbarPlacement(in: size) {
        case .top:
            return CGPoint(x: size.width / 2, y: 68)
        case .bottom:
            return CGPoint(x: size.width / 2, y: size.height - 68)
        case .leading:
            return CGPoint(x: 58, y: size.height / 2)
        case .trailing:
            return CGPoint(x: size.width - 58, y: size.height / 2)
        }
    }

    private func dockedAlignment(for placement: ViewerToolbarPlacement) -> Alignment {
        switch placement {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    private func dockedPadding(for placement: ViewerToolbarPlacement) -> EdgeInsets {
        switch placement {
        case .top:
            return EdgeInsets(top: 10, leading: 10, bottom: 0, trailing: 10)
        case .bottom:
            return EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10)
        case .leading:
            return EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 0)
        case .trailing:
            return EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 8)
        }
    }

    private var toolbarCustomization: some View {
        NavigationStack {
            List {
                Section("Placement") {
                    Picker("Style", selection: $preferences.toolbarStyle) {
                        Text(ViewerToolbarStyle.dockedFloating.label).tag(ViewerToolbarStyle.dockedFloating)
                        Text(ViewerToolbarStyle.docked.label).tag(ViewerToolbarStyle.docked)
                        Text(ViewerToolbarStyle.floating.label).tag(ViewerToolbarStyle.floating)
                    }
                    Picker("Position", selection: $preferences.toolbarPlacement) {
                        ForEach(ViewerToolbarPlacement.allCases) { placement in
                            Label(placement.label, systemImage: placement.icon).tag(placement)
                        }
                    }
                    Button("Reset Floating Position") {
                        preferences.toolbarOffset = .zero
                    }
                }
                Section("Cursor") {
                    Toggle("Show Overlay Cursor", isOn: $preferences.showCursorOverlay)
                }
                Section("Toolbar Items") {
                    ForEach(preferences.toolbarItems) { item in
                        HStack(spacing: 12) {
                            Label(item.label, systemImage: item.icon)
                            Spacer()
                            if item.isRequired {
                                Text("Required")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Toggle(
                                    item.label,
                                    isOn: Binding(
                                        get: { preferences.isToolbarItemVisible(item) },
                                        set: { preferences.setToolbarItem(item, visible: $0) }
                                    )
                                )
                                .labelsHidden()
                            }
                        }
                    }
                    .onMove { source, destination in
                        preferences.moveToolbarItems(from: source, to: destination)
                    }
                }
                Section {
                    Button("Reset Default Toolbar") {
                        preferences.resetToolbarItems()
                    }
                }
            }
            .navigationTitle("Customize Toolbar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showToolbarCustomization = false }
                }
            }
        }
    }

    private var gestureHelp: some View {
        NavigationStack {
            List {
                Section("Touch") {
                    Label("Tap clicks where you touch.", systemImage: "hand.tap")
                    Label("Double tap sends a double click.", systemImage: "hand.tap.fill")
                    Label("Long press starts a drag.", systemImage: "cursorarrow.motionlines")
                    Label("Two-finger tap right-clicks.", systemImage: "contextualmenu.and.cursorarrow")
                    Label("Three-finger tap middle-clicks.", systemImage: "circle.grid.cross")
                }
                Section("Viewport") {
                    Label("Two-finger pinch zooms the local view.", systemImage: "plus.magnifyingglass")
                    Label("Two-finger drag scrolls the remote Mac.", systemImage: "scroll")
                    Label("Two-finger double tap hides or shows controls.", systemImage: "slider.horizontal.3")
                }
                Section("Modifiers") {
                    Label("Tap a modifier for the next action.", systemImage: "shift")
                    Label("Double tap a modifier to lock it.", systemImage: "lock")
                }
            }
            .navigationTitle("Gestures")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showGestureHelp = false }
                }
            }
        }
    }
}
#endif
