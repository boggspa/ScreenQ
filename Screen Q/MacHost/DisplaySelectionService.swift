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

struct CaptureInputConstraint {
    let kind: ShareTargetKind
    let mappingFrame: CGRect?
    let allowedFrames: [CGRect]
    let processID: pid_t?
}

@available(macOS 12.3, *)
struct ResolvedCaptureTarget {
    let id: String
    let kind: ShareTargetKind
    let filter: SCContentFilter
    let sourceRect: CGRect?
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: Double
    let pointHeight: Double
    let scaleFactor: Double
}

@available(macOS 12.3, *)
@MainActor
final class CaptureTargetSelectionService: ObservableObject {
    static let allDisplaysTargetID = "all-displays"

    struct CaptureTargetOption: Identifiable, Hashable {
        let id: String
        let kind: ShareTargetKind
        let name: String
        let detail: String?
        let displayID: CGDirectDisplayID?
        let pixelWidth: Int
        let pixelHeight: Int
        let windowID: CGWindowID?
        let processID: pid_t?
        let bundleIdentifier: String?
        let mappingFrame: CGRect?
        let allowedFrames: [CGRect]

        var protocolInfo: ShareTargetInfo {
            ShareTargetInfo(
                id: id,
                kind: kind,
                name: name,
                detail: detail,
                displayID: displayID,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
    }

    @Published private(set) var targets: [CaptureTargetOption] = []
    @Published var selectedTargetID: String? {
        didSet {
            applyDisplaySelectionForSelectedTarget()
            updateActiveInputConstraint()
        }
    }

    private let displaySelection: DisplaySelectionService
    private let selfBundleID = Bundle.main.bundleIdentifier ?? ""
    private var activeInputConstraintCache: CaptureInputConstraint?

    init(displaySelection: DisplaySelectionService) {
        self.displaySelection = displaySelection
    }

    func refresh() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            refresh(using: content)
        } catch {
            Logger.shared.warn("Share target refresh failed: \(error.localizedDescription)")
        }
    }

    func refresh(using content: SCShareableContent) {
        let nextTargets = buildTargets(from: content)
        if targets != nextTargets {
            targets = nextTargets
        }
        validateSelection()
        updateActiveInputConstraint()
    }

    func selectDisplayTarget(_ displayID: CGDirectDisplayID) {
        if displayID == DisplaySelectionService.allDisplaysID {
            selectedTargetID = Self.allDisplaysTargetID
        } else {
            selectedTargetID = Self.displayTargetID(displayID)
        }
    }

    func targetListMessage() -> ShareTargetListMessage {
        targetListMessage(activeTargetID: selectedTargetID)
    }

    func targetListMessage(activeTargetID: String?) -> ShareTargetListMessage {
        ShareTargetListMessage(
            targets: targets.map(\.protocolInfo),
            activeTargetID: activeTargetID ?? selectedTargetID
        )
    }

    func activeInputConstraint() -> CaptureInputConstraint? {
        activeInputConstraintCache
    }

    func activeTargetID() -> String? {
        selectedTargetID
    }

    func isAllDisplaysTarget(_ targetID: String?) -> Bool {
        (targetID ?? selectedTargetID) == Self.allDisplaysTargetID
    }

    func displayID(forTargetID targetID: String?) -> CGDirectDisplayID? {
        target(withID: targetID)?.displayID
    }

    func inputConstraint(forTargetID targetID: String?) -> CaptureInputConstraint? {
        guard let target = target(withID: targetID) else { return nil }
        switch target.kind {
        case .allDisplays, .display:
            return nil
        case .application, .window:
            return CaptureInputConstraint(
                kind: target.kind,
                mappingFrame: target.mappingFrame,
                allowedFrames: target.allowedFrames,
                processID: target.processID
            )
        }
    }

    func resolvedTarget(id targetID: String?, in content: SCShareableContent) throws -> ResolvedCaptureTarget {
        guard let target = target(withID: targetID) else {
            throw NSError(
                domain: "ScreenQ.CaptureTarget", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No share target selected"]
            )
        }
        return try resolvedTarget(target, in: content)
    }

    func resolvedTarget(in content: SCShareableContent) throws -> ResolvedCaptureTarget {
        guard let target = target(withID: selectedTargetID) else {
            throw NSError(
                domain: "ScreenQ.CaptureTarget", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No share target selected"]
            )
        }
        return try resolvedTarget(target, in: content)
    }

    private func resolvedTarget(_ target: CaptureTargetOption, in content: SCShareableContent) throws -> ResolvedCaptureTarget {
        switch target.kind {
        case .allDisplays:
            throw NSError(
                domain: "ScreenQ.CaptureTarget", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "All displays is handled by the compositor path"]
            )
        case .display:
            guard let displayID = target.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NSError(
                    domain: "ScreenQ.CaptureTarget", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Selected display is no longer available"]
                )
            }
            let excludedApps = content.applications.filter { $0.bundleIdentifier == selfBundleID }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            return resolvedTarget(target, filter: filter, display: display, sourceRect: nil)
        case .application:
            guard let displayID = target.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }),
                  let processID = target.processID,
                  let app = content.applications.first(where: { $0.processID == processID }) else {
                throw NSError(
                    domain: "ScreenQ.CaptureTarget", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Selected app is no longer shareable"]
                )
            }
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            return resolvedTarget(
                target,
                filter: filter,
                display: display,
                sourceRect: displayLocalRect(for: target.mappingFrame, in: display)
            )
        case .window:
            guard let windowID = target.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw NSError(
                    domain: "ScreenQ.CaptureTarget", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Selected window is no longer shareable"]
                )
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return resolvedTarget(target, filter: filter, display: nil, sourceRect: nil)
        }
    }

    var isAllDisplaysSelected: Bool {
        selectedTargetID == Self.allDisplaysTargetID
    }

    private func selectedTarget() -> CaptureTargetOption? {
        target(withID: selectedTargetID)
    }

    private func target(withID targetID: String?) -> CaptureTargetOption? {
        let resolvedID = targetID ?? selectedTargetID
        guard let resolvedID else { return targets.first }
        return targets.first { $0.id == resolvedID }
    }

    private func validateSelection() {
        guard !targets.isEmpty else {
            selectedTargetID = nil
            return
        }
        if let selectedTargetID, targets.contains(where: { $0.id == selectedTargetID }) {
            applyDisplaySelectionForSelectedTarget()
            return
        }
        if displaySelection.isAllDisplaysSelected,
           targets.contains(where: { $0.id == Self.allDisplaysTargetID }) {
            selectedTargetID = Self.allDisplaysTargetID
            return
        }
        if let selectedDisplayID = displaySelection.selectedDisplayID,
           targets.contains(where: { $0.id == Self.displayTargetID(selectedDisplayID) }) {
            selectedTargetID = Self.displayTargetID(selectedDisplayID)
            return
        }
        selectedTargetID = targets.first?.id
    }

    private func applyDisplaySelectionForSelectedTarget() {
        guard let target = selectedTarget() else { return }
        switch target.kind {
        case .allDisplays:
            displaySelection.selectedDisplayID = DisplaySelectionService.allDisplaysID
        case .display, .application, .window:
            if let displayID = target.displayID {
                displaySelection.selectedDisplayID = displayID
            }
        }
    }

    private func buildTargets(from content: SCShareableContent) -> [CaptureTargetOption] {
        let displays = content.displays.sorted { $0.displayID < $1.displayID }

        var result: [CaptureTargetOption] = []
        if displays.count > 1, let all = displaySelection.allDisplaysInfo() {
            result.append(CaptureTargetOption(
                id: Self.allDisplaysTargetID,
                kind: .allDisplays,
                name: "All Displays",
                detail: nil,
                displayID: DisplaySelectionService.allDisplaysID,
                pixelWidth: all.pixelWidth,
                pixelHeight: all.pixelHeight,
                windowID: nil,
                processID: nil,
                bundleIdentifier: nil,
                mappingFrame: nil,
                allowedFrames: []
            ))
        }

        for display in displays {
            result.append(CaptureTargetOption(
                id: Self.displayTargetID(display.displayID),
                kind: .display,
                name: "Display \(display.displayID)",
                detail: nil,
                displayID: display.displayID,
                pixelWidth: Int(display.width),
                pixelHeight: Int(display.height),
                windowID: nil,
                processID: nil,
                bundleIdentifier: nil,
                mappingFrame: nil,
                allowedFrames: []
            ))
        }

        let shareableWindows = content.windows
            .compactMap { window -> (window: SCWindow, owner: SCRunningApplication, display: SCDisplay, bounds: CGRect, scale: Double)? in
                guard window.windowLayer == 0,
                      window.isOnScreen,
                      let owner = window.owningApplication,
                      owner.bundleIdentifier != selfBundleID else {
                    return nil
                }
                let bounds = window.frame
                guard bounds.width >= 80, bounds.height >= 60 else { return nil }
                guard let display = bestDisplay(for: bounds, in: displays) else { return nil }
                return (window, owner, display, bounds, displayScale(for: display.displayID))
            }

        let appTargets = applicationTargets(from: shareableWindows)
        result.append(contentsOf: appTargets.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison == .orderedSame {
                return ($0.detail ?? "").localizedCaseInsensitiveCompare($1.detail ?? "") == .orderedAscending
            }
            return comparison == .orderedAscending
        })

        let windowTargets = shareableWindows.compactMap { item -> CaptureTargetOption? in
            let window = item.window
            let owner = item.owner
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title?.isEmpty == false ? title! : owner.applicationName
            let bounds = item.bounds
            return CaptureTargetOption(
                id: Self.windowTargetID(window.windowID),
                kind: .window,
                name: name,
                detail: "\(owner.applicationName) window on \(displayName(for: item.display))",
                displayID: item.display.displayID,
                pixelWidth: max(1, Int((bounds.width * item.scale).rounded())),
                pixelHeight: max(1, Int((bounds.height * item.scale).rounded())),
                windowID: window.windowID,
                processID: owner.processID,
                bundleIdentifier: owner.bundleIdentifier,
                mappingFrame: bounds,
                allowedFrames: [bounds]
            )
        }
        result.append(contentsOf: windowTargets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })

        return result
    }

    private struct ApplicationDisplayKey: Hashable {
        let processID: pid_t
        let displayID: CGDirectDisplayID
    }

    private struct ApplicationDisplayGroup {
        let owner: SCRunningApplication
        let display: SCDisplay
        var frames: [CGRect]
        let scale: Double
    }

    private func applicationTargets(
        from windows: [(window: SCWindow, owner: SCRunningApplication, display: SCDisplay, bounds: CGRect, scale: Double)]
    ) -> [CaptureTargetOption] {
        var groups: [ApplicationDisplayKey: ApplicationDisplayGroup] = [:]
        for item in windows {
            let key = ApplicationDisplayKey(
                processID: item.owner.processID,
                displayID: item.display.displayID
            )
            if var group = groups[key] {
                group.frames.append(item.bounds)
                groups[key] = group
            } else {
                groups[key] = ApplicationDisplayGroup(
                    owner: item.owner,
                    display: item.display,
                    frames: [item.bounds],
                    scale: item.scale
                )
            }
        }

        return groups.values.compactMap { group in
            let union = unionRect(group.frames)
            guard !union.isNull, !union.isEmpty else { return nil }
            let windowCount = group.frames.count
            return CaptureTargetOption(
                id: Self.applicationTargetID(
                    processID: group.owner.processID,
                    displayID: group.display.displayID
                ),
                kind: .application,
                name: group.owner.applicationName,
                detail: "\(windowCount) \(windowCount == 1 ? "window" : "windows") on \(displayName(for: group.display))",
                displayID: group.display.displayID,
                pixelWidth: max(1, Int((union.width * group.scale).rounded())),
                pixelHeight: max(1, Int((union.height * group.scale).rounded())),
                windowID: nil,
                processID: group.owner.processID,
                bundleIdentifier: group.owner.bundleIdentifier,
                mappingFrame: union,
                allowedFrames: group.frames
            )
        }
    }

    private func bestDisplay(for frame: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays
            .map { display -> (display: SCDisplay, area: CGFloat) in
                let intersection = frame.intersection(display.frame)
                let area = intersection.isNull || intersection.isEmpty ? 0 : intersection.width * intersection.height
                return (display, area)
            }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }?
            .display
    }

    private func unionRect(_ frames: [CGRect]) -> CGRect {
        frames.reduce(CGRect.null) { partial, frame in
            partial.union(frame)
        }
    }

    private func displayName(for display: SCDisplay) -> String {
        "Display \(display.displayID)"
    }

    private func resolvedTarget(
        _ target: CaptureTargetOption,
        filter: SCContentFilter,
        display: SCDisplay?,
        sourceRect: CGRect?
    ) -> ResolvedCaptureTarget {
        let displayID = target.displayID ?? display?.displayID ?? 0
        let scale = display.map { displayScale(for: $0.displayID) } ?? targetScale(for: target)
        let usesFullDisplayGeometry = target.kind == .display
        return ResolvedCaptureTarget(
            id: target.id,
            kind: target.kind,
            filter: filter,
            sourceRect: sourceRect,
            displayID: displayID,
            pixelWidth: usesFullDisplayGeometry ? (display.map { Int($0.width) } ?? target.pixelWidth) : target.pixelWidth,
            pixelHeight: usesFullDisplayGeometry ? (display.map { Int($0.height) } ?? target.pixelHeight) : target.pixelHeight,
            pointWidth: usesFullDisplayGeometry ? (display.map { Double($0.frame.width) } ?? targetPointWidth(target)) : targetPointWidth(target),
            pointHeight: usesFullDisplayGeometry ? (display.map { Double($0.frame.height) } ?? targetPointHeight(target)) : targetPointHeight(target),
            scaleFactor: scale
        )
    }

    private func targetPointWidth(_ target: CaptureTargetOption) -> Double {
        return Double(target.mappingFrame?.width ?? CGFloat(target.pixelWidth))
    }

    private func targetPointHeight(_ target: CaptureTargetOption) -> Double {
        return Double(target.mappingFrame?.height ?? CGFloat(target.pixelHeight))
    }

    private func displayLocalRect(for frame: CGRect?, in display: SCDisplay) -> CGRect? {
        guard let frame else { return nil }
        let visible = frame.intersection(display.frame)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return CGRect(
            x: visible.minX - display.frame.minX,
            y: visible.minY - display.frame.minY,
            width: visible.width,
            height: visible.height
        )
    }

    private func updateActiveInputConstraint() {
        guard let target = selectedTarget() else {
            activeInputConstraintCache = nil
            return
        }
        switch target.kind {
        case .allDisplays, .display:
            activeInputConstraintCache = nil
        case .application, .window:
            activeInputConstraintCache = CaptureInputConstraint(
                kind: target.kind,
                mappingFrame: target.mappingFrame,
                allowedFrames: target.allowedFrames,
                processID: target.processID
            )
        }
    }

    private func targetScale(for target: CaptureTargetOption) -> Double {
        guard let displayID = target.displayID else { return 1.0 }
        return displayScale(for: displayID)
    }

    private func displayScale(for displayID: CGDirectDisplayID) -> Double {
        if let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenNumber == displayID
        }) {
            return Double(screen.backingScaleFactor)
        }
        return 1.0
    }

    static func displayTargetID(_ displayID: CGDirectDisplayID) -> String {
        "display:\(displayID)"
    }

    private static func windowTargetID(_ windowID: CGWindowID) -> String {
        "window:\(windowID)"
    }

    private static func applicationTargetID(processID: pid_t, displayID: CGDirectDisplayID) -> String {
        "application:\(processID):display:\(displayID)"
    }
}
#endif
