//
//  MacStatusBarController.swift
//  Screen Q
//
//  Hosts the menu-bar status item. Replaces the legacy NSMenu with a
//  SwiftUI popover (MacMenuBarView) and renders a dynamic icon that
//  badges active sessions / pending host requests and tints based on
//  app state (green when sharing or connected, accent otherwise).
//

#if os(macOS)
import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class MacStatusBarController: NSObject, ObservableObject {
    private weak var app: AppState?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitor: Any?

    func configure(appState: AppState) {
        guard statusItem == nil else {
            app = appState
            return
        }
        app = appState

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = makeIcon(badgeCount: 0, tintActive: false)
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("Screen Q")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 360, height: 540)
        popover = pop

        Task { await appState.bonjourBrowser.start() }

        observeState(appState)
        refreshIcon()
    }

    private func observeState(_ app: AppState) {
        Publishers.MergeMany(
            app.macHost.objectWillChange.eraseToAnyPublisher(),
            app.viewerSessions.objectWillChange.eraseToAnyPublisher(),
            app.objectWillChange.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
        .store(in: &cancellables)
    }

    private func refreshIcon() {
        guard let app, let button = statusItem?.button else { return }
        let activeCount = app.viewerSessions.sessions.count
        let pendingHostRequests = app.macHost.pendingRequests.count
        let badge = activeCount + pendingHostRequests
        let active = activeCount > 0 || app.macHost.isSharing
        button.image = makeIcon(badgeCount: badge, tintActive: active)

        let summary: String
        if activeCount > 0 {
            summary = "\(activeCount) active session\(activeCount == 1 ? "" : "s")"
        } else if app.macHost.isSharing {
            summary = pendingHostRequests > 0 ? "Hosting — \(pendingHostRequests) pending" : "Hosting"
        } else {
            summary = "Idle"
        }
        button.setAccessibilityValue(summary)
        button.toolTip = "Screen Q · \(summary)"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button, let app else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        let view = MacMenuBarView(
            app: app,
            sessionStore: app.viewerSessions,
            onOpenApp: { [weak self] in
                self?.popover?.performClose(nil)
                if app.menuBarOnlyMode { app.menuBarOnlyMode = false }
                MacWindowControls.activateApp()
            },
            onOpenRole: { [weak self] role in
                self?.popover?.performClose(nil)
                app.viewerFocusMode = false
                app.selectRole(role)
                MacWindowControls.activateApp()
            },
            onConnect: { [weak self] pending in
                self?.popover?.performClose(nil)
                app.requestViewerConnection(pending)
                MacWindowControls.activateApp()
            },
            onSelectSession: { id in
                app.viewerSessions.selectSession(id: id)
                app.selectRole(.viewer)
            },
            onCloseSession: { id in
                Task { await app.viewerSessions.closeSession(id: id) }
            },
            onConnectSaved: { [weak self] saved in
                self?.popover?.performClose(nil)
                self?.connectSaved(saved, app: app)
                MacWindowControls.activateApp()
            },
            onStopHosting: {
                app.requestStopHostingFromMenu()
            },
            onRefresh: {
                Task {
                    await app.bonjourBrowser.start()
                    if app.tailnetAuthConfigured {
                        await app.refreshTailnetDevices()
                    }
                }
            },
            onToggleMenuBarOnly: {
                app.menuBarOnlyMode.toggle()
            },
            onQuit: { NSApp.terminate(nil) }
        )

        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
            if let monitor = self?.eventMonitor {
                NSEvent.removeMonitor(monitor)
                self?.eventMonitor = nil
            }
        }
    }

    private func connectSaved(_ saved: SavedConnection, app: AppState) {
        let store = app.viewerSessions
        switch saved.resolvedProtocol {
        case .macScreenSharing:
            store.startVNCSession(host: saved.host, port: saved.port, label: saved.displayName, profile: .macScreenSharing)
        case .vnc:
            store.startVNCSession(host: saved.host, port: saved.port, label: saved.displayName, profile: .genericVNC)
        case .rdp:
            store.startRDPSession(host: saved.host, port: saved.port, label: saved.displayName, app: app)
        case .screenQ:
            Task {
                await store.connect(via: app, hostText: saved.host, port: saved.port, connectionProtocol: .screenQ, displayName: saved.displayName)
            }
        }
        app.selectRole(.viewer)
    }

    /// Compose a base SF Symbol with an optional red badge bubble and a
    /// green tint when sharing or connected. Otherwise returns the
    /// system-template image so the system handles dark/light correctly.
    private func makeIcon(badgeCount: Int, tintActive: Bool) -> NSImage? {
        let symbolName = "rectangle.connected.to.line.below"
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Screen Q") else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        guard let configured = base.withSymbolConfiguration(config) else { return base }

        guard badgeCount > 0 || tintActive else {
            configured.isTemplate = true
            return configured
        }

        let baseSize = configured.size
        let result = NSImage(size: baseSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        if tintActive {
            let rect = NSRect(origin: .zero, size: baseSize)
            configured.draw(in: rect)
            NSColor.systemGreen.withAlphaComponent(0.85).set()
            rect.fill(using: .sourceAtop)
        } else {
            configured.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        if badgeCount > 0 {
            let countText = badgeCount > 9 ? "9+" : "\(badgeCount)"
            let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = (countText as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 3
            let bubbleH: CGFloat = 11
            let bubbleW = max(bubbleH, textSize.width + pad * 2)
            let bubbleRect = NSRect(
                x: baseSize.width - bubbleW + 2,
                y: baseSize.height - bubbleH + 1,
                width: bubbleW,
                height: bubbleH
            )
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: bubbleRect, xRadius: bubbleH / 2, yRadius: bubbleH / 2).fill()
            let textRect = NSRect(
                x: bubbleRect.midX - textSize.width / 2,
                y: bubbleRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            (countText as NSString).draw(in: textRect, withAttributes: attrs)
        }

        result.isTemplate = false
        return result
    }
}
#endif
