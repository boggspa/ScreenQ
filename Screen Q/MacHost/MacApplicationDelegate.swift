//
//  MacApplicationDelegate.swift
//  Screen Q
//

#if os(macOS)
import AppKit

final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MacWindowControls.activateApp()
        return false
    }
}
#endif
