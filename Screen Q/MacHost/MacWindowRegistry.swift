//
//  MacWindowRegistry.swift
//  Screen Q
//

#if os(macOS)
import AppKit

@MainActor
final class MacWindowRegistry {
    static let shared = MacWindowRegistry()

    private weak var mainWindow: NSWindow?
    private weak var appState: AppState?
    private let mainWindowDelegate = MacMainWindowCloseDelegate()

    private init() {}

    func configure(appState: AppState) {
        self.appState = appState
        mainWindowDelegate.configure(appState: appState)
    }

    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }

        mainWindow = window
        mainWindowDelegate.install(on: window)
    }

    func activateMainWindow() -> Bool {
        guard let window = preferredWindow else { return false }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    var preferredWindow: NSWindow? {
        mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && !$0.isMiniaturized }
            ?? NSApp.windows.first
    }
}

@MainActor
private final class MacMainWindowCloseDelegate: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var appState: AppState?

    func configure(appState: AppState) {
        self.appState = appState
    }

    func install(on window: NSWindow) {
        guard self.window !== window else { return }

        self.window = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if appState?.viewerHasActiveSession == true {
            let alert = NSAlert()
            alert.messageText = "Disconnect the active viewer session first."
            alert.informativeText = "Screen Q can continue hosting from the menu bar, but active viewer sessions need the main window. Disconnect before closing this window."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: sender)
            return false
        }
        sender.orderOut(nil)
        return false
    }
}
#endif
