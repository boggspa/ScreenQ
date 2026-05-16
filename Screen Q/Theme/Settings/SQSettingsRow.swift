//
//  SQSettingsRow.swift
//  Screen Q  ·  Theme · Settings
//
//  Single row inside an `SQSettingsSection`. Renders a 28×28 rounded-square
//  gradient icon, a title (`Font.sqHeadline`), optional subtitle
//  (`Font.sqCaption`), and a trailing slot for toggles / chevrons / pickers
//  / inline buttons.
//
//  Deployment targets: macOS 11.5+, iOS 17+. No `.tint`, `.borderedProminent`,
//  `.ultraThinMaterial`, or trailing-closure `overlay(alignment:)` calls.
//

import SwiftUI

/// Row primitive for the Settings pane. Use the trailing slot to add a
/// Toggle, Picker, button, chevron, or arbitrary inline detail.
struct SQSettingsRow<Trailing: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconBlock
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var iconBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ScreenQTheme.accent(iconTint))
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: 28, height: 28)
        .shadow(color: iconTint.opacity(0.30), radius: 4, x: 0, y: 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Convenience initializers

extension SQSettingsRow where Trailing == EmptyView {
    init(icon: String, iconTint: Color, title: String, subtitle: String? = nil) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

/// A small inline chevron used as the trailing affordance for rows that
/// navigate elsewhere (sidebar/list entries, deep links).
struct SQSettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .accessibilityHidden(true)
    }
}

/// A small inline detail label used as the trailing affordance for rows
/// that surface a value without a control.
struct SQSettingsDetail: View {
    let value: String
    var body: some View {
        Text(value)
            .font(.sqCallout)
            .foregroundColor(.secondary)
    }
}

#Preview("SQSettingsRow") {
    VStack(alignment: .leading, spacing: 0) {
        SQSettingsRow(
            icon: "paintpalette.fill",
            iconTint: ScreenQTheme.cosmicCyan,
            title: "Appearance",
            subtitle: "System, Light, or Dark"
        ) {
            SQSettingsDetail(value: "System")
        }
        Divider().opacity(0.4)
        SQSettingsRow(
            icon: "globe",
            iconTint: ScreenQTheme.cosmicMint,
            title: "Language",
            subtitle: "English (United States)"
        )
        Divider().opacity(0.4)
        SQSettingsRow(
            icon: "lock.shield",
            iconTint: ScreenQTheme.cosmicViolet,
            title: "Security & Trust"
        ) {
            SQSettingsChevron()
        }
    }
    .screenQCard(padding: 14)
    .padding()
    .background(ScreenQTheme.heroBackground)
}
