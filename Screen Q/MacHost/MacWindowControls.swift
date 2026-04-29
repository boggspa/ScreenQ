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
        if let window = preferredWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func toggleFullScreen() {
        activateApp()
        preferredWindow?.toggleFullScreen(nil)
    }

    private static var preferredWindow: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && !$0.isMiniaturized }
            ?? NSApp.windows.first
    }
}
#endif
