//
//  HomeView.swift
//  Screen Q
//

import SwiftUI

struct HomeView: View {

    @EnvironmentObject private var app: AppState
    @State private var pendingRole: DeviceRole?
    @State private var showRoleSwitchPrompt = false
    @State private var showDiagnostics = false
    @State private var showSecurityTrust = false

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
                    showSecurityTrust = true
                } label: {
                    Label("Security & Trust", systemImage: "lock.shield")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
                .environmentObject(app)
        }
        .sheet(isPresented: $showSecurityTrust) {
            SecurityTrustView()
                .environmentObject(app)
        }
        .alert(isPresented: $showRoleSwitchPrompt) {
            Alert(
                title: Text("Stop the active session?"),
                message: Text(activeSwitchMessage),
                primaryButton: .destructive(Text("Stop and Switch")) {
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
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(DeviceRole.allCases) { role in
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
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var roleDetailPane: some View {
        if let role = app.selectedRole {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(role.title, systemImage: role.systemImage)
                        .font(.headline)
                    Spacer()
                    if activeRoleNeedsStopPrompt(role) {
                        Text(activeRoleStatus(role))
                            .font(.caption)
                            .foregroundColor(.secondary)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Divider()
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(DeviceRole.allCases) { role in
                            NavigationLink(destination: RoleDetailView(role: role)) {
                                RoleCard(role: role, isSelected: false)
                            }
                            .buttonStyle(.plain)
                            .disabled(!role.isSupportedOnCurrentPlatform)
                            .opacity(role.isSupportedOnCurrentPlatform ? 1 : 0.55)
                        }
                    }
                    footer
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Screen Q")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    NavigationLink(destination: SecurityTrustView()) {
                        Label("Security & Trust", systemImage: "lock.shield")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    NavigationLink(destination: DiagnosticsView()) {
                        Label("Diagnostics", systemImage: "wrench.and.screwdriver")
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
    }

    enum HomeRoute: Hashable {
        case diagnostics
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(iOS)
            Text("Share and control Macs. View iPhone and iPad screens with Apple-safe guidance.")
                .font(.headline)
                .foregroundColor(.secondary)
            #else
            Text("Screen Q")
                .font(.largeTitle).bold()
            Text("Share and control Macs. View iPhone and iPad screens with Apple-safe guidance.")
                .font(.title3)
                .foregroundColor(.secondary)
            #endif
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local network discovery uses Bonjour. Connect across networks via Tailscale or your VPN.", systemImage: "network")
            Label("iPhone and iPad cannot be remote-controlled by third-party apps. Screen Q is honest about this.", systemImage: "exclamationmark.shield")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.top, 12)
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 280), spacing: 16)]
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
            return app.hostIsSharing
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

private struct RoleCard: View {
    let role: DeviceRole
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: role.systemImage)
                .font(.system(size: 28))
                .foregroundColor(.accentColor)
            Text(role.title)
                .font(.headline)
            Text(role.subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !role.isSupportedOnCurrentPlatform {
                Label("Not available on this platform", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.gray.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isSelected ? 2 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct EmptyRoleDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.2.swap")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Choose an option")
                .font(.title3)
            Text("Host this Mac, connect to another host, or review Apple-native alternatives.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
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
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("\(role.title) is not available on this platform.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text(role.subtitle)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(32)
        .navigationTitle(role.title)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
