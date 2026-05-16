//
//  HomeView.swift
//  Screen Q
//

import SwiftUI

struct HomeView: View {

    @EnvironmentObject private var app: AppState
    @State private var pendingRole: DeviceRole?
    @State private var showRoleSwitchPrompt = false
    @State private var showSettings = false
    @State private var settingsInitialTab: SettingsScene.Tab? = nil

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        Group {
            if app.viewerFocusMode, app.selectedRole == .viewer {
                RoleDetailView(role: .viewer)
                    .environmentObject(app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    rolePicker
                        .frame(minWidth: 340, idealWidth: 420, maxWidth: 500)
                    Divider()
                    roleDetailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    settingsInitialTab = nil
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .help("Settings (⌘,)")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsScene(initialTab: settingsInitialTab)
                .environmentObject(app)
        }
        .sheet(isPresented: firstRunOnboardingBinding) {
            FirstRunOnboardingView()
                .environmentObject(app)
        }
        .alert(isPresented: $showRoleSwitchPrompt) {
            Alert(
                title: Text("Switch modes?"),
                message: Text(activeSwitchMessage),
                primaryButton: .destructive(Text("Switch and Stop")) {
                    if let role = pendingRole {
                        app.viewerFocusMode = false
                        app.selectRole(role)
                    }
                    pendingRole = nil
                },
                secondaryButton: .cancel {
                    pendingRole = nil
                }
            )
        }
    }

    private var rolePicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                roleGrid
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var roleGrid: some View {
        if #available(macOS 14.0, *) {
            MacRoleGrid(
                columns: gridColumns,
                selectedRole: app.selectedRole,
                onSelect: { role in requestRoleSelection(role) }
            )
        } else {
            // TODO: full keyboard focus management requires macOS 14+ (onKeyPress).
            // On macOS 11.5-13, cards remain mouse-driven only.
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(DeviceRole.primaryRoles) { role in
                    Button {
                        requestRoleSelection(role)
                    } label: {
                        RoleCard(role: role, isSelected: app.selectedRole == role)
                    }
                    .buttonStyle(.plain)
                    .disabled(!role.isSupportedOnCurrentPlatform)
                    .opacity(role.isSupportedOnCurrentPlatform ? 1 : 0.55)
                }
            }
        }
    }

    @ViewBuilder
    private var roleDetailPane: some View {
        if let role = app.selectedRole {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(role.title, systemImage: role.systemImage)
                        .font(.sqHeadline)
                    Spacer()
                    if activeRoleNeedsStopPrompt(role) {
                        SQPill(text: activeRoleStatus(role), status: .healthy, compact: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()
                RoleDetailView(role: role)
                    .environmentObject(app)
            }
        } else {
            EmptyRoleDetailView()
        }
    }
    #endif

    private var iOSBody: some View {
        NavigationView {
            ZStack {
                ScreenQTheme.heroBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        iOSHero
                        iOSRolesGrid
                        iOSCapabilitiesStrip
                        footer
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Screen Q")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        SQHaptics.tap()
                        settingsInitialTab = nil
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 540)
            #endif
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
        .sheet(isPresented: $showSettings) {
            NavigationView {
                SettingsScene(initialTab: settingsInitialTab)
                    .environmentObject(app)
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Done") {
                                SQHaptics.tap()
                                showSettings = false
                            }
                        }
                    }
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
        }
        .sheet(isPresented: firstRunOnboardingBinding) {
            FirstRunOnboardingView()
                .environmentObject(app)
        }
    }

    private var iOSHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ScreenQBrandMark(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome back")
                        .font(.sqCaption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text("Your remote desktop, anywhere.")
                        .font(.sqDisplay)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(app.localDeviceName)
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                SQPill(text: "On this network", status: .info)
                SQPill(text: "End-to-end encryption", status: .healthy)
            }
        }
        .screenQCard(tint: ScreenQTheme.cosmicCyan, padding: 18)
    }

    private var iOSRolesGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SQSectionHeader("Pick a role")
            LazyVGrid(columns: gridColumns, spacing: 14) {
                ForEach(DeviceRole.primaryRoles) { role in
                    NavigationLink(destination: RoleDetailView(role: role)) {
                        RoleCard(role: role, isSelected: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(!role.isSupportedOnCurrentPlatform)
                    .opacity(role.isSupportedOnCurrentPlatform ? 1 : 0.55)
                    .simultaneousGesture(TapGesture().onEnded {
                        SQHaptics.tap()
                    })
                }
            }
        }
    }

    private var iOSCapabilitiesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            SQSectionHeader("What's built in")
            VStack(alignment: .leading, spacing: 6) {
                capabilityRow("Native Screen Q · LAN · Tailscale · VPN", system: "globe")
                capabilityRow("Apple Screen Sharing (VNC / RFB)", system: "rectangle.on.rectangle")
                capabilityRow("Windows Remote Desktop (RDP) import", system: "pc")
                capabilityRow("File transfer, clipboard sync, audio forwarding", system: "doc.on.doc")
            }
        }
        .screenQCard()
    }

    private func capabilityRow(_ text: String, system: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ScreenQTheme.cosmicCyan)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.sqBody)
                .foregroundColor(.primary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }


    enum HomeRoute: Hashable {
        case diagnostics
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(iOS)
            Text("Control Macs and Windows PCs over LAN, Tailscale, or VPN.")
                .font(.sqHeadline)
                .foregroundColor(.secondary)
            #else
            Text("Screen Q")
                .font(.sqDisplay)
            Text("Control Macs and Windows PCs over LAN, Tailscale, or VPN.")
                .font(.sqTitle)
                .foregroundColor(.secondary)
            #endif
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local network discovery uses Bonjour. Connect across networks via Tailscale or your VPN.", systemImage: "network")
            Label("iPhone and iPad control stays with Apple-native options instead of private APIs.", systemImage: "exclamationmark.shield")
        }
        .font(.sqCaption)
        .foregroundColor(.secondary)
        .padding(.top, 12)
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 280), spacing: 16)]
    }

    private var firstRunOnboardingBinding: Binding<Bool> {
        Binding(
            get: { !app.firstRunOnboardingCompleted },
            set: { isPresented in
                if !isPresented {
                    app.completeFirstRunOnboarding()
                }
            }
        )
    }

    private func requestRoleSelection(_ role: DeviceRole) {
        guard role.isSupportedOnCurrentPlatform else { return }
        guard app.selectedRole != role else { return }
        if activeRoleNeedsStopPrompt(app.selectedRole) {
            pendingRole = role
            showRoleSwitchPrompt = true
        } else {
            app.viewerFocusMode = false
            app.selectRole(role)
        }
    }

    private func activeRoleNeedsStopPrompt(_ role: DeviceRole?) -> Bool {
        switch role {
        case .hostMac:
            #if os(macOS)
            return app.macHost.isSharing
            #else
            return false
            #endif
        case .viewer:
            return app.viewerHasActiveSession
        default:
            return false
        }
    }

    private func activeRoleNeedsStopPrompt(_ role: DeviceRole) -> Bool {
        activeRoleNeedsStopPrompt(Optional(role))
    }

    private func activeRoleStatus(_ role: DeviceRole) -> String {
        switch role {
        case .hostMac:
            return "Hosting active"
        case .viewer:
            return "Viewer session active"
        default:
            return ""
        }
    }

    private var activeSwitchMessage: String {
        switch app.selectedRole {
        case .hostMac:
            return "This Mac is currently hosting. Switching modes will stop sharing and disconnect viewers."
        case .viewer:
            return "A viewer session is active. Switching modes will disconnect from the remote host."
        default:
            return "Switching modes will stop the active session."
        }
    }
}

#if os(macOS)
@available(macOS 14.0, *)
private struct MacRoleGrid: View {
    let columns: [GridItem]
    let selectedRole: DeviceRole?
    let onSelect: (DeviceRole) -> Void

    @FocusState private var focusedRole: DeviceRole?

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(DeviceRole.primaryRoles) { role in
                Button {
                    onSelect(role)
                } label: {
                    RoleCard(role: role, isSelected: selectedRole == role)
                        .overlay(
                            RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous)
                                .strokeBorder(
                                    focusedRole == role ? ScreenQTheme.cosmicCyan : Color.clear,
                                    lineWidth: focusedRole == role ? 2.5 : 0
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!role.isSupportedOnCurrentPlatform)
                .opacity(role.isSupportedOnCurrentPlatform ? 1 : 0.55)
                .focusable(role.isSupportedOnCurrentPlatform)
                .focused($focusedRole, equals: role)
                .onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    handleKey(press.key, current: role)
                }
            }
        }
        .onAppear {
            if focusedRole == nil {
                focusedRole = selectedRole ?? DeviceRole.primaryRoles.first { $0.isSupportedOnCurrentPlatform }
            }
        }
    }

    private func handleKey(_ key: KeyEquivalent, current: DeviceRole) -> KeyPress.Result {
        switch key {
        case .return, .space:
            onSelect(current)
            return .handled
        case .leftArrow, .upArrow:
            moveFocus(from: current, delta: -1)
            return .handled
        case .rightArrow, .downArrow:
            moveFocus(from: current, delta: 1)
            return .handled
        default:
            return .ignored
        }
    }

    private func moveFocus(from current: DeviceRole, delta: Int) {
        let supported = DeviceRole.primaryRoles.filter { $0.isSupportedOnCurrentPlatform }
        guard !supported.isEmpty,
              let idx = supported.firstIndex(of: current) else { return }
        let next = (idx + delta + supported.count) % supported.count
        focusedRole = supported[next]
    }
}
#endif

private struct RoleCard: View {
    let role: DeviceRole
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ScreenQTheme.accent(tint))
                    Image(systemName: role.systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: 46, height: 46)
                .shadow(color: tint.opacity(0.45), radius: 8, x: 0, y: 4)

                Spacer()

                if role.isSupportedOnCurrentPlatform {
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
                Text(role.title)
                    .font(.sqHeadline)
                Text(role.subtitle)
                    .font(.sqCallout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !role.isSupportedOnCurrentPlatform {
                Label("Not available on this device", systemImage: "info.circle")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .screenQCard(tint: tint, padding: 18)
        .overlay(
            RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? ScreenQTheme.cosmicCyan.opacity(0.75) : Color.clear,
                    lineWidth: isSelected ? 2 : 0
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: ScreenQTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role.title). \(role.subtitle)\(role.isSupportedOnCurrentPlatform ? "" : ". Not available on this device")")
    }

    private var tint: Color {
        switch role {
        case .hostMac:                  return ScreenQTheme.cosmicViolet
        case .viewer:                   return ScreenQTheme.cosmicCyan
        case .iosScreenShare:           return ScreenQTheme.cosmicAmber
        case .appleNativeAlternatives:  return ScreenQTheme.cosmicRose
        }
    }
}

private struct EmptyRoleDetailView: View {
    var body: some View {
        SQEmptyState(
            icon: "rectangle.on.rectangle.angled",
            title: "Pick a role to begin",
            message: "Choose Host this Mac or Viewer mode to set up Screen Q on this device.",
            tint: ScreenQTheme.cosmicCyan
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RoleDetailView: View {
    let role: DeviceRole
    var body: some View {
        switch role {
        case .hostMac:
            #if os(macOS)
            HostMacView()
            #else
            UnsupportedRoleView(role: role)
            #endif
        case .viewer:
            ViewerView()
        case .iosScreenShare:
            #if os(iOS)
            IOSScreenShareView()
            #else
            UnsupportedRoleView(role: role)
            #endif
        case .appleNativeAlternatives:
            AppleNativeAlternativesView()
        }
    }
}

struct UnsupportedRoleView: View {
    let role: DeviceRole
    var body: some View {
        SQEmptyState(
            icon: "exclamationmark.triangle",
            title: "\(role.title) is not available on this platform.",
            message: role.subtitle,
            tint: ScreenQTheme.cosmicAmber
        )
        .padding(32)
        .navigationTitle(role.title)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
