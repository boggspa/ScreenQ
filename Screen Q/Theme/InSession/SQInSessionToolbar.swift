//
//  SQInSessionToolbar.swift
//  Screen Q  ·  Theme / In-Session
//
//  Unified in-session toolbar shell. Used by every viewer (Screen Q
//  native, VNC, RDP) and the iOS session control surface. Its job is the
//  CHROME: a `.screenQGlass()` capsule/rectangle that aligns content
//  horizontally or vertically, embeds an optional `SQModifierBar`
//  inline, and ALWAYS exposes a `gear` end-cap so toolbar customisation
//  is discoverable.
//
//  The toolbar does NOT own positioning, drag, or condense logic — those
//  stay with the call-site so the various viewers can keep their
//  per-protocol placement preferences. The toolbar only knows about
//  orientation and style.
//
//  Deployment targets: macOS 11.5+, iOS 17+. No `.tint`, `.indigo`,
//  `.teal`, `.borderedProminent`, `.ultraThinMaterial`. Use the cosmic
//  palette and `.screenQGlass()`.
//

import SwiftUI

// MARK: - Toolbar placement / style (top-level so callers don't have to
// reach through a generic type to spell them out).

enum SQInSessionToolbarPlacement { case bottom, top, leading, trailing }
enum SQInSessionToolbarStyle { case docked, floating, condensed }

struct SQInSessionToolbar<Content: View, Trailing: View>: View {

    typealias Placement = SQInSessionToolbarPlacement
    typealias Style = SQInSessionToolbarStyle

    let placement: Placement
    let style: Style
    var modifiers: SQModifierBar.Snapshot?
    var modifiersEnabled: Bool = true
    var stickyModifierOnLongPress: Bool = true
    var onModifierToggle: ((SQModifierBar.Modifier, SQModifierBar.LatchState) -> Void)?
    var onCustomize: (() -> Void)?

    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    private var isVertical: Bool {
        placement == .leading || placement == .trailing
    }

    var body: some View {
        Group {
            if isVertical {
                VStack(spacing: spacing) {
                    contentStack
                }
            } else {
                HStack(spacing: spacing) {
                    contentStack
                }
            }
        }
        .padding(padding)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session controls")
    }

    @ViewBuilder
    private var contentStack: some View {
        content()

        if let snapshot = modifiers, let onToggle = onModifierToggle {
            divider
            SQModifierBar(
                snapshot: snapshot,
                orientation: isVertical ? .vertical : .horizontal,
                stickyOnLongPress: stickyModifierOnLongPress,
                enabled: modifiersEnabled,
                onToggle: onToggle
            )
        }

        let trailingContent = trailing()
        if !(trailingContent is EmptyView) {
            divider
            trailingContent
        }

        if onCustomize != nil {
            divider
            customizeButton
        }
    }

    private var divider: some View {
        Group {
            if isVertical {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 24, height: 0.6)
                    .padding(.vertical, 2)
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 0.6, height: 24)
                    .padding(.horizontal, 2)
            }
        }
        .accessibilityHidden(true)
    }

    private var customizeButton: some View {
        Button(action: {
            SQHaptics.tap()
            onCustomize?()
        }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ScreenQTheme.cosmicCyan)
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(ScreenQTheme.cosmicCyan.opacity(0.12))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Customize toolbar")
        .accessibilityHint("Re-order or hide buttons in this toolbar.")
    }

    // MARK: - Style hooks

    private var padding: CGFloat {
        switch style {
        case .docked:    return 7
        case .floating:  return 7
        case .condensed: return 4
        }
    }

    private var spacing: CGFloat {
        switch style {
        case .docked:    return 6
        case .floating:  return 6
        case .condensed: return 4
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .docked:    return 22
        case .floating:  return 22
        case .condensed: return 18
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .docked, .floating:
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(glassFill)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(glassStroke, lineWidth: 0.75)
            }
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 8)
        case .condensed:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(glassFill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
        }
    }

    private var glassFill: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(0.55),
                Color.black.opacity(0.40)
            ],
            startPoint: .top,
            endPoint:   .bottom
        )
    }

    private var glassStroke: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.30),
                Color.white.opacity(0.05)
            ],
            startPoint: .top,
            endPoint:   .bottom
        )
    }
}

// MARK: - Convenience overload for "no trailing slot"

extension SQInSessionToolbar where Trailing == EmptyView {
    init(
        placement: Placement,
        style: Style,
        modifiers: SQModifierBar.Snapshot? = nil,
        modifiersEnabled: Bool = true,
        stickyModifierOnLongPress: Bool = true,
        onModifierToggle: ((SQModifierBar.Modifier, SQModifierBar.LatchState) -> Void)? = nil,
        onCustomize: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            placement: placement,
            style: style,
            modifiers: modifiers,
            modifiersEnabled: modifiersEnabled,
            stickyModifierOnLongPress: stickyModifierOnLongPress,
            onModifierToggle: onModifierToggle,
            onCustomize: onCustomize,
            content: content,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - SQToolbarButton helper (used by all viewers)

/// A small, consistent icon button used inside `SQInSessionToolbar`.
/// Mirrors the spacing/sizing every viewer used to redefine privately.
struct SQToolbarButton: View {
    let systemName: String
    let label: String
    var tint: Color = .white
    var size: CGFloat = 38
    var isOn: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: {
            guard !isDisabled else { return }
            SQHaptics.tap()
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(foreground)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(isOn
                                  ? ScreenQTheme.cosmicCyan.opacity(0.85)
                                  : Color.clear)
                )
                .overlay(
                    isOn
                    ? AnyView(Circle().stroke(ScreenQTheme.cosmicCyan.opacity(0.95), lineWidth: 0.8))
                    : AnyView(EmptyView())
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var foreground: Color {
        if isOn { return .white }
        return tint
    }
}

#Preview("SQInSessionToolbar — floating") {
    VStack(spacing: 30) {
        SQInSessionToolbar(
            placement: .bottom,
            style: .floating,
            modifiers: .init(shift: .momentary, control: .off, option: .locked, command: .off),
            onModifierToggle: { _, _ in },
            onCustomize: {},
            content: {
                HStack(spacing: 6) {
                    SQToolbarButton(systemName: "keyboard", label: "Keyboard") {}
                    SQToolbarButton(systemName: "minus.magnifyingglass", label: "Reset zoom") {}
                    SQToolbarButton(systemName: "rectangle.arrowtriangle.2.inward", label: "Fit") {}
                }
            },
            trailing: {
                SQToolbarButton(systemName: "xmark", label: "Disconnect", tint: ScreenQTheme.cosmicRose) {}
            }
        )

        SQInSessionToolbar(
            placement: .bottom,
            style: .condensed,
            onCustomize: {}
        ) {
            HStack(spacing: 4) {
                SQToolbarButton(systemName: "plus", label: "Expand") {}
            }
        }
    }
    .padding(30)
    .background(Color.black)
}
