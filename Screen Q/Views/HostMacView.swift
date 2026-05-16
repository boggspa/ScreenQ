//
//  HostMacView.swift
//  Screen Q
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI

struct HostMacView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HostMacContent(host: app.macHost)
            .environmentObject(app)
    }
}

private struct HostMacContent: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var host: MacHostRuntime
    @State private var showStopConfirm = false
    @State private var showRelaunchConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let banner = permissionsBanner {
                    banner
                }
                permissionsCard
                displayCard

                if showsIdleEmptyState {
                    idleEmptyState
                } else {
                    advertiseCard
                }

                if host.isSharing { connectInfoCard }
                if host.isSharing { viewerPreviewTile }
                curtainModeCard
                permissionsGrantCard
                pairingCard
                sessionsCard
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.3), value: host.isSharing)
            .animation(.easeInOut(duration: 0.3), value: showsIdleEmptyState)
        }
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
        .navigationTitle("Host this Mac")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SQDestructiveButton(
                    title: "Stop Sharing",
                    systemImage: "stop.fill",
                    isEnabled: host.isSharing
                ) {
                    showStopConfirm = true
                }
            }
        }
        .alert(isPresented: $showStopConfirm) {
            Alert(
                title: Text("Stop sharing this Mac?"),
                message: Text("All connected viewers will be disconnected. You can re-share at any time."),
                primaryButton: .destructive(Text("Stop")) { host.stopHosting() },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            Task { await host.refreshForHostSurface() }
        }
    }

    // MARK: - Permissions banner

    /// Renders the prominent action banner when something is blocking
    /// the host from going live. Returns `nil` when permissions are
    /// healthy so the layout doesn't reserve space.
    @ViewBuilder
    private var permissionsBannerView: some View {
        let screen = app.macPermissions.screenRecordingStatus
        let access = app.macPermissions.accessibilityStatus

        switch (screen, access) {
        case (.granted, .granted), (.granted, .notRequested):
            EmptyView()
        case (_, _):
            HostPermissionsBanner(
                screenStatus: screen,
                accessibilityStatus: access,
                onPrimary: handleBannerPrimary,
                onRelaunch: { showRelaunchConfirm = true },
                onOpenSettings: handleBannerOpenSettings
            )
            .alert(isPresented: $showRelaunchConfirm) {
                Alert(
                    title: Text("Relaunch Screen Q?"),
                    message: Text("macOS only picks up new Screen Recording grants on a fresh launch. Screen Q will quit and reopen — any active session will end."),
                    primaryButton: .default(Text("Relaunch Screen Q")) {
                        app.macPermissions.relaunchApp()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var permissionsBanner: AnyView? {
        let screen = app.macPermissions.screenRecordingStatus
        let access = app.macPermissions.accessibilityStatus
        if case .granted = screen, case .granted = access { return nil }
        if case .granted = screen, case .notRequested = access { return nil }
        return AnyView(permissionsBannerView)
    }

    private func handleBannerPrimary() {
        let screen = app.macPermissions.screenRecordingStatus
        let access = app.macPermissions.accessibilityStatus

        // Prioritise Screen Recording because hosting can't start without it.
        switch screen {
        case .notRequested:
            app.macPermissions.requestScreenRecording()
            return
        case .requestedPendingUser, .grantedPendingRestart:
            app.macPermissions.openPrivacyScreenRecording()
            return
        case .granted:
            break
        }

        switch access {
        case .notRequested:
            app.macPermissions.requestAccessibility()
        case .requestedPendingUser, .grantedPendingRestart:
            app.macPermissions.openPrivacyAccessibility()
        case .granted:
            break
        }
    }

    private func handleBannerOpenSettings() {
        let screen = app.macPermissions.screenRecordingStatus
        if screen != .granted {
            app.macPermissions.openPrivacyScreenRecording()
        } else {
            app.macPermissions.openPrivacyAccessibility()
        }
    }

    // MARK: - State helpers

    private var permissionsReady: Bool {
        app.macPermissions.screenRecordingStatus == .granted
            && (app.macPermissions.accessibilityStatus == .granted
                || app.macPermissions.accessibilityStatus == .notRequested)
    }

    private var showsIdleEmptyState: Bool {
        !host.isSharing && host.readyToHost && permissionsReady
    }

    // MARK: - Cards

    private var idleEmptyState: some View {
        SQEmptyState(
            icon: "rectangle.on.rectangle",
            title: "Not sharing yet",
            message: "Start sharing to let trusted viewers see this Mac.",
            tint: ScreenQTheme.cosmicCyan,
            primary: .init("Start Sharing", systemImage: "play.fill") {
                Task { await host.startHosting() }
            },
            secondary: .init("View Only Mode", systemImage: "eye") {
                host.viewOnly.toggle()
            }
        )
        .screenQCard(tint: ScreenQTheme.cosmicCyan)
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SQSectionHeader("Permissions",
                            subtitle: permissionsSubtitle)
            PermissionsView()
                .environmentObject(app.macPermissions)
        }
        .screenQCard(tint: permissionsCardTint)
    }

    private var permissionsSubtitle: String {
        let screen = app.macPermissions.screenRecordingStatus
        let access = app.macPermissions.accessibilityStatus
        if screen == .granted && access == .granted { return "All set — ready to host." }
        if screen == .granted { return "Screen Recording granted." }
        return "Action needed before hosting."
    }

    private var permissionsCardTint: Color {
        let screen = app.macPermissions.screenRecordingStatus
        let access = app.macPermissions.accessibilityStatus
        if screen == .granted && (access == .granted || access == .notRequested) {
            return ScreenQTheme.cosmicMint
        }
        return ScreenQTheme.cosmicAmber
    }

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SQSectionHeader("Display",
                            subtitle: "Choose what to share with connected viewers.")
            if app.displaySelection.displays.isEmpty {
                SQEmptyState(
                    icon: "display.trianglebadge.exclamationmark",
                    title: "No displays detected",
                    message: "Grant Screen Recording, then click Refresh.",
                    tint: ScreenQTheme.cosmicTeal,
                    primary: .init("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            await app.displaySelection.refreshUsingSCShareableContent()
                            if #available(macOS 12.3, *) {
                                await app.captureTargetService.refresh()
                            }
                        }
                    },
                    compact: true
                )
            } else {
                Picker("Display", selection: Binding(
                    get: { app.displaySelection.selectedDisplayID ?? app.displaySelection.displays.first?.id ?? 0 },
                    set: { displayID in
                        app.displaySelection.selectedDisplayID = displayID
                        if #available(macOS 12.3, *) {
                            app.captureTargetService.selectDisplayTarget(displayID)
                        }
                    }
                )) {
                    ForEach(app.displaySelection.displayOptions()) { d in
                        Text("\(d.name) - \(d.pixelWidth)x\(d.pixelHeight)")
                            .tag(d.id)
                    }
                }
                .pickerStyle(.menu)
                if #available(macOS 12.3, *) {
                    shareTargetPicker
                }

                HStack {
                    Button("Refresh Displays") {
                        Task {
                            await app.displaySelection.refreshUsingSCShareableContent()
                            if #available(macOS 12.3, *) {
                                await app.captureTargetService.refresh()
                            }
                        }
                    }
                    .font(.sqCaption)
                    Spacer()
                }
            }
        }
        .screenQCard(tint: ScreenQTheme.cosmicTeal)
    }

    @available(macOS 12.3, *)
    private var shareTargetPicker: some View {
        Picker("Share Target", selection: Binding(
            get: { app.captureTargetService.selectedTargetID ?? "" },
            set: { app.captureTargetService.selectedTargetID = $0.isEmpty ? nil : $0 }
        )) {
            ForEach(app.captureTargetService.targets) { target in
                Text(shareTargetLabel(target))
                    .tag(target.id)
            }
        }
        .pickerStyle(.menu)
    }

    @available(macOS 12.3, *)
    private func shareTargetLabel(_ target: CaptureTargetSelectionService.CaptureTargetOption) -> String {
        if let detail = target.detail {
            return "\(target.name) - \(detail)"
        }
        return target.name
    }

    private var advertiseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SQSectionHeader("Advertise on local network",
                            subtitle: host.isSharing ? "Live on the LAN." : "Idle.")

            if host.isSharing {
                HStack(spacing: 8) {
                    LiveStatusDot(color: ScreenQTheme.cosmicMint, active: true)
                    SQPill(
                        text: "Advertising on local network",
                        status: .healthy
                    )
                    Spacer()
                }
            }

            HStack {
                Button(host.isSharing ? "Hosting…" : "Start Hosting") {
                    Task { await host.startHosting() }
                }
                .disabled(host.isSharing || !host.readyToHost)
                .buttonStyle(.bordered)

                Spacer()

                Text("Bonjour: _screenq._tcp - port \(ScreenQProtocol.defaultPort)")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
            }
            Toggle("Auto-start hosting on launch", isOn: Binding(
                get: { host.autoStartHosting },
                set: { host.autoStartHosting = $0 }
            ))
            .font(.sqCallout)
            .foregroundColor(.secondary)
            Toggle("Share clipboard", isOn: Binding(
                get: { host.enableClipboard },
                set: { host.enableClipboard = $0 }
            ))
            .font(.sqCallout)
            .foregroundColor(.secondary)
            Toggle("Forward audio", isOn: Binding(
                get: { host.enableAudio },
                set: { host.enableAudio = $0 }
            ))
            .font(.sqCallout)
            .foregroundColor(.secondary)
        }
        .screenQCard(tint: ScreenQTheme.cosmicCyan)
    }

    /// Live preview tile shown while hosting so the host can confirm at
    /// a glance what viewers are seeing. The capture frame isn't currently
    /// published from `MacScreenCaptureService` (frames go straight to
    /// per-viewer encoders), so this surface stays in its "waiting" state
    /// until a future wiring change exposes the latest CGImage to the UI.
    /// TODO: wire to MacScreenCaptureService.currentFrame once a
    /// host-side thumbnail publisher exists.
    private var viewerPreviewTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SQSectionHeader("Viewers see this", subtitle: "Live thumbnail")
                Spacer()
            }
            Group {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 200)
                    VStack(spacing: 8) {
                        ScreenQActivityTrail(tint: ScreenQTheme.cosmicCyan)
                        Text("Waiting for first frame…")
                            .font(.sqCallout)
                            .foregroundColor(.secondary)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
            }
            Text("Updates a few times a second once viewers connect.")
                .font(.sqCaption)
                .foregroundColor(.secondary)
        }
        .screenQCard(tint: ScreenQTheme.cosmicCyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live preview of what viewers see")
    }

    private var connectInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SQSectionHeader("Connect from another device",
                            subtitle: "Give your viewer one of these addresses.")
            Text("Use any address with port \(host.listeningPort):")
                .font(.sqCaption)
                .foregroundColor(.secondary)

            if host.listeningAddresses.isEmpty {
                SQErrorRecovery(
                    title: "No connectable addresses",
                    message: "Check that Wi-Fi or Ethernet is connected.",
                    retryTitle: "Refresh",
                    onRetry: {
                        Task { await host.refreshListeningInfo() }
                    }
                )
            } else {
                ForEach(host.listeningAddresses) { iface in
                    HStack(spacing: 8) {
                        Image(systemName: iface.kind == .tailscale ? "network" : "wifi")
                            .foregroundColor(iface.kind == .tailscale
                                             ? ScreenQTheme.cosmicCyan
                                             : ScreenQTheme.cosmicMint)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(iface.address):\(host.listeningPort)")
                                .font(.system(.body, design: .monospaced))

                            Text(iface.humanLabel)
                                .font(.sqCaption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(iface.address):\(host.listeningPort)", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                        .accessibilityLabel("Copy address")
                    }
                    .padding(.vertical, 4)
                }
            }

            Text("Bonjour (same LAN) discovers automatically. For Tailscale or VPN, viewers use Manual Connect.")
                .font(.sqCaption)
                .foregroundColor(.secondary)
        }
        .screenQCard(tint: ScreenQTheme.cosmicCyan)
        .onAppear {
            Task { await host.refreshListeningInfo() }
        }
    }

    private var curtainModeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(
                    get: { host.viewOnly },
                    set: { host.viewOnly = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("View Only Mode")
                            .font(.sqHeadline)
                        Text(host.viewOnly
                             ? "Viewers can see this Mac but cannot take control."
                             : "Viewers can take control when granted.")
                            .font(.sqCaption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if host.viewOnly {
                    SQPill(text: "On", status: .info)
                }
            }
        }
        .screenQCard(tint: host.viewOnly ? ScreenQTheme.cosmicViolet : nil)
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SQSectionHeader("Pairing",
                            subtitle: "Codes expire after 5 minutes.")
            HStack(alignment: .firstTextBaseline) {
                Text("Code")
                    .font(.sqHeadline)
                Text(host.pairingCode)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))

                Spacer()
                Button("Regenerate") { host.regeneratePairingCode() }
                    .font(.sqCaption)
            }
            Text("Tell your viewer this code. The host still decides whether to trust or allow each connection.")
                .font(.sqCaption)
                .foregroundColor(.secondary)
            if !host.pendingRequests.isEmpty {
                Divider()
                Text("Incoming requests")
                    .font(.sqHeadline)
                ForEach(host.pendingRequests) { req in
                    PairingRequestRow(request: req, host: host)
                }
            }
        }
        .screenQCard(tint: host.pendingRequests.isEmpty ? nil : ScreenQTheme.cosmicAmber)
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SQSectionHeader("Sessions",
                            subtitle: host.hostConnections.isEmpty
                                ? nil
                                : "\(host.hostConnections.count) active")
            if host.hostConnections.isEmpty {
                if host.isSharing {
                    SQEmptyState(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Waiting for viewers",
                        message: "Share your pairing code or address to invite a viewer.",
                        tint: ScreenQTheme.cosmicCyan,
                        compact: true
                    )
                } else {
                    SQEmptyState(
                        icon: "rectangle.on.rectangle",
                        title: "Not hosting",
                        message: "Start hosting to accept viewer connections.",
                        tint: ScreenQTheme.cosmicAmber,
                        compact: true
                    )
                }
            } else {
                ForEach(host.hostConnections) { box in
                    HostSessionRow(box: box, host: host)
                }
            }
        }
        .screenQCard()
    }

    private var permissionsGrantCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SQSectionHeader("Viewer Permissions",
                            subtitle: "Choose what connected viewers can do.")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(PermissionSet.allCases, id: \.label) { item in
                    Toggle(isOn: Binding(
                        get: { host.permissions.contains(item.flag) },
                        set: { enabled in
                            if enabled {
                                host.permissions.insert(item.flag)
                            } else {
                                host.permissions.remove(item.flag)
                            }
                        }
                    )) {
                        Label(item.label, systemImage: item.icon)
                            .font(.sqCallout)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack(spacing: 12) {
                Button("Full Access") { host.permissions = .fullAccess }
                    .font(.sqCaption)
                Button("Standard") { host.permissions = .standard }
                    .font(.sqCaption)
                Button("View Only") { host.permissions = .viewOnly }
                    .font(.sqCaption)
            }
        }
        .screenQCard(tint: ScreenQTheme.cosmicIndigo)
    }
}

private struct PairingRequestRow: View {
    let request: PairingRequest
    @ObservedObject var host: MacHostRuntime

    @State private var now: Date = Date()
    private let waitTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(ScreenQTheme.accent(ScreenQTheme.cosmicAmber))
                    Image(systemName: request.trustedReconnect ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.viewer.displayName)
                        .font(.sqHeadline)
                        .lineLimit(1)
                    Text(identityLine)
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(waitText)
                    }
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Waiting \(waitText)")
                }

                Spacer()

                SQPill(
                    text: request.trustedReconnect ? "Trusted reconnect" : "Awaiting trust",
                    status: .attention,
                    compact: true
                )
            }

            if !request.trustedReconnect {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Code")
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                    Text(request.claimedCode)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.bold)
                    if host.pairingCodeMatches(request) {
                        SQPill(text: "Matches host", status: .healthy, compact: true)
                    } else {
                        SQPill(text: "No match", status: .error, compact: true)
                    }
                    Spacer()
                }
            } else {
                Text("Policy: \(host.accessPolicy(for: request).displayName)")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Spacer()
                SQDestructiveButton(
                    title: "Reject",
                    systemImage: "xmark",
                    isEnabled: true
                ) {
                    Task { await host.reject(request) }
                }
                Button {
                    Task { await host.approve(request) }
                } label: {
                    Label(
                        request.trustedReconnect ? "Allow" : "Trust",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.sqHeadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(
                            host.pairingCodeMatches(request)
                                ? ScreenQTheme.cosmicMint
                                : Color.secondary.opacity(0.25)
                        )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!host.pairingCodeMatches(request))
                .help(host.pairingCodeMatches(request)
                      ? "Approve this pairing request"
                      : "The pairing code does not match — ask the viewer to re-enter it.")
            }
        }
        .padding(.vertical, 4)
        .screenQCard(tint: ScreenQTheme.cosmicAmber, cornerRadius: 12, padding: 12)
        .onReceive(waitTimer) { now = $0 }
        .accessibilityElement(children: .contain)
    }

    private var identityLine: String {
        var parts: [String] = [request.viewer.platform.human]
        if let fp = request.identityFingerprint, !fp.isEmpty {
            parts.append("ID \(fp.prefix(8))")
        }
        return parts.joined(separator: " · ")
    }

    private var waitText: String {
        let elapsed = max(0, Int(now.timeIntervalSince(request.receivedAt)))
        if elapsed < 60 {
            return "Waiting \(elapsed)s"
        }
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return "Waiting \(minutes)m \(seconds)s"
    }
}

private struct HostSessionRow: View {
    @ObservedObject var box: HostSessionBox
    @ObservedObject var host: MacHostRuntime

    var body: some View {
        HStack {
            Image(systemName: "rectangle.connected.to.line.below")
                .foregroundColor(ScreenQTheme.cosmicCyan)
                .accessibilityHidden(true)
            Text(box.peerName)
                .font(.sqBody)
            Spacer()
            Text(box.state.humanDescription)
                .foregroundColor(.secondary)
                .font(.sqCaption)
            if box.state.isActive && box.encryptionStatusKnown {
                SQPill(
                    text: box.encryptionEnabled ? "Encrypted" : "Unencrypted",
                    status: box.encryptionEnabled ? .healthy : .attention,
                    compact: true
                )
            }
            Button {
                Task { await host.disconnect(box) }
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundColor(ScreenQTheme.cosmicRose)
            }
            .buttonStyle(.plain)
            .help("Disconnect viewer")
            .accessibilityLabel("Disconnect viewer")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }
}

private extension TrustedPeerAccessPolicy {
    var displayName: String {
        switch self {
        case .askEveryTime: return "Ask every time"
        case .alwaysAllow: return "Always allow"
        case .alwaysDeny: return "Always deny"
        }
    }
}

private struct HostPermissionsBanner: View {
    let screenStatus: MacPermissionStatus
    let accessibilityStatus: MacPermissionStatus
    let onPrimary: () -> Void
    let onRelaunch: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.20))
                Image(systemName: iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.sqHeadline)
                Text(message)
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: onPrimary) {
                        Label(primaryLabel, systemImage: primaryIcon)
                            .font(.sqCaption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(tint)
                            )
                    }
                    .buttonStyle(.plain)

                    if showsRelaunch {
                        Button(action: onRelaunch) {
                            Label("Relaunch Screen Q", systemImage: "arrow.triangle.2.circlepath")
                                .font(.sqCaption)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(.plain)
                    } else if showsOpenSettings {
                        Button(action: onOpenSettings) {
                            Label("Open Privacy Settings", systemImage: "gearshape.fill")
                                .font(.sqCaption)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .screenQCard(tint: tint, padding: 16)
    }

    // MARK: - Copy + state mapping

    private var tint: Color {
        switch primaryStatus {
        case .notRequested:           return ScreenQTheme.cosmicCyan
        case .requestedPendingUser:   return ScreenQTheme.cosmicAmber
        case .grantedPendingRestart:  return ScreenQTheme.cosmicAmber
        case .granted:                return ScreenQTheme.cosmicMint
        }
    }

    private var iconName: String {
        switch primaryStatus {
        case .notRequested:          return "lock.shield"
        case .requestedPendingUser:  return "exclamationmark.triangle.fill"
        case .grantedPendingRestart: return "arrow.triangle.2.circlepath"
        case .granted:               return "checkmark.shield.fill"
        }
    }

    private var title: String {
        if screenStatus != .granted {
            switch screenStatus {
            case .notRequested:
                return "One-time setup: allow Screen Recording"
            case .requestedPendingUser:
                return "Screen Recording needs to be enabled"
            case .grantedPendingRestart:
                return "Relaunch to finish enabling Screen Recording"
            case .granted:
                return ""
            }
        }
        switch accessibilityStatus {
        case .notRequested:
            return "Enable Accessibility to allow remote control"
        case .requestedPendingUser, .grantedPendingRestart:
            return "Accessibility needs to be enabled"
        case .granted:
            return ""
        }
    }

    private var message: String {
        if screenStatus != .granted {
            switch screenStatus {
            case .notRequested:
                return "Screen Q needs Screen Recording to share this Mac's display with a viewer. We'll show the macOS prompt."
            case .requestedPendingUser:
                return "Enable Screen Q in System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch for the change to take effect."
            case .grantedPendingRestart:
                return "macOS won't pick up a new Screen Recording grant until Screen Q restarts."
            case .granted:
                return ""
            }
        }
        switch accessibilityStatus {
        case .notRequested:
            return "Accessibility lets Screen Q deliver mouse and keyboard events to this Mac. Hosting works in view-only mode without it, but control will be disabled."
        case .requestedPendingUser, .grantedPendingRestart:
            return "Open System Settings ▸ Privacy & Security ▸ Accessibility and enable Screen Q. No relaunch needed."
        case .granted:
            return ""
        }
    }

    private var primaryLabel: String {
        switch primaryStatus {
        case .notRequested:           return "Allow…"
        case .requestedPendingUser:   return "Open Privacy Settings"
        case .grantedPendingRestart:  return "Open Privacy Settings"
        case .granted:                return "OK"
        }
    }

    private var primaryIcon: String {
        switch primaryStatus {
        case .notRequested:           return "checkmark.shield"
        case .requestedPendingUser:   return "gearshape.fill"
        case .grantedPendingRestart:  return "gearshape.fill"
        case .granted:                return "checkmark"
        }
    }

    /// Which permission's status the banner is currently being driven by.
    private var primaryStatus: MacPermissionStatus {
        screenStatus != .granted ? screenStatus : accessibilityStatus
    }

    private var showsRelaunch: Bool {
        // Only Screen Recording needs a relaunch; offer it when we're
        // certain the user has interacted with the toggle at least once.
        screenStatus == .requestedPendingUser || screenStatus == .grantedPendingRestart
    }

    private var showsOpenSettings: Bool {
        // For Accessibility-only cases we still want a clear secondary
        // path to Settings.
        !showsRelaunch && primaryStatus != .notRequested
    }
}
#endif
