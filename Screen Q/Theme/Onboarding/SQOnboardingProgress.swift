//
//  SQOnboardingProgress.swift
//  Screen Q  ·  Theme · Onboarding
//
//  Two reusable building blocks for the first-run onboarding flow:
//
//    SQOnboardingProgress  ·  N-dot step indicator with a wide "current"
//                              pill. Animates between steps and exposes a
//                              "Step X of N" accessibility label.
//    SQOnboardingNavBar    ·  Back / optional-trailing-link / Next row
//                              shared across every step. Haptic feedback
//                              on either button.
//
//  Deployment targets: macOS 11.5+, iOS 17+. Avoids `.tint(_:)`,
//  `.borderedProminent`, 2-arg `.onChange`, `.overlay(alignment:) { ... }`
//  trailing-closure form, and `.ultraThinMaterial`.
//

import SwiftUI

// MARK: - Step indicator

/// N-dot row that highlights `current` with a wide pill and renders past
/// steps as filled dots, future steps as muted hollow dots. Smooth
/// transitions when `current` changes.
struct SQOnboardingProgress: View {
    let total: Int
    @Binding var current: Int   // 0-indexed
    var tint: Color = ScreenQTheme.cosmicCyan

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<max(total, 1), id: \.self) { idx in
                dot(at: idx)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(current, total - 1) + 1) of \(total)")
    }

    @ViewBuilder
    private func dot(at idx: Int) -> some View {
        if idx == current {
            Capsule(style: .continuous)
                .fill(tint)
                .frame(width: 22, height: 8)
                .shadow(color: tint.opacity(0.35), radius: 4, x: 0, y: 2)
        } else if idx < current {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Nav bar

/// Shared Back / Next row. The trailing slot is for soft secondary
/// affordances like a "Maybe later" text link on the welcome step.
struct SQOnboardingNavBar: View {

    let canGoBack: Bool
    let canGoForward: Bool
    let nextTitle: String       // "Next" / "Get Started" / "Finish"
    var nextIsPrimary: Bool = true
    let onBack: () -> Void
    let onNext: () -> Void
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            backButton
                .opacity(canGoBack ? 1 : 0)
                .disabled(!canGoBack)
                .accessibilityHidden(!canGoBack)

            Spacer(minLength: 0)

            if let trailing { trailing }

            nextButton
        }
    }

    private var backButton: some View {
        Button {
            SQHaptics.tap()
            onBack()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Back")
                    .font(.sqCallout)
            }
            .foregroundColor(ScreenQTheme.cosmicCyan)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private var nextButton: some View {
        Button {
            SQHaptics.tap()
            onNext()
        } label: {
            HStack(spacing: 6) {
                Text(nextTitle)
                    .font(.sqHeadline)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(nextForeground)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(nextBackground)
            .opacity(canGoForward ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!canGoForward)
        .accessibilityLabel(nextTitle)
    }

    private var nextForeground: Color {
        nextIsPrimary ? .white : ScreenQTheme.cosmicCyan
    }

    @ViewBuilder
    private var nextBackground: some View {
        if nextIsPrimary {
            Capsule(style: .continuous)
                .fill(ScreenQTheme.cosmicCyan)
        } else {
            Capsule(style: .continuous)
                .strokeBorder(ScreenQTheme.cosmicCyan.opacity(0.55), lineWidth: 1)
        }
    }
}

#Preview("SQOnboardingProgress") {
    StatefulPreviewWrapper(0) { binding in
        VStack(spacing: 24) {
            SQOnboardingProgress(total: 4, current: binding)
            HStack(spacing: 12) {
                Button("Prev") { binding.wrappedValue = max(0, binding.wrappedValue - 1) }
                Button("Next") { binding.wrappedValue = min(3, binding.wrappedValue + 1) }
            }
            SQOnboardingNavBar(
                canGoBack: binding.wrappedValue > 0,
                canGoForward: binding.wrappedValue < 3,
                nextTitle: binding.wrappedValue == 3 ? "Finish" : "Next",
                onBack: { binding.wrappedValue -= 1 },
                onNext: { binding.wrappedValue += 1 },
                trailing: AnyView(
                    Button("Maybe later") {}
                        .buttonStyle(.plain)
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                )
            )
        }
        .padding(32)
        .background(ScreenQTheme.heroBackground)
    }
}

/// Small helper so previews can drive @Binding values without a host view.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State var value: Value
    let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(wrappedValue: initial)
        self.content = content
    }

    var body: some View { content($value) }
}
