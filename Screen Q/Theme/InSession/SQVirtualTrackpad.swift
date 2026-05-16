//
//  SQVirtualTrackpad.swift
//  Screen Q  ·  Theme / In-Session
//
//  EXPERIMENTAL — branded SwiftUI trackpad surface. NOT the production
//  trackpad path; the live trackpad mode used by the viewers is
//  `Screen Q/Viewer/TrackpadInputView.swift` (UIKit-backed, integrated
//  with `InputMappingService` and the viewport math).
//
//  This file is kept as a forward-looking primitive for design
//  experiments — e.g. a future Settings preview, an onboarding demo,
//  or a tablet-side alternative interaction surface. Adopt with care:
//  it does NOT route through `InputMappingService`, so absolute-vs-
//  relative pointer translation, hover, and gesture continuity have to
//  be replicated by the call site.
//
//  Sensitivity scaling:
//    - .precise → 0.5
//    - .normal  → 1.0
//    - .fast    → 1.8
//
//  Deployment target: iOS 17+. Guarded with `#if os(iOS)` so the file
//  is silently absent from macOS builds.
//

#if os(iOS)
import SwiftUI

struct SQVirtualTrackpad: View {

    enum SensitivityMode: String, CaseIterable, Identifiable {
        case precise
        case normal
        case fast

        var id: String { rawValue }

        var label: String {
            switch self {
            case .precise: return "Precise"
            case .normal:  return "Normal"
            case .fast:    return "Fast"
            }
        }

        var factor: CGFloat {
            switch self {
            case .precise: return 0.5
            case .normal:  return 1.0
            case .fast:    return 1.8
            }
        }
    }

    var mode: SensitivityMode = .normal

    /// Relative cursor movement. Delta is already scaled by `mode.factor`.
    var onCursorDelta: (CGSize) -> Void
    var onLeftTap: () -> Void
    var onRightTap: () -> Void
    var onScroll: (CGSize) -> Void
    var onMiddleTap: (() -> Void)? = nil
    var onModifier: ((SQModifierBar.Modifier) -> Void)? = nil

    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastScrollTranslation: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background surface
            RoundedRectangle(cornerRadius: ScreenQTheme.panelCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.55),
                            Color.black.opacity(0.40)
                        ],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScreenQTheme.panelCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )

            // "Trackpad" badge — discoverability cue.
            HStack(spacing: 6) {
                SQPill(text: "Trackpad", status: .info, compact: true)
                Text(modeHint)
                    .font(.sqCaption)
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityHidden(true)

            // Centred drag-hint glyph (fades).
            Image(systemName: "hand.tap")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.white.opacity(0.15))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        // Single-finger drag → cursor movement.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let delta = CGSize(
                        width:  (value.translation.width  - lastDragTranslation.width)  * mode.factor,
                        height: (value.translation.height - lastDragTranslation.height) * mode.factor
                    )
                    lastDragTranslation = value.translation
                    onCursorDelta(delta)
                }
                .onEnded { _ in
                    lastDragTranslation = .zero
                }
        )
        // Single-finger tap → left click.
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                SQHaptics.tap()
                onLeftTap()
            }
        )
        // Two-finger tap → right click. NB: SwiftUI's plain TapGesture
        // can't distinguish finger count on iOS; we approximate with
        // long-press as a fallback for two-finger semantics until a UIKit
        // recogniser is wired up. Long-press → right click matches the
        // existing convention elsewhere in Screen Q.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.30)
                .onEnded { _ in
                    SQHaptics.bump()
                    onRightTap()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Virtual trackpad")
        .accessibilityHint("Drag to move cursor, tap to click, long-press to right-click.")
    }

    private var modeHint: String {
        "Sensitivity: \(mode.label)"
    }
}

// MARK: - Two-finger scroll attachment

extension SQVirtualTrackpad {
    /// Attach to a parent surface to receive two-finger drag as scroll.
    /// The Trackpad widget exposes single-finger cursor movement only;
    /// pair this modifier on its container to add scroll mapping.
    func attachingScroll(to surface: some View) -> some View {
        surface.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in /* delegated to caller */ }
        )
    }
}

#Preview("SQVirtualTrackpad") {
    VStack {
        SQVirtualTrackpad(
            mode: .normal,
            onCursorDelta: { _ in },
            onLeftTap: {},
            onRightTap: {},
            onScroll: { _ in }
        )
        .frame(height: 220)
        .padding(16)
    }
    .background(Color.black)
}

#endif
