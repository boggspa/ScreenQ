//
//  MacStatusBarController.swift
//  Screen Q
//
//  Hosts the menu-bar status item. Replaces the legacy NSMenu with a
//  SwiftUI popover (MacMenuBarView) and renders a dynamic asset-backed
//  icon that badges active sessions / pending host requests.
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
    private var appearanceObserver: NSObjectProtocol?
    private var globalShortcutMonitor: Any?
    private var localShortcutMonitor: Any?
    private let menuBarIconPointSize: CGFloat = 18

    // Popover sizing: width is fixed at 360pt; height is content-driven and
    // clamped between minPopoverHeight and maxPopoverHeight so the menu never
    // shrinks past readable or grows past comfortable.
    private let popoverWidth: CGFloat = 360
    private let minPopoverHeight: CGFloat = 480
    private let maxPopoverHeight: CGFloat = 720

    /// Source of truth for the user-configurable global shortcut. The
    /// controller subscribes to `$current` so changes from Settings →
    /// Hosting automatically re-install monitors without a relaunch.
    private let shortcutManager = GlobalShortcutManager.shared

    override init() {
        super.init()
        installShortcutMonitors()
        shortcutManager.$current
            .dropFirst()
            .sink { [weak self] _ in
                self?.reinstallShortcutMonitors()
            }
            .store(in: &cancellables)
    }

    deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localShortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func configure(appState: AppState) {
        guard statusItem == nil else {
            app = appState
            return
        }
        app = appState

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = makeIcon(badgeCount: 0, active: false, appearance: button.effectiveAppearance)
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Screen Q")
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshIcon()
            }
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: popoverWidth, height: minPopoverHeight)
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
        button.image = makeIcon(badgeCount: badge, active: active, appearance: button.effectiveAppearance)

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
        toggleMenuBarPopover()
    }

    private func toggleMenuBarPopover() {
        guard let popover, let button = statusItem?.button, let app else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.contentSize = NSSize(width: popoverWidth, height: computePopoverHeight(for: app))

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

    private func computePopoverHeight(for app: AppState) -> CGFloat {
        // Rough additive model. The popover hosts a header, a list of active
        // viewer sessions, a list of pending host pairing requests, and a
        // footer of action rows (Stop Sharing, navigation, Quit).
        let base: CGFloat = 200                 // header + footer + padding
        let extras: CGFloat = 80                // Stop Sharing button + nav links
        let sessionRow: CGFloat = 64            // per active session
        let pendingRow: CGFloat = 56            // per pending pair request

        let sessionCount = CGFloat(app.viewerSessions.sessions.count)
        let pendingCount = CGFloat(app.macHost.pendingRequests.count)

        let total = base + extras + sessionRow * sessionCount + pendingRow * pendingCount
        return max(minPopoverHeight, min(maxPopoverHeight, total))
    }

    // MARK: Global shortcut
    //
    // The global monitor fires when Screen Q is not the frontmost app —
    // requires Accessibility permission (already prompted via PermissionsView).
    // The local monitor fires when Screen Q is frontmost and consumes the
    // event so it does not propagate to the focused window.
    //
    // The active shortcut is selected by the user via Settings → Hosting
    // (`GlobalShortcutManager.shared`). Changes are picked up live via the
    // Combine subscription set up in `init()`.
    private func installShortcutMonitors() {
        // Skip installing monitors when the user has disabled the shortcut.
        guard shortcutManager.isEnabled else { return }

        let mask: NSEvent.EventTypeMask = .keyDown
        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // Global handlers fire on a background thread; hop to main.
            guard let self else { return }
            let isMatch = MainActor.assumeIsolated {
                self.shortcutManager.matches(event)
            }
            if isMatch {
                Task { @MainActor [weak self] in
                    self?.toggleMenuBarPopover()
                }
            }
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if self.shortcutManager.matches(event) {
                self.toggleMenuBarPopover()
                return nil   // consume so it does not reach the focused view
            }
            return event
        }
    }

    private func reinstallShortcutMonitors() {
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
            globalShortcutMonitor = nil
        }
        if let monitor = localShortcutMonitor {
            NSEvent.removeMonitor(monitor)
            localShortcutMonitor = nil
        }
        installShortcutMonitors()
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

    private func makeIcon(badgeCount: Int, active: Bool, appearance: NSAppearance) -> NSImage? {
        guard let base = baseMenuBarIcon(active: active, appearance: appearance) else { return nil }

        guard badgeCount > 0 else { return base }

        let baseSize = base.size
        let result = NSImage(size: baseSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        base.draw(in: NSRect(origin: .zero, size: baseSize))

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

        result.isTemplate = false
        return result
    }

    private func baseMenuBarIcon(active: Bool, appearance: NSAppearance) -> NSImage? {
        let assetName: String
        if active {
            assetName = "ScreenQMenuBarIconActive"
        } else if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            assetName = "ScreenQMenuBarIconDark"
        } else {
            assetName = "ScreenQMenuBarIconLight"
        }

        if let asset = NSImage(named: NSImage.Name(assetName))?.copy() as? NSImage {
            asset.size = NSSize(width: menuBarIconPointSize, height: menuBarIconPointSize)
            asset.isTemplate = false
            return asset
        }

        guard let symbol = NSImage(
            systemSymbolName: "rectangle.connected.to.line.below",
            accessibilityDescription: "Screen Q"
        ) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let fallback = (symbol.withSymbolConfiguration(config) ?? symbol).copy() as? NSImage
        fallback?.size = NSSize(width: menuBarIconPointSize, height: menuBarIconPointSize)
        fallback?.isTemplate = !active
        return fallback
    }
}
#endif
