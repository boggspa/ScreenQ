//
//  MacStatusBarController.swift
//  Screen Q
//

#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor
final class MacStatusBarController: NSObject, ObservableObject, NSMenuDelegate {
    private weak var app: AppState?
    private var statusItem: NSStatusItem?
    private var actions: [String: MenuAction] = [:]

    func configure(appState: AppState) {
        guard statusItem == nil else {
            app = appState
            return
        }
        app = appState

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "Screen Q")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu(title: "Screen Q")
        menu.delegate = self
        item.menu = menu
        statusItem = item

        Task { await appState.bonjourBrowser.start() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()

        guard let app else {
            menu.addItem(withTitle: "Screen Q unavailable", action: nil, keyEquivalent: "")
            return
        }

        menu.addItem(makeItem("Open Screen Q", systemImage: "macwindow", action: .openApp))
        menu.addItem(NSMenuItem.separator())

        if app.hostIsSharing {
            menu.addItem(statusItem("Hosting this Mac", systemImage: "dot.radiowaves.left.and.right", state: .on))
            menu.addItem(makeItem("Manage Host", systemImage: "person.2.badge.gearshape", action: .openRole(.hostMac)))
            if app.pendingPairingRequests.isEmpty {
                menu.addItem(statusItem("No pending requests", systemImage: "checkmark.circle", state: .off))
            } else {
                menu.addItem(makeItem(
                    "\(app.pendingPairingRequests.count) Connection Request\(app.pendingPairingRequests.count == 1 ? "" : "s")",
                    systemImage: "person.crop.circle.badge.questionmark",
                    action: .openRole(.hostMac)
                ))
            }
            menu.addItem(makeItem("Stop Hosting", systemImage: "stop.circle", action: .stopHosting))
        } else {
            menu.addItem(makeItem("Host this Mac", systemImage: "desktopcomputer", action: .openRole(.hostMac)))
            addNearbyDevices(to: menu, app: app)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Refresh Devices", systemImage: "arrow.clockwise", action: .refreshDevices))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Quit Screen Q", systemImage: "power", action: .quit))
    }

    private func addNearbyDevices(to menu: NSMenu, app: AppState) {
        menu.addItem(sectionHeader("Nearby Devices"))

        let screenQHosts = app.discoveredHosts.prefix(5)
        let rfbHosts = app.discoveredRFBHosts.prefix(5)
        let tailnetDevices = app.tailnetDevices.prefix(5)
        let hasAnyDevice = !screenQHosts.isEmpty || !rfbHosts.isEmpty || !tailnetDevices.isEmpty

        guard hasAnyDevice else {
            menu.addItem(statusItem(app.browserStatus.isBrowsing ? "Searching local network..." : "No devices found", systemImage: "magnifyingglass", state: .off))
            return
        }

        for host in screenQHosts {
            let suffix = host.isIOSShareOnlyPresence ? " - view-only" : ""
            menu.addItem(makeItem(
                "\(host.displayName)\(suffix)",
                systemImage: symbol(for: host),
                action: .connect(.screenQ(host))
            ))
        }

        for host in rfbHosts {
            menu.addItem(makeItem(
                "\(host.displayName) - Mac Screen Sharing",
                systemImage: "macwindow",
                action: .connect(.macScreenSharing(host))
            ))
        }

        for device in tailnetDevices {
            guard let host = device.connectionHost else { continue }
            menu.addItem(makeItem(
                "\(device.displayName) - \(device.recommendedProtocol.displayName)",
                systemImage: device.symbolName,
                action: .connect(.manual(
                    host: host,
                    port: device.recommendedProtocol.defaultPort,
                    displayName: device.displayName,
                    connectionProtocol: device.recommendedProtocol
                ))
            ))
        }
    }

    private func makeItem(_ title: String, systemImage: String, action: MenuAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        let id = UUID().uuidString
        actions[id] = action
        item.representedObject = id
        return item
    }

    private func statusItem(_ title: String, systemImage: String, state: NSControl.StateValue) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        item.state = state
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbol(for host: DiscoveredHost) -> String {
        switch host.advertisedPlatform {
        case "macOS": return "desktopcomputer"
        case "iPadOS": return "ipad"
        case "iOS": return "iphone"
        case "visionOS": return "visionpro"
        default: return "display"
        }
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let action = actions[id],
              let app else { return }

        switch action {
        case .openApp:
            MacWindowControls.activateApp()
        case .openRole(let role):
            app.viewerFocusMode = false
            app.selectRole(role)
            MacWindowControls.activateApp()
        case .connect(let pending):
            app.requestViewerConnection(pending)
            MacWindowControls.activateApp()
        case .stopHosting:
            app.requestStopHostingFromMenu()
            MacWindowControls.activateApp()
        case .refreshDevices:
            Task {
                await app.bonjourBrowser.start()
                if app.tailnetAuthConfigured {
                    await app.refreshTailnetDevices()
                }
            }
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private enum MenuAction {
        case openApp
        case openRole(DeviceRole)
        case connect(PendingViewerConnection)
        case stopHosting
        case refreshDevices
        case quit
    }
}
#endif
