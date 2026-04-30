//
//  MacApplicationDelegate.swift
//  Screen Q
//

#if os(macOS)
import AppKit

final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Honor persisted menu-bar-only preference on launch.
        if UserDefaults.standard.bool(forKey: "ScreenQ.MenuBarOnlyMode") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If the user clicks the dock icon while in menu-bar-only mode,
        // surface the main window. (Only relevant when policy was switched
        // back to .regular at runtime.)
        MacWindowControls.activateApp()
        return false
    }
}
#endif
