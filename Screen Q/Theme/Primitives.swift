//
//  Primitives.swift
//  Screen Q  ·  Theme
//
//  Shared view primitives that views compose to stay on-brand without
//  redefining cards, pills, headers, empty/loading/error surfaces in
//  every file.
//
//  Public API:
//    .screenQCard(tint:cornerRadius:padding:)
//    .screenQGlass(cornerRadius:)
//    SQSectionHeader, SQPill, SQDestructiveButton
//    SQEmptyState, SQErrorRecovery, SQLoadingScrim
//

import SwiftUI

// MARK: - Card chrome

/// Soft fill + hairline border + slight shadow. Adapts to colour scheme.
struct ScreenQCardStyle: ViewModifier {
    let tint: Color?
    let cornerRadius: CGFloat
    let padding: CGFloat

    @Environment(\.colorScheme) private var scheme

    init(tint: Color? = nil,
         cornerRadius: CGFloat = ScreenQTheme.cardCornerRadius,
         padding: CGFloat = 18) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.padding = padding
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.6)
            )
            .shadow(color: shadowColor, radius: 14, x: 0, y: 8)
    }

    private var fill: Color {
        let base: Color = scheme == .dark
            ? Color.white.opacity(0.05)
            : Color.white.opacity(0.85)
        if let tint {
            return tint.opacity(scheme == .dark ? 0.10 : 0.06)
        }
        return base
    }

    private var stroke: Color {
        if let tint { return tint.opacity(0.30) }
        return Color.primary.opacity(scheme == .dark ? 0.07 : 0.10)
    }

    private var shadowColor: Color {
        scheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.06)
    }
}

/// Glass / blurred chrome alternative. Falls back to a solid-ish fill on
/// macOS 11.5 where `.ultraThinMaterial` isn't available.
struct ScreenQGlassStyle: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    init(cornerRadius: CGFloat = ScreenQTheme.panelCornerRadius) {
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
    }

    private var fill: Color {
        scheme == .dark
            ? Color.black.opacity(0.55)
            : Color.white.opacity(0.78)
    }

    private var border: Color {
        scheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.06)
    }
}

extension View {
    func screenQCard(
        tint: Color? = nil,
        cornerRadius: CGFloat = ScreenQTheme.cardCornerRadius,
        padding: CGFloat = 18
    ) -> some View {
        modifier(ScreenQCardStyle(tint: tint, cornerRadius: cornerRadius, padding: padding))
    }

    func screenQGlass(
        cornerRadius: CGFloat = ScreenQTheme.panelCornerRadius
    ) -> some View {
        modifier(ScreenQGlassStyle(cornerRadius: cornerRadius))
    }
}

// MARK: - Section header

/// Consistent section header used across every screen. Replaces the 30+
/// ad-hoc `Text(...).font(.headline)` + spacer arrangements scattered
/// through the app.
struct SQSectionHeader: View {

    struct Action {
        let title: String
        let systemImage: String?
        let action: () -> Void
        init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.action = action
        }
    }

    let title: String
    var subtitle: String? = nil
    var action: Action? = nil

    init(_ title: String, subtitle: String? = nil, action: Action? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let action {
                Button(action: action.action) {
                    HStack(spacing: 4) {
                        if let img = action.systemImage {
                            Image(systemName: img)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(action.title)
                            .font(.sqCaption)
                    }
                    .foregroundColor(ScreenQTheme.cosmicCyan)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.title)
            }
        }
    }
}

// MARK: - Status pill

/// Small status capsule with an icon + label. Always pairs colour with an
/// icon — never colour-only.
struct SQPill: View {
    let text: String
    let status: SQStatus
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
                .font(.system(size: compact ? 9 : 10, weight: .bold))
            Text(text)
                .font(.sqCaption)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .foregroundColor(status.tint)
        .background(Capsule().fill(status.tint.opacity(0.18)))
        .overlay(Capsule().stroke(status.tint.opacity(0.55), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text), \(status.accessibilityWord)")
    }
}

// MARK: - Destructive button

/// A button that paints destructive-red only when enabled — avoids the
/// "always-red Stop button" anti-pattern when the action is unavailable.
struct SQDestructiveButton: View {
    let title: String
    var systemImage: String? = "stop.fill"
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let img = systemImage {
                    Image(systemName: img)
                }
                Text(title)
            }
            .font(.sqHeadline)
            .foregroundColor(isEnabled ? .white : .secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(
                    isEnabled
                        ? ScreenQTheme.cosmicRose
                        : Color.secondary.opacity(0.18)
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

// MARK: - Empty state

/// Friendly empty-state surface — gradient icon block + copy + up to two
/// CTAs. Inspired by Apple's stock empty states but stays on-brand.
struct SQEmptyState: View {

    struct Action {
        let title: String
        let systemImage: String?
        let action: () -> Void
        init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.action = action
        }
    }

    let icon: String
    let title: String
    let message: String
    var tint: Color = ScreenQTheme.cosmicCyan
    var primary: Action? = nil
    var secondary: Action? = nil
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            iconBlock
            VStack(spacing: 4) {
                Text(title)
                    .font(compact ? .sqHeadline : .sqTitle)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if primary != nil || secondary != nil {
                actions
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 18 : 28)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }

    private var iconBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ScreenQTheme.accent(tint))
                .frame(width: compact ? 52 : 64, height: compact ? 52 : 64)
                .shadow(color: tint.opacity(0.35), radius: 10, x: 0, y: 4)
            Image(systemName: icon)
                .font(.system(size: compact ? 22 : 26, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let primary {
                Button(action: primary.action) {
                    HStack(spacing: 6) {
                        if let img = primary.systemImage {
                            Image(systemName: img)
                        }
                        Text(primary.title)
                    }
                    .font(.sqHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(ScreenQTheme.accent(tint)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(primary.title)
            }
            if let secondary {
                Button(action: secondary.action) {
                    HStack(spacing: 6) {
                        if let img = secondary.systemImage {
                            Image(systemName: img)
                        }
                        Text(secondary.title)
                    }
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(secondary.title)
            }
        }
    }
}

// MARK: - Error recovery (inline)

/// Inline error surface with Retry + optional secondary action. Replaces
/// hard alerts and orange-text errors. Mirrors `CinematicSessionScreen`'s
/// failure tone without taking the full screen.
struct SQErrorRecovery: View {

    let title: String
    let message: String
    var detail: String? = nil
    var retryTitle: String = "Retry"
    var onRetry: (() -> Void)? = nil
    var secondary: SQEmptyState.Action? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(ScreenQTheme.cosmicRose.opacity(0.18))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(ScreenQTheme.cosmicRose)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                Text(message)
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.sqCaption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if onRetry != nil || secondary != nil {
                    HStack(spacing: 8) {
                        if let onRetry {
                            Button(action: onRetry) {
                                Label(retryTitle, systemImage: "arrow.clockwise")
                                    .font(.sqCallout)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .foregroundColor(.white)
                                    .background(Capsule().fill(ScreenQTheme.cosmicRose))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(retryTitle)
                        }
                        if let secondary {
                            Button(action: secondary.action) {
                                HStack(spacing: 4) {
                                    if let img = secondary.systemImage {
                                        Image(systemName: img)
                                    }
                                    Text(secondary.title)
                                }
                                .font(.sqCallout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .foregroundColor(.primary)
                                .background(
                                    Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(secondary.title)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .screenQCard(tint: ScreenQTheme.cosmicRose, padding: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Loading scrim

/// Translucent overlay used while a background action runs. Drops the
/// `ScreenQActivityTrail` over the calling surface so the content stays
/// visible underneath.
struct SQLoadingScrim: View {
    let title: String
    var subtitle: String? = nil
    var tint: Color = .white

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 10) {
                ScreenQActivityTrail(tint: tint)
                Text(title)
                    .font(.sqHeadline)
                    .foregroundColor(tint)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.sqCaption)
                        .foregroundColor(tint.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: ScreenQTheme.panelCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScreenQTheme.panelCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle ?? "")")
    }
}

#Preview("Primitives") {
    ScrollView {
        VStack(spacing: 18) {
            SQSectionHeader("Saved screens",
                            subtitle: "3 connections · 1 group",
                            action: .init("Add", systemImage: "plus") {})

            HStack {
                SQPill(text: "Encrypted", status: .healthy)
                SQPill(text: "Pending grant", status: .attention)
                SQPill(text: "Offline", status: .error)
                SQPill(text: "Probing…", status: .info)
                SQPill(text: "Idle", status: .muted)
            }

            SQEmptyState(
                icon: "rectangle.connected.to.line.below",
                title: "No saved connections yet",
                message: "Connect to a Mac, PC, or Tailscale device and save it for one-tap access.",
                primary: .init("Quick Connect", systemImage: "bolt.fill") {},
                secondary: .init("Scan nearby", systemImage: "antenna.radiowaves.left.and.right") {}
            )
            .screenQCard()

            SQErrorRecovery(
                title: "Couldn't reach host",
                message: "The Mac may be offline or on a different network.",
                detail: "Last attempt: 2 seconds ago.",
                onRetry: {},
                secondary: .init("Save bug report", systemImage: "ladybug") {}
            )

            HStack {
                SQDestructiveButton(title: "Stop Sharing", isEnabled: true) {}
                SQDestructiveButton(title: "Stop Sharing", isEnabled: false) {}
            }
        }
        .padding()
    }
    .background(ScreenQTheme.heroBackground)
}
