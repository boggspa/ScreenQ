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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if controlsVisible {
                    if isPad {
                        floatingToolbar(in: proxy.size)
                    } else if proxy.size.width > proxy.size.height {
                        dockedToolbar(vertical: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                            .padding(.vertical, 10)
                    } else {
                        dockedToolbar(vertical: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
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
        toolbarBody(vertical: isCollapsed)
            .position(x: size.width / 2, y: size.height - 68)
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
                            in: size
                        )
                    }
                    .onEnded { _ in
                        dragStartOffset = nil
                    }
            )
    }

    private func dockedToolbar(vertical: Bool) -> some View {
        toolbarBody(vertical: vertical)
    }

    private func toolbarBody(vertical: Bool) -> some View {
        let axis: Axis.Set = vertical ? .vertical : .horizontal
        return ScrollView(axis, showsIndicators: false) {
            Group {
                if isCollapsed && isPad {
                    stack(vertical: vertical) {
                        statusPill
                        iconButton(systemName: "chevron.up.chevron.down", label: "Expand controls") {
                            isCollapsed = false
                        }
                        iconButton(
                            systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
                            label: isKeyboardActive ? "Hide keyboard" : "Show keyboard",
                            disabled: !canControl
                        ) {
                            isKeyboardActive.toggle()
                        }
                        touchModeMenu
                        actionMenu
                    }
                } else {
                    stack(vertical: vertical) {
                        statusPill
                        iconButton(systemName: "minus", label: isPad ? "Collapse controls" : "Hide controls") {
                            if isPad {
                                isCollapsed = true
                            } else {
                                controlsVisible = false
                            }
                        }
                        iconButton(
                            systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
                            label: isKeyboardActive ? "Hide keyboard" : "Show keyboard",
                            disabled: !canControl
                        ) {
                            isKeyboardActive.toggle()
                        }
                        touchModeMenu
                        iconButton(
                            systemName: fitMode ? "rectangle.arrowtriangle.2.outward" : "rectangle.arrowtriangle.2.inward",
                            label: fitMode ? "Fill screen" : "Fit to screen"
                        ) {
                            fitMode.toggle()
                            preferences.fitMode = fitMode
                        }
                        if !viewport.isIdentity {
                            iconButton(systemName: "minus.magnifyingglass", label: "Reset zoom") {
                                resetViewport()
                            }
                        }
                        displayMenu
                        modifierButtons(vertical: vertical)
                        arrowsMenu
                        specialKeysMenu
                        functionKeysMenu
                        shortcutsMenu
                        actionMenu
                        iconButton(systemName: "xmark.circle", label: "Disconnect", tint: .red) {
                            onDisconnect()
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(
            maxWidth: vertical ? 58 : min(UIScreen.main.bounds.width - 20, 760),
            maxHeight: vertical ? min(UIScreen.main.bounds.height - 20, 620) : 58
        )
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    @ViewBuilder
    private func stack<Content: View>(vertical: Bool, @ViewBuilder content: () -> Content) -> some View {
        if vertical {
            VStack(spacing: 8, content: content)
        } else {
            HStack(spacing: 8, content: content)
        }
    }

    private var canControl: Bool {
        session.inputMapper.isControlEnabled
    }

    private func send(_ key: KeyCode, modifiers explicitModifiers: KeyModifiers = []) {
        guard canControl else { return }
        session.inputMapper.sendKey(key, modifiers: explicitModifiers)
    }

    private func clampedOffset(_ offset: CGSize, in size: CGSize) -> CGSize {
        let maxX = max(0, size.width / 2 - 80)
        let maxY = max(0, size.height / 2 - 50)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
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
