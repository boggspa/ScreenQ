//
//  PermissionsView.swift
//  Screen Q
//
//  State-driven macOS permissions checklist surfaced inside HostMacView.
//  Each row reacts to the matching `MacPermissionStatus` so we never
//  show an inert "Request" button after TCC has already been asked once.
//

#if os(macOS)
import SwiftUI

struct PermissionsView: View {

    @EnvironmentObject private var permissions: MacPermissionsService
    @State private var confirmRelaunch = false
    @State private var isRefreshing = false

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                if allGranted {
                    allGrantedSummary
                } else {
                    PermissionRow(
                        title: "Screen Recording",
                        subtitle: "Capture this Mac's display via ScreenCaptureKit.",
                        tint: ScreenQTheme.cosmicCyan,
                        icon: "rectangle.dashed.badge.record",
                        status: permissions.screenRecordingStatus,
                        primary: primaryAction(for: .screenRecording),
                        secondary: secondaryAction(for: .screenRecording),
                        helperText: helperText(for: .screenRecording)
                    )

                    PermissionRow(
                        title: "Accessibility",
                        subtitle: "Inject mouse and keyboard events for remote control.",
                        tint: ScreenQTheme.cosmicViolet,
                        icon: "hand.point.up.left.fill",
                        status: permissions.accessibilityStatus,
                        primary: primaryAction(for: .accessibility),
                        secondary: secondaryAction(for: .accessibility),
                        helperText: helperText(for: .accessibility)
                    )

                    LocalNetworkRow(attempted: permissions.localNetworkAttempted)

                    Label("macOS picks up new grants on relaunch",
                          systemImage: "info.circle")
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                        .padding(.top, 2)
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        triggerRefresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.sqCaption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: permissions.screenRecordingStatus)
            .animation(.easeInOut(duration: 0.25), value: permissions.accessibilityStatus)
            .animation(.easeInOut(duration: 0.25), value: permissions.localNetworkAttempted)
            .animation(.easeInOut(duration: 0.25), value: allGranted)
            .alert(isPresented: $confirmRelaunch) {
                Alert(
                    title: Text("Relaunch Screen Q?"),
                    message: Text("macOS only picks up new Screen Recording grants on a fresh launch. Screen Q will quit and reopen — any active session will end."),
                    primaryButton: .default(Text("Relaunch Screen Q")) {
                        permissions.relaunchApp()
                    },
                    secondaryButton: .cancel()
                )
            }

            if isRefreshing {
                SQLoadingScrim(title: "Checking permissions…")
                    .transition(.opacity)
            }
        }
    }

    private var allGranted: Bool {
        permissions.screenRecordingStatus == .granted
            && permissions.accessibilityStatus == .granted
            && permissions.localNetworkAttempted
    }

    private var allGrantedSummary: some View {
        VStack(alignment: .center, spacing: 6) {
            SQPill(text: "All permissions granted", status: .healthy)
            Text("Screen Q is ready to host.")
                .font(.sqCallout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .screenQCard(tint: ScreenQTheme.cosmicMint, padding: 14)
    }

    private func triggerRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            permissions.refresh()
            // Give the scrim a moment so the user perceives the refresh —
            // the underlying probe is synchronous and otherwise invisible.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await MainActor.run { isRefreshing = false }
        }
    }

    // MARK: - Action wiring

    private enum Kind { case screenRecording, accessibility }

    private func primaryAction(for kind: Kind) -> PermissionRow.Action? {
        let status = (kind == .screenRecording) ? permissions.screenRecordingStatus : permissions.accessibilityStatus
        switch status {
        case .granted:
            return nil
        case .notRequested:
            return PermissionRow.Action(
                label: "Allow…",
                systemImage: "checkmark.shield",
                role: .primary
            ) {
                switch kind {
                case .screenRecording: permissions.requestScreenRecording()
                case .accessibility:   permissions.requestAccessibility()
                }
            }
        case .requestedPendingUser, .grantedPendingRestart:
            return PermissionRow.Action(
                label: "Open Privacy Settings",
                systemImage: "gearshape.fill",
                role: .primary
            ) {
                switch kind {
                case .screenRecording: permissions.openPrivacyScreenRecording()
                case .accessibility:   permissions.openPrivacyAccessibility()
                }
            }
        }
    }

    private func secondaryAction(for kind: Kind) -> PermissionRow.Action? {
        let status = (kind == .screenRecording) ? permissions.screenRecordingStatus : permissions.accessibilityStatus
        switch (kind, status) {
        case (.screenRecording, .requestedPendingUser),
             (.screenRecording, .grantedPendingRestart):
            return PermissionRow.Action(
                label: "Relaunch Screen Q",
                systemImage: "arrow.triangle.2.circlepath",
                role: .secondary
            ) {
                confirmRelaunch = true
            }
        default:
            return nil
        }
    }

    private func helperText(for kind: Kind) -> String? {
        let status = (kind == .screenRecording) ? permissions.screenRecordingStatus : permissions.accessibilityStatus
        switch (kind, status) {
        case (.screenRecording, .requestedPendingUser):
            return "Enable Screen Q in System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch."
        case (.accessibility, .requestedPendingUser):
            return "Enable Screen Q in System Settings ▸ Privacy & Security ▸ Accessibility. No relaunch needed."
        case (_, .grantedPendingRestart):
            return "macOS picks up new grants on relaunch."
        default:
            return nil
        }
    }
}

// MARK: - Row

private struct PermissionRow: View {

    struct Action {
        enum Role { case primary, secondary }
        let label: String
        let systemImage: String
        let role: Role
        let perform: () -> Void
    }

    let title: String
    let subtitle: String
    let tint: Color
    let icon: String
    let status: MacPermissionStatus
    let primary: Action?
    let secondary: Action?
    let helperText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(tint)
                        .accessibilityHidden(true)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.sqHeadline)
                        Spacer(minLength: 8)
                        SQPill(text: statusLabel, status: statusToken)
                    }
                    Text(subtitle)
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let helperText {
                Text(helperText)
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 48)
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                Spacer().frame(width: 36)
                if let primary {
                    Button {
                        primary.perform()
                    } label: {
                        Label(primary.label, systemImage: primary.systemImage)
                            .font(.sqCaption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(tint)
                            )
                    }
                    .buttonStyle(.plain)
                }
                if let secondary {
                    Button {
                        secondary.perform()
                    } label: {
                        Label(secondary.label, systemImage: secondary.systemImage)
                            .font(.sqCaption)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().strokeBorder(
                                    Color.secondary.opacity(0.5),
                                    lineWidth: 0.75
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .screenQCard(tint: cardTint, cornerRadius: 12, padding: 12)
    }

    private var statusToken: SQStatus {
        switch status {
        case .granted:                return .healthy
        case .notRequested:           return .muted
        case .requestedPendingUser:   return .attention
        case .grantedPendingRestart:  return .attention
        }
    }

    private var statusLabel: String {
        switch status {
        case .granted:                return "Granted"
        case .notRequested:           return "Needed"
        case .requestedPendingUser:   return "Action needed"
        case .grantedPendingRestart:  return "Relaunch to apply"
        }
    }

    /// Card tint follows status urgency rather than the row's brand tint —
    /// granted rows feel calm, action-needed rows feel warm.
    private var cardTint: Color {
        switch status {
        case .granted:                return ScreenQTheme.cosmicMint
        case .requestedPendingUser,
             .grantedPendingRestart:  return ScreenQTheme.cosmicAmber
        case .notRequested:           return tint
        }
    }
}

private struct LocalNetworkRow: View {
    let attempted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ScreenQTheme.cosmicTeal.opacity(0.16))
                Image(systemName: "network")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(ScreenQTheme.cosmicTeal)
                    .accessibilityHidden(true)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Local Network")
                        .font(.sqHeadline)
                    Spacer(minLength: 8)
                    SQPill(
                        text: attempted ? "Granted" : "Needed",
                        status: attempted ? .healthy : .muted
                    )
                }
                Text("Bonjour discovery prompt — automatically requested the first time you start hosting.")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .screenQCard(
            tint: attempted ? ScreenQTheme.cosmicMint : ScreenQTheme.cosmicTeal,
            cornerRadius: 12,
            padding: 12
        )
    }
}

#Preview {
    PermissionsView()
        .environmentObject(MacPermissionsService())
        .padding()
        .frame(width: 520)
}
#endif
