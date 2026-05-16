//
//  MacPermissionsService.swift
//  Screen Q
//
//  Surfaces the three macOS permissions Screen Q's host mode actually uses:
//   - Screen Recording (TCC)
//   - Accessibility (TCC) for CGEvent injection
//   - Local Network (Privacy / Bonjour)
//
//  Why this is more than a thin TCC wrapper:
//
//  The OS has a long-standing quirk where flipping the Screen Recording
//  toggle in System Settings does NOT make `CGPreflightScreenCaptureAccess`
//  start returning `true` for the already-running process. The user has
//  to quit & relaunch the app. Without proper UX around that, the user
//  ends up in a "click Request, nothing happens, still not granted"
//  loop because `CGRequestScreenCaptureAccess` only fires the system
//  prompt once per process. We model that explicitly here.
//

#if os(macOS)
import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Combine

/// High-level state for a single TCC permission, used to drive UX.
enum MacPermissionStatus: Equatable {
    /// Granted in this running process; ready to use.
    case granted
    /// Not granted yet and we've never asked for it during this app's lifetime.
    case notRequested
    /// We've already shown the system prompt to this process — clicking
    /// "Request" again will not do anything visible. The user must open
    /// System Settings and (for Screen Recording) relaunch the app.
    case requestedPendingUser
    /// We requested previously, the user enabled the toggle in System
    /// Settings, but TCC is still reporting `false` for this process.
    /// The app must be quit & relaunched for the entitlement to take
    /// effect.
    case grantedPendingRestart

    var isUsable: Bool { self == .granted }

    var needsRelaunch: Bool { self == .grantedPendingRestart }
}

@MainActor
final class MacPermissionsService: ObservableObject {

    @Published private(set) var screenRecordingGranted: Bool = false
    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var localNetworkAttempted: Bool = false

    @Published private(set) var screenRecordingStatus: MacPermissionStatus = .notRequested
    @Published private(set) var accessibilityStatus: MacPermissionStatus = .notRequested

    /// Persisted across launches so we know whether to use "Request" or
    /// "Open System Settings" labelling on first paint.
    private let defaults: UserDefaults
    private let screenRecordingRequestedKey = "ScreenQ.Permissions.ScreenRecording.RequestedBefore"
    private let accessibilityRequestedKey   = "ScreenQ.Permissions.Accessibility.RequestedBefore"

    /// `true` if `CGRequestScreenCaptureAccess()` has already been invoked
    /// during this *process* lifetime. A second call would be a no-op
    /// from the user's perspective.
    private var didRequestScreenRecordingThisLaunch: Bool = false
    private var didRequestAccessibilityThisLaunch: Bool = false

    private var pollTimer: Timer?
    private var resignObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
        startPolling()
        installAppActivationObservers()
    }

    // AppState holds this service for the lifetime of the app, so we
    // skip explicit teardown of the polling timer / notification
    // observers — they're reclaimed when the process exits. This also
    // sidesteps cross-isolation access from a nonisolated deinit.

    /// Recompute everything from TCC and reduce that down into our
    /// higher-level `MacPermissionStatus` states.
    func refresh() {
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()

        if screenRecording != screenRecordingGranted {
            screenRecordingGranted = screenRecording
        }
        if accessibility != accessibilityGranted {
            accessibilityGranted = accessibility
        }

        let nextScreenRecordingStatus = resolveScreenRecordingStatus(granted: screenRecording)
        if nextScreenRecordingStatus != screenRecordingStatus {
            screenRecordingStatus = nextScreenRecordingStatus
        }

        let nextAccessibilityStatus = resolveAccessibilityStatus(granted: accessibility)
        if nextAccessibilityStatus != accessibilityStatus {
            accessibilityStatus = nextAccessibilityStatus
        }
    }

    /// Trigger the system Screen Recording flow.
    ///
    /// `CGRequestScreenCaptureAccess()` will only show the system prompt
    /// the **first** time it is called per process. Once we've called it
    /// we record that and switch the UI over to "Open System Settings"
    /// + "Quit & Relaunch" so the user has a real path forward instead
    /// of an inert button.
    @discardableResult
    func requestScreenRecording() -> Bool {
        // If we already know we're granted, this is a no-op.
        if CGPreflightScreenCaptureAccess() {
            didRequestScreenRecordingThisLaunch = true
            persistRequested(screenRecording: true)
            refresh()
            return true
        }

        // Always record that we asked at least once on this device so
        // subsequent launches present the right "Open System Settings"
        // affordance immediately.
        persistRequested(screenRecording: true)

        if didRequestScreenRecordingThisLaunch {
            // Re-calling does not show a new prompt; just open Settings.
            openPrivacyScreenRecording()
            refresh()
            return false
        }

        didRequestScreenRecordingThisLaunch = true
        let granted = CGRequestScreenCaptureAccess()
        // After the prompt resolves the user may have flipped the toggle
        // but TCC for this process is still cached as `false`. We let
        // the regular polling + activation handler pick that up.
        refresh()
        if !granted {
            openPrivacyScreenRecording()
        }
        return granted
    }

    /// Show the Accessibility prompt and recheck.
    ///
    /// Accessibility is more forgiving than Screen Recording: once the
    /// user enables the toggle for our bundle, `AXIsProcessTrusted()`
    /// starts returning `true` for the running process. No relaunch
    /// required.
    @discardableResult
    func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() {
            didRequestAccessibilityThisLaunch = true
            persistRequested(accessibility: true)
            refresh()
            return true
        }

        persistRequested(accessibility: true)
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options: NSDictionary = [key: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        didRequestAccessibilityThisLaunch = true

        if !trusted {
            openPrivacyAccessibility()
        }
        refresh()
        return trusted
    }

    /// Open the Privacy & Security pane focused on Screen Recording so the
    /// user can flip the toggle for Screen Q.
    func openPrivacyScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacyAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Bonjour will trigger the Local Network permission prompt the first
    /// time we listen. We just record that we asked.
    func markLocalNetworkAttempted() {
        localNetworkAttempted = true
    }

    /// Quit and relaunch the current Screen Q app bundle so TCC can
    /// re-evaluate Screen Recording for the new process. Used after the
    /// user enables Screen Recording in System Settings.
    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Internals

    private func resolveScreenRecordingStatus(granted: Bool) -> MacPermissionStatus {
        if granted { return .granted }
        let everRequested = didRequestScreenRecordingThisLaunch
            || defaults.bool(forKey: screenRecordingRequestedKey)
        if !everRequested { return .notRequested }
        // If the user has previously seen the prompt and toggled it in
        // Settings, the entitlement only sticks after relaunching. We
        // can't truly distinguish "toggled but pending restart" from
        // "still not toggled" without a sentinel; pessimistically say
        // `requestedPendingUser` and surface a "Quit & Relaunch" button
        // in the UI so the user can move forward either way.
        return .requestedPendingUser
    }

    private func resolveAccessibilityStatus(granted: Bool) -> MacPermissionStatus {
        if granted { return .granted }
        let everRequested = didRequestAccessibilityThisLaunch
            || defaults.bool(forKey: accessibilityRequestedKey)
        return everRequested ? .requestedPendingUser : .notRequested
    }

    private func persistRequested(screenRecording: Bool? = nil, accessibility: Bool? = nil) {
        if let screenRecording, screenRecording {
            defaults.set(true, forKey: screenRecordingRequestedKey)
        }
        if let accessibility, accessibility {
            defaults.set(true, forKey: accessibilityRequestedKey)
        }
    }

    /// Poll a few times a second so the UI reflects toggling in System
    /// Settings without forcing the user to hit "Refresh". Cheap; just
    /// two TCC reads.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func installAppActivationObservers() {
        // Quick refresh when the app regains focus (e.g. user came back
        // from System Settings).
        let center = NotificationCenter.default
        becomeActiveObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        resignObserver = center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            // No-op; explicit hook in case we ever need to pause/resume.
        }
    }
}
#endif
