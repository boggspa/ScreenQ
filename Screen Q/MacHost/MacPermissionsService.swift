//
//  MacPermissionsService.swift
//  Screen Q
//
//  Surfaces the three macOS permissions Screen Q's host mode actually uses:
//   - Screen Recording (TCC)
//   - Accessibility (TCC) for CGEvent injection
//   - Local Network (Privacy / Bonjour)
//
//  We only check status and request access; we never silently bypass TCC.
//

#if os(macOS)
import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Combine

@MainActor
final class MacPermissionsService: ObservableObject {

    @Published private(set) var screenRecordingGranted: Bool = false
    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var localNetworkAttempted: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Trigger the system Screen Recording permission flow. Returns the
    /// current grant value after the prompt resolves (note: TCC is async
    /// from the user's perspective; the value here just reflects current
    /// process state at this moment).
    @discardableResult
    func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        screenRecordingGranted = granted
        return granted
    }

    /// Show the Accessibility prompt and recheck.
    @discardableResult
    func requestAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options: NSDictionary = [key: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted
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
}
#endif
