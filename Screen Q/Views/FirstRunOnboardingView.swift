//
//  FirstRunOnboardingView.swift
//  Screen Q
//
//  First-launch onboarding flow. Replaces the previous "single grid of
//  route cards" router with a 4-step TabView:
//
//    0. Welcome   — role pick (Host / Mac Viewer / iOS Viewer)
//    1. Path pick — route cards filtered to the chosen role
//    2. Path setup — per-route preparation (permissions, info, CTAs)
//    3. Verify    — confirmation + Finish
//
//  Dismissal is handled by the parent's sheet binding: completing the
//  flow flips `firstRunOnboardingCompleted` to true and the sheet hides.
//

import SwiftUI

struct FirstRunOnboardingView: View {

    @EnvironmentObject private var app: AppState

    @State private var step: Int = 0
    @State private var selectedRole: DeviceRole?
    @State private var selectedRoute: FirstRunOnboardingRoute?

    private let totalSteps = 4

    var body: some View {
        ZStack {
            ScreenQTheme.heroBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                header

                TabView(selection: $step) {
                    stepWelcome.tag(0)
                    stepPathPick.tag(1)
                    stepPathSetup.tag(2)
                    stepVerify.tag(3)
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                SQOnboardingProgress(total: totalSteps, current: $step)
                    .padding(.horizontal, 24)

                SQOnboardingNavBar(
                    canGoBack: step > 0,
                    canGoForward: canGoForward,
                    nextTitle: step == totalSteps - 1 ? "Finish" : "Next",
                    onBack: { withAnimation(.easeInOut(duration: 0.25)) { step = max(0, step - 1) } },
                    onNext: { handleNext() },
                    trailing: step == 0 ? AnyView(skipLink) : nil
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .padding(.top, 22)
        }
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 780, maxWidth: 880, minHeight: 600, idealHeight: 680)
        #endif
        .onAppear { ensureValidSelections() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ScreenQBrandMark(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Screen Q")
                    .font(.sqTitle)
                Text(stepSubtitle)
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private var stepSubtitle: String {
        switch step {
        case 0: return "Pick your role to begin."
        case 1: return "Choose how you want to use Screen Q."
        case 2: return setupSubtitle
        case 3: return "All set!"
        default: return ""
        }
    }

    private var setupSubtitle: String {
        guard let route = selectedRoute else { return "Path setup." }
        return "\(route.title) setup."
    }

    // MARK: - Step 0 · Welcome + role pick

    private var stepWelcome: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(roleOptions) { option in
                    RoleSelectionCard(
                        role: option,
                        isSelected: selectedRole == option,
                        isEnabled: option.isSupportedOnCurrentPlatform
                    ) {
                        guard option.isSupportedOnCurrentPlatform else { return }
                        SQHaptics.tap()
                        selectedRole = option
                        // If the user changes role mid-flow, drop a stale route pick.
                        if let route = selectedRoute, !routesForRole(option).contains(route) {
                            selectedRoute = nil
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
    }

    /// Currently surfaced as the three primary roles. iOS hides hostMac
    /// automatically because `isSupportedOnCurrentPlatform` is false there.
    private var roleOptions: [DeviceRole] {
        // We surface hostMac + viewer on both platforms (the disabled state
        // on iOS makes the missing capability explicit instead of silent).
        // `appleNativeAlternatives` is intentionally omitted from onboarding
        // — it lives in the in-app help surface.
        [.hostMac, .viewer]
    }

    private var skipLink: some View {
        Button {
            SQHaptics.tap()
            app.completeFirstRunOnboarding()
        } label: {
            Text("Skip setup for now")
                .font(.sqCallout)
                .foregroundColor(.secondary)
                .underline()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip onboarding for now")
    }

    // MARK: - Step 1 · Path pick

    private var stepPathPick: some View {
        ScrollView {
            LazyVGrid(columns: pathColumns, spacing: 14) {
                ForEach(routesForRole(selectedRole ?? .viewer)) { route in
                    FirstRunRouteCard(
                        route: route,
                        isSelected: selectedRoute == route
                    ) {
                        SQHaptics.tap()
                        selectedRoute = route
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
    }

    private var pathColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)]
    }

    private func routesForRole(_ role: DeviceRole) -> [FirstRunOnboardingRoute] {
        switch role {
        case .hostMac:
            return [.hostMac]
        case .viewer, .iosScreenShare, .appleNativeAlternatives:
            return [.connectExistingMac, .useTailscale, .useAppleScreenSharing, .importRDP]
        }
    }

    // MARK: - Step 2 · Path setup

    private var stepPathSetup: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let route = selectedRoute {
                    setupContent(for: route)
                } else {
                    SQEmptyState(
                        icon: "questionmark.circle",
                        title: "Pick a path first",
                        message: "Go back a step and choose how you want to use Screen Q.",
                        tint: ScreenQTheme.cosmicAmber,
                        compact: true
                    )
                    .screenQCard(tint: ScreenQTheme.cosmicAmber)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func setupContent(for route: FirstRunOnboardingRoute) -> some View {
        switch route {
        case .hostMac:
            #if os(macOS)
            HostMacPermissionsSummary(permissions: app.macPermissions)
            #else
            SQEmptyState(
                icon: "desktopcomputer.trianglebadge.exclamationmark",
                title: "Hosting needs macOS",
                message: "Open Screen Q on the Mac you want to share. You can keep using the viewer here.",
                tint: ScreenQTheme.cosmicAmber
            )
            .screenQCard(tint: ScreenQTheme.cosmicAmber)
            #endif

        case .connectExistingMac:
            SQEmptyState(
                icon: "rectangle.connected.to.line.below",
                title: "Nothing to set up",
                message: "You'll add Macs from the Connections tab after onboarding.",
                tint: ScreenQTheme.cosmicCyan
            )
            .screenQCard(tint: ScreenQTheme.cosmicCyan)

        case .useTailscale:
            SQEmptyState(
                icon: "network",
                title: "Connect Tailscale",
                message: "Sign in to your Tailscale account to see your tailnet here.",
                tint: ScreenQTheme.cosmicMint,
                primary: .init("Open Tailscale auth", systemImage: "arrow.right") {
                    SQHaptics.tap()
                    // The Connections hub picks this up after we dismiss.
                    app.pendingConnectionHubStartupAction = .tailnetSetup
                }
            )
            .screenQCard(tint: ScreenQTheme.cosmicMint)

        case .useAppleScreenSharing:
            SQEmptyState(
                icon: "applelogo",
                title: "Apple Screen Sharing",
                message: "We'll connect using the system's vnc:// scheme — no setup needed.",
                tint: ScreenQTheme.cosmicViolet
            )
            .screenQCard(tint: ScreenQTheme.cosmicViolet)

        case .importRDP:
            SQEmptyState(
                icon: "doc.badge.gearshape",
                title: "Import an .rdp profile",
                message: "Drop or pick an .rdp file to import your existing Windows session.",
                tint: ScreenQTheme.cosmicAmber,
                primary: .init("Pick file…", systemImage: "doc.fill") {
                    SQHaptics.tap()
                    // The Connections hub's importer picks this up after dismiss.
                    app.pendingConnectionHubStartupAction = .importRDP
                }
            )
            .screenQCard(tint: ScreenQTheme.cosmicAmber)
        }
    }

    // MARK: - Step 3 · Verify

    private var stepVerify: some View {
        ScrollView {
            VStack(spacing: 14) {
                SQEmptyState(
                    icon: "checkmark.circle.fill",
                    title: "You're ready to go",
                    message: roleSpecificMessage,
                    tint: ScreenQTheme.cosmicMint
                )
                .screenQCard(tint: ScreenQTheme.cosmicMint)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
    }

    private var roleSpecificMessage: String {
        let roleText: String
        switch selectedRole {
        case .hostMac:
            roleText = "Hosting this Mac"
        case .viewer:
            roleText = "Connecting as a viewer"
        case .iosScreenShare:
            roleText = "Sharing this device's screen"
        case .appleNativeAlternatives:
            roleText = "Using Apple-native tools"
        case .none:
            roleText = "Getting started"
        }
        if let route = selectedRoute {
            return "\(roleText) · \(route.title). Tap Finish to open the app."
        }
        return "\(roleText). Tap Finish to open the app."
    }

    // MARK: - Forward gating

    private var canGoForward: Bool {
        switch step {
        case 0: return selectedRole != nil
        case 1: return selectedRoute != nil
        case 2: return true
        case 3: return true
        default: return false
        }
    }

    private func ensureValidSelections() {
        // If the platform doesn't support the currently selected role,
        // clear it so the user is forced through the role picker again.
        if let role = selectedRole, !role.isSupportedOnCurrentPlatform {
            selectedRole = nil
        }
    }

    // MARK: - Nav handlers

    private func handleNext() {
        if step == totalSteps - 1 {
            finishOnboarding()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                step = min(totalSteps - 1, step + 1)
            }
        }
    }

    private func finishOnboarding() {
        SQHaptics.success()
        if let role = selectedRole {
            app.selectRole(role)
        }
        // Delegate to AppState's existing routing helper so the
        // ConnectionHub startup action is set up correctly. This also
        // flips `firstRunOnboardingCompleted = true`, which dismisses
        // the sheet via HomeView's binding.
        app.completeFirstRunOnboarding(route: selectedRoute)
    }
}

// MARK: - Role selection card

private struct RoleSelectionCard: View {
    let role: DeviceRole
    let isSelected: Bool
    let isEnabled: Bool
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ScreenQTheme.accent(tint))
                    Image(systemName: role.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: 44, height: 44)
                .shadow(color: tint.opacity(isEnabled ? 0.45 : 0.0), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(role.title)
                        .font(.sqHeadline)
                        .foregroundColor(.primary)
                    Text(role.subtitle)
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !isEnabled {
                    SQPill(text: platformBadgeText, status: .muted, compact: true)
                } else if isSelected {
                    SQPill(text: "Selected", status: .info, compact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .screenQCard(tint: tint, padding: 16)
            .overlay(
                RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? ScreenQTheme.cosmicCyan : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(role.title)
        .accessibilityHint(isEnabled ? role.subtitle : "Not available on this platform")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tint: Color {
        switch role {
        case .hostMac:                 return ScreenQTheme.cosmicCyan
        case .viewer:                  return ScreenQTheme.cosmicTeal
        case .iosScreenShare:          return ScreenQTheme.cosmicAmber
        case .appleNativeAlternatives: return ScreenQTheme.cosmicViolet
        }
    }

    private var platformBadgeText: String {
        switch role {
        case .hostMac:
            return "macOS only"
        default:
            return "Unavailable"
        }
    }
}

// MARK: - Route card

private struct FirstRunRouteCard: View {
    let route: FirstRunOnboardingRoute
    let isSelected: Bool
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ScreenQTheme.accent(route.tint))
                        Image(systemName: route.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .accessibilityHidden(true)
                    }
                    .frame(width: 44, height: 44)
                    .shadow(color: route.tint.opacity(0.45), radius: 6, x: 0, y: 3)

                    Spacer()
                    if isSelected {
                        SQPill(text: "Selected", status: .info, compact: true)
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .bold))
                            .padding(8)
                            .background(
                                Circle().fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06))
                            )
                            .foregroundColor(.secondary)
                            .accessibilityHidden(true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(route.title)
                        .font(.sqHeadline)
                        .foregroundColor(.primary)
                    Text(route.detail)
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .screenQCard(tint: route.tint, padding: 16)
            .overlay(
                RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? ScreenQTheme.cosmicCyan : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(route.title)
        .accessibilityHint(route.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Host Mac permission summary (macOS only)

#if os(macOS)
/// Compact summary of the three macOS permissions Screen Q's host mode
/// uses. We don't reach for SQSettingsRow (Phase 4 owns that primitive)
/// — instead we lay rows out by hand with `.screenQCard`.
private struct HostMacPermissionsSummary: View {

    @ObservedObject var permissions: MacPermissionsService

    var body: some View {
        VStack(spacing: 10) {
            row(
                title: "Screen Recording",
                detail: screenRecordingDetail,
                status: screenRecordingStatus,
                pillText: screenRecordingPillText
            )
            row(
                title: "Accessibility",
                detail: accessibilityDetail,
                status: accessibilityStatus,
                pillText: accessibilityPillText
            )
            row(
                title: "Local Network",
                detail: "Required to discover Macs over Bonjour. iOS / macOS will prompt the first time we listen.",
                status: localNetworkStatus,
                pillText: localNetworkPillText
            )

            Button {
                SQHaptics.tap()
                permissions.openPrivacyScreenRecording()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                    Text("Open Privacy Settings")
                }
                .font(.sqHeadline)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(ScreenQTheme.cosmicCyan))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Privacy Settings")
            .padding(.top, 6)
        }
        .onAppear { permissions.refresh() }
    }

    private func row(title: String, detail: String, status: SQStatus, pillText: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            SQPill(text: pillText, status: status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenQCard(tint: status.tint, padding: 14)
    }

    // MARK: Mapped statuses

    private var screenRecordingDetail: String {
        switch permissions.screenRecordingStatus {
        case .granted:
            return "Granted. Screen Q can capture this Mac's display."
        case .grantedPendingRestart:
            return "Enabled in System Settings — quit and relaunch Screen Q so it takes effect."
        case .requestedPendingUser:
            return "Open System Settings and enable Screen Q under Screen Recording."
        case .notRequested:
            return "Required to share this Mac's screen. We'll request it when hosting begins."
        }
    }

    private var screenRecordingStatus: SQStatus {
        switch permissions.screenRecordingStatus {
        case .granted:               return .healthy
        case .grantedPendingRestart: return .attention
        case .requestedPendingUser:  return .attention
        case .notRequested:          return .info
        }
    }

    private var screenRecordingPillText: String {
        switch permissions.screenRecordingStatus {
        case .granted:               return "Granted"
        case .grantedPendingRestart: return "Restart"
        case .requestedPendingUser:  return "Pending"
        case .notRequested:          return "Not yet"
        }
    }

    private var accessibilityDetail: String {
        switch permissions.accessibilityStatus {
        case .granted:
            return "Granted. Screen Q can forward keyboard and mouse input."
        case .grantedPendingRestart, .requestedPendingUser:
            return "Open System Settings and enable Screen Q under Accessibility."
        case .notRequested:
            return "Required to forward keyboard and mouse input from a viewer."
        }
    }

    private var accessibilityStatus: SQStatus {
        switch permissions.accessibilityStatus {
        case .granted:                                  return .healthy
        case .grantedPendingRestart, .requestedPendingUser: return .attention
        case .notRequested:                             return .info
        }
    }

    private var accessibilityPillText: String {
        switch permissions.accessibilityStatus {
        case .granted:                                  return "Granted"
        case .grantedPendingRestart, .requestedPendingUser: return "Pending"
        case .notRequested:                             return "Not yet"
        }
    }

    private var localNetworkStatus: SQStatus {
        permissions.localNetworkAttempted ? .healthy : .info
    }

    private var localNetworkPillText: String {
        permissions.localNetworkAttempted ? "Asked" : "Not yet"
    }
}
#endif

// MARK: - Route presentation helpers

private extension FirstRunOnboardingRoute {
    var title: String {
        switch self {
        case .hostMac:
            return "Host this Mac"
        case .connectExistingMac:
            return "Connect to existing Mac"
        case .useTailscale:
            return "Use Tailscale"
        case .useAppleScreenSharing:
            return "Use Apple Screen Sharing"
        case .importRDP:
            return "Import RDP"
        }
    }

    var detail: String {
        switch self {
        case .hostMac:
            return "Open hosting, permissions, pairing, and approval controls for this Mac."
        case .connectExistingMac:
            return "Open a new Screen Q connection by host name, local address, or quick link."
        case .useTailscale:
            return "Configure Tailnet discovery or connect to a known Tailscale name."
        case .useAppleScreenSharing:
            return "Open a Mac Screen Sharing connection for Macs without Screen Q installed."
        case .importRDP:
            return "Open the Windows/RDP route and import an existing .rdp profile."
        }
    }

    var systemImage: String {
        switch self {
        case .hostMac:
            return "desktopcomputer"
        case .connectExistingMac:
            return "display"
        case .useTailscale:
            return "lock.shield"
        case .useAppleScreenSharing:
            return "macwindow"
        case .importRDP:
            return "pc"
        }
    }

    var tint: Color {
        switch self {
        case .hostMac:
            return ScreenQTheme.cosmicCyan
        case .connectExistingMac:
            return ScreenQTheme.cosmicTeal
        case .useTailscale:
            return ScreenQTheme.cosmicMint
        case .useAppleScreenSharing:
            return ScreenQTheme.cosmicViolet
        case .importRDP:
            return ScreenQTheme.cosmicAmber
        }
    }
}
