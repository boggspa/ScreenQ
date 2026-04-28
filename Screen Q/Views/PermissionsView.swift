//
//  PermissionsView.swift
//  Screen Q
//
//  Compact macOS permissions checklist surfaced inside HostMacView.
//

#if os(macOS)
import SwiftUI

struct PermissionsView: View {

    @EnvironmentObject private var permissions: MacPermissionsService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(
                title: "Screen Recording",
                subtitle: "Required to capture this Mac's display via ScreenCaptureKit.",
                granted: permissions.screenRecordingGranted,
                primary: ("Request", { permissions.requestScreenRecording() }),
                secondary: ("Open Privacy", { permissions.openPrivacyScreenRecording() })
            )
            row(
                title: "Accessibility",
                subtitle: "Required to inject mouse and keyboard events for remote control.",
                granted: permissions.accessibilityGranted,
                primary: ("Request", { permissions.requestAccessibility() }),
                secondary: ("Open Privacy", { permissions.openPrivacyAccessibility() })
            )
            row(
                title: "Local Network",
                subtitle: "Required for Bonjour discovery. Triggered automatically when you start hosting.",
                granted: permissions.localNetworkAttempted,
                primary: nil,
                secondary: nil,
                grantedLabel: permissions.localNetworkAttempted ? "Prompt seen" : "Not yet requested"
            )
            HStack {
                Spacer()
                Button("Refresh") { permissions.refresh() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func row(
        title: String,
        subtitle: String,
        granted: Bool,
        primary: (String, () -> Void)?,
        secondary: (String, () -> Void)?,
        grantedLabel: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(granted ? .green : .secondary)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let grantedLabel {
                        Text(grantedLabel).font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(granted ? "Granted" : "Not granted")
                            .font(.caption)
                            .foregroundColor(granted ? .green : .secondary)
                    }
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    if let primary {
                        Button(primary.0) { primary.1() }
                            .buttonStyle(.bordered)
                    }
                    if let secondary {
                        Button(secondary.0) { secondary.1() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    PermissionsView()
        .environmentObject(MacPermissionsService())
        .padding()
}
#endif
