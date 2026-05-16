//
//  MacPairingPromptController.swift
//  Screen Q
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class MacPairingPromptController: NSObject, NSWindowDelegate {
    static let shared = MacPairingPromptController()

    private var panels: [UUID: NSPanel] = [:]
    private var closeHandlers: [UUID: () -> Void] = [:]

    private override init() {
        super.init()
    }

    func present(request: PairingRequest, runtime: MacHostRuntime) {
        if let panel = panels[request.id] {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: request.trustedReconnect ? 334 : 314),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = request.trustedReconnect ? "Approve Screen Q Connection" : "Trust This Device?"
        panel.identifier = NSUserInterfaceItemIdentifier(request.id.uuidString)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: MacPairingPromptView(
            request: request,
            runtime: runtime
        ))

        panels[request.id] = panel
        closeHandlers[request.id] = { [weak runtime] in
            Task { @MainActor in
                await runtime?.reject(request)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss(_ id: UUID) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        closeHandlers.removeValue(forKey: id)
        panel.delegate = nil
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let raw = panel.identifier?.rawValue,
              let id = UUID(uuidString: raw) else { return }
        panels.removeValue(forKey: id)
        closeHandlers.removeValue(forKey: id)?()
    }
}

private struct MacPairingPromptView: View {
    let request: PairingRequest
    @ObservedObject var runtime: MacHostRuntime

    @State private var now: Date = Date()
    private let waitTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var codeMatches: Bool {
        runtime.pairingCodeMatches(request)
    }

    private var permissionSummary: String {
        let labels = PermissionSet.allCases
            .filter { runtime.permissions.contains($0.flag) }
            .map(\.label)
        return labels.isEmpty ? "No permissions selected" : labels.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: request.trustedReconnect ? "checkmark.shield" : "lock.shield")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(request.trustedReconnect ? .green : .accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.bold())
                    Text(subtitle)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                labeledValue("Device", "\(request.viewer.displayName) (\(request.viewer.platform.human))")
                labeledValue("Waiting", waitText)
                labeledValue("Permissions", permissionSummary)
                if let fingerprint = request.identityFingerprint {
                    labeledValue("Identity", "\(fingerprint.prefix(16))...")
                }
                if !request.trustedReconnect {
                    labeledValue("Pairing Code", request.claimedCode)
                    Text(codeMatches ? "The code matches the current host challenge." : "The code does not match the current host challenge.")
                        .font(.caption)
                        .foregroundColor(codeMatches ? .green : .red)
                }
            }
            .accessibilityElement(children: .contain)

            Spacer(minLength: 0)

            if request.trustedReconnect {
                trustedActions
            } else {
                unknownDeviceActions
            }
        }
        .padding(22)
        .frame(width: 460, alignment: .leading)
        .onReceive(waitTimer) { now = $0 }
    }

    private var waitText: String {
        let elapsed = max(0, Int(now.timeIntervalSince(request.receivedAt)))
        if elapsed < 60 {
            return "\(elapsed)s"
        }
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return "\(minutes)m \(seconds)s"
    }

    private var title: String {
        request.trustedReconnect ? "Allow this trusted device to connect?" : "Trust this device?"
    }

    private var subtitle: String {
        if request.trustedReconnect {
            return "This device identity is already trusted. Choose whether to allow this session once or save an automatic policy."
        }
        return "Only trust this device if the viewer entered the 6-digit code shown by Screen Q on this Mac."
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(label == "Pairing Code" ? .system(.body, design: .monospaced) : .body)
                .lineLimit(2)
        }
    }

    private var unknownDeviceActions: some View {
        HStack {
            Button("Do Not Trust") {
                Task { await runtime.reject(request) }
            }
            Spacer()
            Button("Trust") {
                Task { await runtime.approve(request) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!codeMatches)
        }
    }

    private var trustedActions: some View {
        HStack {
            Button("Always Deny") {
                Task {
                    await runtime.reject(
                        request,
                        reason: "Denied by host access policy",
                        setting: .alwaysDeny
                    )
                }
            }
            Button("Deny") {
                Task { await runtime.reject(request) }
            }
            Spacer()
            Button("Allow Once") {
                Task { await runtime.approve(request, setting: .askEveryTime) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Always Allow") {
                Task { await runtime.approve(request, setting: .alwaysAllow) }
            }
        }
    }
}
#endif
