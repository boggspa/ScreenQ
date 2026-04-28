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
    nonisolated static let allDisplaysID: CGDirectDisplayID = 0

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
        validateSelection()
    }

    func selectedDisplay() -> DisplayInfo? {
        if selectedDisplayID == Self.allDisplaysID {
            return allDisplaysInfo()
        }
        guard let selectedDisplayID else { return displays.first }
        return displays.first { $0.id == selectedDisplayID }
    }

    var isAllDisplaysSelected: Bool {
        selectedDisplayID == Self.allDisplaysID
    }

    var canSelectAllDisplays: Bool {
        displays.count > 1
    }

    func displayOptions(includeAllDisplays: Bool = true) -> [DisplayInfo] {
        var options: [DisplayInfo] = []
        if includeAllDisplays, canSelectAllDisplays, let all = allDisplaysInfo() {
            options.append(all)
        }
        options.append(contentsOf: displays)
        return options
    }

    func allDisplaysInfo() -> DisplayInfo? {
        guard canSelectAllDisplays else { return nil }
        let pointFrame = Self.appKitDisplayFrameUnion()
        guard !pointFrame.isNull, !pointFrame.isEmpty else { return nil }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 1.0
        return DisplayInfo(
            id: Self.allDisplaysID,
            name: "All Displays",
            pixelWidth: Int((pointFrame.width * scale).rounded()),
            pixelHeight: Int((pointFrame.height * scale).rounded()),
            pointWidth: Double(pointFrame.width),
            pointHeight: Double(pointFrame.height),
            scaleFactor: Double(scale)
        )
    }

    func selectedCGBounds() -> CGRect? {
        if selectedDisplayID == Self.allDisplaysID {
            return Self.cgDisplayBoundsUnion()
        }
        guard let info = selectedDisplay() else { return nil }
        return CGDisplayBounds(info.id)
    }

    nonisolated static func cgDisplayBoundsUnion() -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids
            .map { CGDisplayBounds($0) }
            .reduce(CGRect.null) { $0.union($1) }
    }

    nonisolated static func appKitDisplayFrameUnion() -> CGRect {
        NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }
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
            self.validateSelection()
        } catch {
            Logger.shared.warn("SCShareableContent failed (\(error.localizedDescription)); falling back to NSScreen")
            refreshFromNSScreen()
        }
    }

    private func validateSelection() {
        guard !displays.isEmpty else {
            selectedDisplayID = nil
            return
        }
        if selectedDisplayID == Self.allDisplaysID, canSelectAllDisplays {
            return
        }
        if let selectedDisplayID, displays.contains(where: { $0.id == selectedDisplayID }) {
            return
        }
        selectedDisplayID = displays.first?.id
    }
}
#endif
