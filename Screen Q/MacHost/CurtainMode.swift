//
//  CurtainMode.swift
//  Screen Q
//
//  "Curtain mode" blanks the host's screen while it is being controlled
//  remotely, hiding the remote user's activity from anyone physically
//  present at the host machine. Uses CGDisplayCapture/Release.
//

#if os(macOS)
import Foundation
import CoreGraphics
import AppKit
import Combine

@MainActor
final class CurtainMode: ObservableObject {

    @Published private(set) var isActive = false

    /// Activate curtain mode — blanks all displays.
    func activate() {
        guard !isActive else { return }
        let result = CGDisplayCapture(CGMainDisplayID())
        if result == .success {
            isActive = true
            Logger.shared.info("Curtain mode activated")
        } else {
            Logger.shared.error("CGDisplayCapture failed: \(result.rawValue)")
        }
    }

    /// Deactivate curtain mode — restores all displays.
    func deactivate() {
        guard isActive else { return }
        CGDisplayRelease(CGMainDisplayID())
        isActive = false
        Logger.shared.info("Curtain mode deactivated")
    }

    /// Toggle curtain mode.
    func toggle() {
        isActive ? deactivate() : activate()
    }

    deinit {
        // Always release on dealloc to prevent stuck blank screens.
        // Note: deinit is nonisolated, so we unconditionally release.
        CGDisplayRelease(CGMainDisplayID())
    }
}
#endif
