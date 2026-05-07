//
//  FirstRunOnboardingView.swift
//  Screen Q
//
//  First-launch router for the concrete setup paths Screen Q supports.
//

import SwiftUI

struct FirstRunOnboardingView: View {

    @EnvironmentObject private var app: AppState

    private var routes: [FirstRunOnboardingRoute] {
        var items: [FirstRunOnboardingRoute] = []
        #if os(macOS)
        items.append(.hostMac)
        #endif
        items.append(contentsOf: [
            .connectExistingMac,
            .useTailscale,
            .useAppleScreenSharing,
            .importRDP
        ])
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(routes) { route in
                        FirstRunRouteCard(route: route) {
                            app.completeFirstRunOnboarding(route: route)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        #if os(macOS)
        .frame(minWidth: 660, idealWidth: 760, maxWidth: 860, minHeight: 560, idealHeight: 640)
        #endif
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("Start with Screen Q")
                    .font(.title2.bold())
                Text("Choose the setup path for this device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Text("You can change modes from the main window at any time.")
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                app.completeFirstRunOnboarding()
            } label: {
                Text("Skip")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)]
    }
}

private struct FirstRunRouteCard: View {
    let route: FirstRunOnboardingRoute
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: route.systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(route.tint)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(route.tint.opacity(0.12))
                        )
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(route.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(route.detail)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

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
            return .accentColor
        case .connectExistingMac:
            return .blue
        case .useTailscale:
            return .green
        case .useAppleScreenSharing:
            return .purple
        case .importRDP:
            return .orange
        }
    }
}
