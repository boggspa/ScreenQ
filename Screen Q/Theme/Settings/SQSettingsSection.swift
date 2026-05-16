//
//  SQSettingsSection.swift
//  Screen Q  ·  Theme · Settings
//
//  Grouped-section primitive used inside the unified Settings pane. Wraps
//  a stack of `SQSettingsRow` (or any) views in a `screenQCard` with a
//  consistent padding and an `SQSectionHeader` above. Mirrors the visual
//  rhythm of Apple's modern System Settings while staying on-brand.
//
//  Callers compose rows inside the trailing closure. To get the hair-line
//  dividers between rows you can call `.sqSettingsDivider()` between row
//  pairs, or use the convenience `SQSettingsRows { ... }` view which adds
//  them automatically.
//
//  Deployment targets: macOS 11.5+, iOS 17+. No `.tint`, `.borderedProminent`,
//  `.ultraThinMaterial`, or trailing-closure `overlay(alignment:)` calls.
//

import SwiftUI

/// Card-grouped section with header. Used by `SettingsScene` tab bodies
/// to organise related toggles, pickers, and detail rows.
struct SQSettingsSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SQSectionHeader(title, subtitle: subtitle)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .screenQCard(
                cornerRadius: ScreenQTheme.panelCornerRadius,
                padding: 14
            )
        }
    }
}

/// Slim divider tuned for use between rows inside `SQSettingsSection`.
extension View {
    func sqSettingsDivider() -> some View {
        Divider()
            .opacity(0.4)
            .padding(.vertical, 4)
    }
}

#Preview("SQSettingsSection") {
    ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            SQSettingsSection("General", subtitle: "Appearance and basics") {
                SQSettingsRow(
                    icon: "paintpalette.fill",
                    iconTint: ScreenQTheme.cosmicCyan,
                    title: "Appearance",
                    subtitle: "Match the system theme"
                ) {
                    Text("System")
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                }
                Divider().opacity(0.4)
                SQSettingsRow(
                    icon: "globe",
                    iconTint: ScreenQTheme.cosmicMint,
                    title: "Language",
                    subtitle: "English (United States)"
                )
            }

            SQSettingsSection("Security") {
                SQSettingsRow(
                    icon: "lock.shield",
                    iconTint: ScreenQTheme.cosmicViolet,
                    title: "Trusted Devices"
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
    .background(ScreenQTheme.heroBackground)
}
