//
//  Screen_QApp.swift
//  Screen Q
//
//  App entry point. Wires AppState into the SwiftUI scene graph and
//  presents the role-based HomeView. The default ContentView scaffold has
//  been removed in favor of the Screen Q product surface.
//

import SwiftUI

@main
struct Screen_QApp: App {
    @StateObject private var appState = AppState()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var appDelegate
    @StateObject private var statusBarController = MacStatusBarController()
    #endif

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(appState)
                .environmentObject(appState.viewerSessions)
                .onOpenURL { url in
                    appState.handleExternalURL(url)
                }
                #if os(macOS)
                .background(MacMainWindowAccessor())
                .onAppear {
                    MacWindowRegistry.shared.configure(appState: appState)
                    statusBarController.configure(appState: appState)
                }
                #endif
        }

        #if os(macOS)
        // Native macOS Settings scene. Built into SwiftUI on macOS 11.0+ and
        // automatically wired to the ⌘, menu item / "Screen Q → Settings…".
        Settings {
            SettingsScene()
                .environmentObject(appState)
                .environmentObject(appState.viewerSessions)
                .frame(minWidth: 880, minHeight: 540)
        }
        #endif
    }
}
