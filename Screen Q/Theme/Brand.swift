//
//  Brand.swift
//  Screen Q  ·  Theme
//
//  Brand composites — the SQ lockup, the cinematic activity trail, and
//  the splash surface used while the app boots / loads top-level data.
//
//  Public API:
//    ScreenQBrandMark
//    ScreenQActivityTrail
//    SQSplash
//

import SwiftUI

// MARK: - Brand mark

/// Gradient-filled rounded rectangle with the brand glyph centred. Used
/// inside hero headers, loading screens, the onboarding sheet, etc.
struct ScreenQBrandMark: View {
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 12
    var glyphScale: CGFloat = 0.55

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            ScreenQTheme.cosmicCyan,
                            ScreenQTheme.cosmicViolet
                        ],
                        startPoint: .topLeading,
                        endPoint:   .bottomTrailing
                    )
                )
            Image(systemName: "rectangle.connected.to.line.below")
                .resizable()
                .scaledToFit()
                .padding(size * (1.0 - glyphScale) / 2)
                .foregroundColor(.white.opacity(0.95))
        }
        .frame(width: size, height: size)
        .shadow(color: ScreenQTheme.cosmicViolet.opacity(0.35), radius: 8, x: 0, y: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Activity trail

/// Animated 3-dot pulse used in handshake / loading states.
struct ScreenQActivityTrail: View {
    var tint: Color = .white
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .opacity(opacity(for: idx))
                    .scaleEffect(scale(for: idx))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }

    private func opacity(for idx: Int) -> Double {
        let offset = (phase + Double(idx) / 3.0).truncatingRemainder(dividingBy: 1)
        return 0.35 + 0.55 * (1 - abs(0.5 - offset) * 2)
    }

    private func scale(for idx: Int) -> Double {
        let offset = (phase + Double(idx) / 3.0).truncatingRemainder(dividingBy: 1)
        return 0.85 + 0.4 * (1 - abs(0.5 - offset) * 2)
    }
}

// MARK: - Splash

/// Full-bleed brand splash with cinematic backdrop. Use as a top-level
/// loading surface while initial state hydrates (iCloud bootstrap,
/// permissions probe, etc.).
struct SQSplash: View {
    var title: String = "Screen Q"
    var subtitle: String? = "Loading your remote desktop…"

    var body: some View {
        ZStack {
            ScreenQTheme.cinematicBackdrop
                .ignoresSafeArea()
            RadialGradient(
                colors: [
                    ScreenQTheme.cosmicCyan.opacity(0.22),
                    Color.clear
                ],
                center: .center,
                startRadius: 5,
                endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                ScreenQBrandMark(size: 72)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.sqTitle)
                        .foregroundColor(.white)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.sqCallout)
                            .foregroundColor(.white.opacity(0.72))
                    }
                }
                ScreenQActivityTrail(tint: .white)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Screen Q is loading")
    }
}
