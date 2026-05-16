//
//  Tokens.swift
//  Screen Q  ·  Theme
//
//  Centralised design tokens for Screen Q. Imported everywhere — keep the
//  surface API stable. Callers expect the following symbols to exist:
//
//    ScreenQTheme.brandAccent / cosmic*  /  heroBackground / cinematicBackdrop / accent(_:)
//    ScreenQTheme.cardCornerRadius / panelCornerRadius / pillCornerRadius
//    SQStatus  ·  Font.sqDisplay / sqTitle / sqHeadline / sqBody / sqCallout / sqCaption
//
//  Deployment targets: macOS 11.5+, iOS 17+. No `.tint`, `.borderedProminent`,
//  `.teal`, `.ultraThinMaterial` symbols at the API level.
//

import SwiftUI

// MARK: - Brand palette + gradients

enum ScreenQTheme {

    // Brand accent — defers to AccentColor in the asset catalogue.
    static let brandAccent = Color.accentColor

    // Cosmic palette. Hand-rolled so we don't depend on .indigo / .teal
    // (macOS 12+).
    static let cosmicIndigo  = Color(red: 0.21, green: 0.21, blue: 0.45)
    static let cosmicViolet  = Color(red: 0.36, green: 0.21, blue: 0.62)
    static let cosmicCyan    = Color(red: 0.20, green: 0.55, blue: 0.85)
    static let cosmicTeal    = Color(red: 0.10, green: 0.55, blue: 0.65)
    static let cosmicAmber   = Color(red: 0.95, green: 0.66, blue: 0.20)
    static let cosmicRose    = Color(red: 0.92, green: 0.36, blue: 0.55)
    static let cosmicMint    = Color(red: 0.28, green: 0.72, blue: 0.55)

    // Subtle full-bleed gradient for hero / hub surfaces.
    static let heroBackground = LinearGradient(
        colors: [
            cosmicIndigo.opacity(0.12),
            cosmicViolet.opacity(0.06),
            Color.clear
        ],
        startPoint: .topLeading,
        endPoint:   .bottomTrailing
    )

    // Deep wash used behind cinematic loading / handshake screens.
    static let cinematicBackdrop = LinearGradient(
        colors: [
            Color.black,
            cosmicIndigo.opacity(0.95),
            cosmicViolet.opacity(0.85)
        ],
        startPoint: .top,
        endPoint:   .bottom
    )

    static func accent(_ tint: Color) -> LinearGradient {
        LinearGradient(
            colors: [tint.opacity(0.85), tint.opacity(0.55)],
            startPoint: .topLeading,
            endPoint:   .bottomTrailing
        )
    }

    // Geometry
    static let cardCornerRadius: CGFloat = 16
    static let panelCornerRadius: CGFloat = 14
    static let pillCornerRadius: CGFloat = 10
}

// MARK: - SQStatus: semantic status tokens

/// Semantic status used for pills, dots, banners. Colour + icon are
/// always paired so we stay colourblind-safe.
enum SQStatus: Equatable {
    case healthy
    case attention
    case error
    case info
    case muted

    var tint: Color {
        switch self {
        case .healthy:   return ScreenQTheme.cosmicMint
        case .attention: return ScreenQTheme.cosmicAmber
        case .error:     return ScreenQTheme.cosmicRose
        case .info:      return ScreenQTheme.cosmicCyan
        case .muted:     return Color.secondary
        }
    }

    var systemImage: String {
        switch self {
        case .healthy:   return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .error:     return "xmark.octagon.fill"
        case .info:      return "info.circle.fill"
        case .muted:     return "circle.fill"
        }
    }

    var accessibilityWord: String {
        switch self {
        case .healthy:   return "OK"
        case .attention: return "Attention"
        case .error:     return "Error"
        case .info:      return "Info"
        case .muted:     return "Idle"
        }
    }
}

// MARK: - Typography scale

extension Font {
    /// 28pt rounded bold — top-of-screen hero copy.
    static let sqDisplay  = Font.system(size: 28, weight: .bold,     design: .rounded)
    /// 22pt rounded bold — section + sheet titles.
    static let sqTitle    = Font.system(size: 22, weight: .bold,     design: .rounded)
    /// 17pt semibold — primary content headlines, button labels.
    static let sqHeadline = Font.system(size: 17, weight: .semibold, design: .rounded)
    /// 15pt regular — body copy, list rows.
    static let sqBody     = Font.system(size: 15, weight: .regular,  design: .rounded)
    /// 13pt regular — secondary descriptions, helper text.
    static let sqCallout  = Font.system(size: 13, weight: .regular,  design: .rounded)
    /// 11pt medium — pill labels, captions, status text.
    static let sqCaption  = Font.system(size: 11, weight: .medium,   design: .rounded)
}
