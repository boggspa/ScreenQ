//
//  CinematicSessionScreen.swift
//  Screen Q
//
//  Reusable, branded "in-between" surface used while the viewer is
//  connecting, awaiting approval, paired, failed, or otherwise not yet
//  showing remote pixels. Designed to make the moments before live
//  video feel intentional — not a stock ProgressView.
//
//  Used by RemoteScreenView (Screen Q native), VNCViewerView and
//  RDPViewerView so every connection path has the same polish.
//

import SwiftUI

struct CinematicSessionScreen: View {

    enum Kind {
        case progress
        case failure
        case ended
        case success
    }

    struct ButtonSpec {
        enum Style { case filled, ghost, destructive }
        let title: String
        let systemImage: String
        let style: Style
        let action: () -> Void
    }

    let kind: Kind
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var primaryButton: ButtonSpec? = nil
    var secondaryButton: ButtonSpec? = nil

    var body: some View {
        ZStack {
            ScreenQTheme.cinematicBackdrop
                .ignoresSafeArea()

            // Soft radial highlight behind the card
            RadialGradient(
                colors: [
                    accentTint.opacity(0.22),
                    Color.clear
                ],
                center: .center,
                startRadius: 5,
                endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                hero
                copy
                if primaryButton != nil || secondaryButton != nil {
                    actions
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 480)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.30))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 28, x: 0, y: 18)
            .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        switch kind {
        case .progress:
            VStack(spacing: 14) {
                ScreenQBrandMark(size: 64)
                ScreenQActivityTrail(tint: .white)
            }
        case .failure:
            ZStack {
                Circle().fill(Color.red.opacity(0.22))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.red)
                    .accessibilityHidden(true)
            }
            .frame(width: 70, height: 70)
        case .ended:
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: 70, height: 70)
        case .success:
            ZStack {
                Circle().fill(ScreenQTheme.cosmicMint.opacity(0.25))
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(ScreenQTheme.cosmicMint)
                    .accessibilityHidden(true)
            }
            .frame(width: 70, height: 70)
        }
    }

    private var copy: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let primaryButton {
                cinematicButton(primaryButton, primary: true)
            }
            if let secondaryButton {
                cinematicButton(secondaryButton, primary: false)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func cinematicButton(_ spec: ButtonSpec, primary: Bool) -> some View {
        Button(action: spec.action) {
            Label(spec.title, systemImage: spec.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .foregroundColor(foreground(for: spec.style))
                .background(background(for: spec.style))
        }
        .buttonStyle(.plain)
    }

    private func foreground(for style: ButtonSpec.Style) -> Color {
        switch style {
        case .filled:       return .white
        case .ghost:        return .white.opacity(0.85)
        case .destructive:  return .white
        }
    }

    @ViewBuilder
    private func background(for style: ButtonSpec.Style) -> some View {
        switch style {
        case .filled:
            Capsule().fill(accentTint)
        case .ghost:
            Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
        case .destructive:
            Capsule().fill(Color.red.opacity(0.85))
        }
    }

    private var accentTint: Color {
        switch kind {
        case .progress:     return ScreenQTheme.cosmicCyan
        case .failure:      return .red
        case .ended:        return .white
        case .success:      return ScreenQTheme.cosmicMint
        }
    }
}

// MARK: - Pairing variant

/// Specialised cinematic screen with the 6-digit pairing input embedded.
struct CinematicSessionPairingScreen: View {

    let peerLabel: String
    @Binding var pairingPrompt: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

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
                ZStack {
                    Circle().fill(Color.white.opacity(0.10))
                    Image(systemName: "lock.shield")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: 68, height: 68)

                VStack(spacing: 6) {
                    Text("Pair with \(peerLabel)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text("Enter the 6-digit code shown on the host Mac.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                }

                pairingField

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        Label("Cancel", systemImage: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .foregroundColor(.white.opacity(0.85))
                            .background(
                                Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onSubmit) {
                        Label("Connect", systemImage: "arrow.forward")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .foregroundColor(.white)
                            .background(
                                Capsule().fill(canSubmit ? ScreenQTheme.cosmicCyan : Color.gray.opacity(0.45))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 480)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.30))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 28, x: 0, y: 18)
            .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canSubmit: Bool {
        pairingPrompt.count == 6
    }

    private var pairingField: some View {
        TextField("", text: $pairingPrompt)
            .font(.system(size: 30, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(width: 260)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
            )
            #if os(iOS)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            #endif
            .onChange(of: pairingPrompt) { newValue in
                // Strip non-digits and cap to 6.
                let digits = newValue.filter { $0.isNumber }
                let limited = String(digits.prefix(6))
                if limited != newValue {
                    pairingPrompt = limited
                }
            }
    }
}

// MARK: - Shared session indicators

/// Pulsing status dot. When `active` is true the dot fades in and out
/// to convey "live"; otherwise it sits solid for terminal states.
struct LiveStatusDot: View {
    let color: Color
    let active: Bool
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.30))
                .frame(width: 14, height: 14)
                .scaleEffect(pulsing && active ? 1.55 : 1.0)
                .opacity(pulsing && active ? 0 : 0.55)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            guard active else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

/// Small status capsule with an icon, used in viewer / host status bars
/// for things like "Encrypted", "Recording 00:42", etc.
struct SessionStatusBadge: View {
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigitIfAvailable()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundColor(tint)
        .background(
            Capsule().fill(tint.opacity(0.18))
        )
        .overlay(
            Capsule().stroke(tint.opacity(0.55), lineWidth: 0.5)
        )
    }
}

private extension Text {
    /// `.monospacedDigit()` is macOS 12+, so we apply a compatible
    /// alternative when targeting older OSes.
    func monospacedDigitIfAvailable() -> Text {
        if #available(macOS 12.0, iOS 15.0, *) {
            return self.monospacedDigit()
        }
        return self
    }
}

#Preview("Connecting") {
    CinematicSessionScreen(
        kind: .progress,
        title: "Reaching Chris's MacBook Pro",
        subtitle: "Negotiating an encrypted Screen Q session…",
        primaryButton: nil,
        secondaryButton: CinematicSessionScreen.ButtonSpec(
            title: "Cancel",
            systemImage: "xmark",
            style: .ghost,
            action: {}
        )
    )
}

#Preview("Failure") {
    CinematicSessionScreen(
        kind: .failure,
        title: "Couldn't reach host",
        subtitle: "The Mac may be offline or on a different network.",
        primaryButton: CinematicSessionScreen.ButtonSpec(
            title: "Disconnect",
            systemImage: "xmark.circle",
            style: .destructive,
            action: {}
        ),
        secondaryButton: nil
    )
}
