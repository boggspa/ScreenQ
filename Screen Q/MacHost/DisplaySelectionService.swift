//
//  DisplaySelectionService.swift
//  Screen Q
//
//  Lists displays the user can pick to share. We start with one-display
//  support but architect the UI for multi-display selection.
//

#if os(macOS)
import Foundation
import AppKit
import ScreenCaptureKit
import Combine

@MainActor
final class DisplaySelectionService: ObservableObject {

    struct DisplayInfo: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let pixelWidth: Int
        let pixelHeight: Int
        let pointWidth: Double
        let pointHeight: Double
        let scaleFactor: Double
    }

    @Published private(set) var displays: [DisplayInfo] = []
    @Published var selectedDisplayID: CGDirectDisplayID?

    func refreshFromNSScreen() {
        var collected: [DisplayInfo] = []
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
                let pixelW = Int(screen.frame.width * screen.backingScaleFactor)
                let pixelH = Int(screen.frame.height * screen.backingScaleFactor)
                let info = DisplayInfo(
                    id: CGDirectDisplayID(id),
                    name: screen.localizedName,
                    pixelWidth: pixelW,
                    pixelHeight: pixelH,
                    pointWidth: Double(screen.frame.width),
                    pointHeight: Double(screen.frame.height),
                    scaleFactor: Double(screen.backingScaleFactor)
                )
                collected.append(info)
            }
        }
        displays = collected
        if selectedDisplayID == nil {
            selectedDisplayID = collected.first?.id
        }
    }

    func selectedDisplay() -> DisplayInfo? {
        guard let selectedDisplayID else { return displays.first }
        return displays.first { $0.id == selectedDisplayID }
    }

    /// Async version using SCShareableContent (preferred when stream config
    /// time comes around). Falls back to NSScreen if SCShareableContent is
    /// unavailable for any reason.
    func refreshUsingSCShareableContent() async {
        guard #available(macOS 12.3, *) else {
            refreshFromNSScreen()
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            var collected: [DisplayInfo] = []
            for d in content.displays {
                let info = DisplayInfo(
                    id: d.displayID,
                    name: "Display \(d.displayID)",
                    pixelWidth: Int(d.width),
                    pixelHeight: Int(d.height),
                    pointWidth: Double(d.frame.width),
                    pointHeight: Double(d.frame.height),
                    scaleFactor: 1.0
                )
                collected.append(info)
            }
            self.displays = collected
            if self.selectedDisplayID == nil {
                self.selectedDisplayID = collected.first?.id
            }
        } catch {
            Logger.shared.warn("SCShareableContent failed (\(error.localizedDescription)); falling back to NSScreen")
            refreshFromNSScreen()
        }
    }
}
#endif
