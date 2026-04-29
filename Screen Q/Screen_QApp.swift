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
    @StateObject private var statusBarController = MacStatusBarController()
    #endif

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(appState)
                #if os(macOS)
                .onAppear {
                    statusBarController.configure(appState: appState)
                }
                #endif
        }
    }
}
