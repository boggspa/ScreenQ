//
//  MacWindowControls.swift
//  Screen Q
//

#if os(macOS)
import AppKit

@MainActor
enum MacWindowControls {
    static func activateApp() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = MacWindowRegistry.shared.activateMainWindow()
    }

    static func toggleFullScreen() {
        activateApp()
        MacWindowRegistry.shared.preferredWindow?.toggleFullScreen(nil)
    }
}
#endif
