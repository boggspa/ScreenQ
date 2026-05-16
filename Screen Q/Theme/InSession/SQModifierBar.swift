//
//  SQModifierBar.swift
//  Screen Q  ·  Theme / In-Session
//
//  Visible row of Shift/Ctrl/Cmd/Opt chips. Each chip shows three latch
//  states (off / momentary / locked) so the user can always see what
//  modifier is armed before the next click or keystroke.
//
//  This file owns RENDERING ONLY. The state model still lives in
//  `ModifierLatchController` — this view receives a Snapshot, calls back
//  on toggle, and lets the controller decide what the next state should
//  be. Tap → momentary, long-press → lock (when `stickyOnLongPress`).
//
//  Deployment targets: macOS 11.5+, iOS 17+. No `.tint`, no `.indigo`/
//  `.teal`, no 2-arg trailing `.onChange` outside `#if os(iOS)`.
//

import SwiftUI

struct SQModifierBar: View {

    enum Modifier: Hashable {
        case shift
        case control
        case option
        case command

        var label: String {
            switch self {
            case .shift:   return "Shift"
            case .control: return "Control"
            case .option:  return "Option"
            case .command: return "Command"
            }
        }

        var textSymbol: String {
            switch self {
            case .shift:   return "⇧"
            case .control: return "⌃"
            case .option:  return "⌥"
            case .command: return "⌘"
            }
        }

        var shortLabel: String {
            switch self {
            case .shift:   return "Shift"
            case .control: return "Ctrl"
            case .option:  return "Opt"
            case .command: return "Cmd"
            }
        }
    }

    enum LatchState: Equatable {
        case off
        case momentary
        case locked
    }

    struct Snapshot: Equatable {
        var shift: LatchState
        var control: LatchState
        var option: LatchState
        var command: LatchState

        init(shift: LatchState = .off,
             control: LatchState = .off,
             option: LatchState = .off,
             command: LatchState = .off) {
            self.shift = shift
            self.control = control
            self.option = option
            self.command = command
        }

        func state(for modifier: Modifier) -> LatchState {
            switch modifier {
            case .shift:   return shift
            case .control: return control
            case .option:  return option
            case .command: return command
            }
        }
    }

    enum Orientation { case horizontal, vertical }

    let snapshot: Snapshot
    var orientation: Orientation = .horizontal
    var stickyOnLongPress: Bool = true
    var enabled: Bool = true
    let onToggle: (Modifier, LatchState) -> Void

    var body: some View {
        Group {
            if orientation == .horizontal {
                HStack(spacing: 6) {
                    chips
                }
            } else {
                VStack(spacing: 6) {
                    chips
                }
            }
        }
        .opacity(enabled ? 1.0 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modifier keys")
    }

    @ViewBuilder
    private var chips: some View {
        chip(for: .shift)
        chip(for: .control)
        chip(for: .option)
        chip(for: .command)
    }

    private func chip(for modifier: Modifier) -> some View {
        let state = snapshot.state(for: modifier)
        return SQModifierChip(
            modifier: modifier,
            state: state,
            enabled: enabled,
            stickyOnLongPress: stickyOnLongPress,
            onTap: {
                SQHaptics.tap()
                onToggle(modifier, .momentary)
            },
            onLock: {
                SQHaptics.bump()
                onToggle(modifier, .locked)
            }
        )
    }
}

private struct SQModifierChip: View {

    let modifier: SQModifierBar.Modifier
    let state: SQModifierBar.LatchState
    let enabled: Bool
    let stickyOnLongPress: Bool
    let onTap: () -> Void
    let onLock: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: { if enabled { onTap() } }) {
                Text(modifier.textSymbol)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .frame(width: 38, height: 38)
                    .foregroundColor(foreground)
                    .background(
                        ZStack {
                            fillCircle
                            if state == .momentary {
                                Circle()
                                    .stroke(ScreenQTheme.cosmicCyan.opacity(0.85), lineWidth: 0.8)
                            }
                        }
                    )
                    .clipShape(Circle())
                    .shadow(
                        color: glowColor,
                        radius: state == .momentary ? 6 : 0,
                        x: 0,
                        y: 0
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        guard enabled, stickyOnLongPress else { return }
                        onLock()
                    }
            )
            .accessibilityLabel("\(modifier.label) modifier")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(stickyOnLongPress ? "Tap to arm, long-press to lock." : "Tap to arm for the next keystroke.")

            if state == .locked {
                // Tiny STICKY pill overlay so locked state is unambiguous.
                Text("STICKY")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(ScreenQTheme.cosmicAmber))
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var fillCircle: some View {
        switch state {
        case .off:
            Circle().fill(Color.primary.opacity(0.10))
        case .momentary:
            Circle().fill(ScreenQTheme.accent(ScreenQTheme.cosmicCyan))
        case .locked:
            Circle().fill(ScreenQTheme.cosmicCyan)
        }
    }

    private var foreground: Color {
        state == .off ? .primary : .white
    }

    private var glowColor: Color {
        switch state {
        case .momentary: return ScreenQTheme.cosmicCyan.opacity(0.55)
        case .locked:    return ScreenQTheme.cosmicCyan.opacity(0.40)
        case .off:       return .clear
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .off:       return "Off"
        case .momentary: return "Armed"
        case .locked:    return "Locked"
        }
    }
}

// MARK: - Bridge to ModifierLatchController

extension ModifierLatchController {
    /// Render-ready snapshot of every modifier's current latch state.
    var sqModifierSnapshot: SQModifierBar.Snapshot {
        SQModifierBar.Snapshot(
            shift:   SQModifierBar.LatchState(from: state(for: .shift)),
            control: SQModifierBar.LatchState(from: state(for: .control)),
            option:  SQModifierBar.LatchState(from: state(for: .option)),
            command: SQModifierBar.LatchState(from: state(for: .command))
        )
    }

    /// Apply a tap (momentary toggle) or long-press (lock) gesture on a
    /// `SQModifierBar.Modifier`. Keeps the rendering view ignorant of the
    /// controller's actual state machine.
    func apply(_ modifier: SQModifierBar.Modifier, gesture: SQModifierBar.LatchState) {
        let remote = modifier.asRemoteModifier
        switch gesture {
        case .off, .momentary:
            toggleMomentary(remote)
        case .locked:
            toggleLocked(remote)
        }
    }
}

extension SQModifierBar.Modifier {
    var asRemoteModifier: RemoteModifier {
        switch self {
        case .shift:   return .shift
        case .control: return .control
        case .option:  return .option
        case .command: return .command
        }
    }
}

extension SQModifierBar.LatchState {
    init(from controller: ModifierLatchState) {
        switch controller {
        case .off:        self = .off
        case .momentary:  self = .momentary
        case .locked:     self = .locked
        }
    }
}

#Preview("SQModifierBar — Horizontal") {
    VStack(spacing: 14) {
        SQModifierBar(
            snapshot: .init(shift: .momentary, control: .off, option: .locked, command: .off),
            onToggle: { _, _ in }
        )
        SQModifierBar(
            snapshot: .init(shift: .off, control: .momentary, option: .momentary, command: .locked),
            orientation: .horizontal,
            stickyOnLongPress: true,
            enabled: true,
            onToggle: { _, _ in }
        )
        SQModifierBar(
            snapshot: .init(),
            orientation: .horizontal,
            enabled: false,
            onToggle: { _, _ in }
        )
    }
    .padding(20)
    .background(ScreenQTheme.heroBackground)
}
