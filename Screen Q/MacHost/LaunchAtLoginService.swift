//
//  LaunchAtLoginService.swift
//  Screen Q
//
//  Wraps `SMAppService.mainApp` (macOS 13+) so Settings → Hosting can
//  register / unregister Screen Q as a login item without scattering
//  ServiceManagement details across the UI. Falls back to a stored-only
//  toggle on older macOS where SMAppService isn't available; the
//  Settings row gates its activation with `LaunchAtLoginService.isSupported`.
//

#if os(macOS)
import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService: ObservableObject {

    static let shared = LaunchAtLoginService()

    /// Mirrors the underlying `SMAppService.mainApp.status` when available.
    /// `false` on macOS 12 or earlier (toggle is shown disabled with a note).
    @Published private(set) var isEnabled: Bool = false

    /// True when SMAppService is available on this macOS version.
    static let isSupported: Bool = {
        if #available(macOS 13.0, *) { return true }
        return false
    }()

    private init() {
        refresh()
    }

    /// Read the live SMAppService status.
    func refresh() {
        if #available(macOS 13.0, *) {
            isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            isEnabled = false
        }
    }

    /// Apply a new enabled state. Returns true on success.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            return true
        } catch {
            Logger.shared.error("LaunchAtLoginService.setEnabled(\(enabled)) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Human-readable status for the Settings row's trailing pill.
    var statusText: String {
        guard Self.isSupported else { return "Requires macOS 13+" }
        return isEnabled ? "On" : "Off"
    }
}
#endif
