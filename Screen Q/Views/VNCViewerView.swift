//
//  VNCViewerView.swift
//  Screen Q
//
//  SwiftUI view for a native VNC session — displays the remote framebuffer,
//  forwards mouse/keyboard input, and handles VNC password prompts.
//

import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

struct VNCViewerView: View {
    @ObservedObject var session: VNCSession
    var onDisconnect: () -> Void
    #if os(iOS)
    @StateObject private var iosInputState = VNCIOSInputState()
    @State private var isKeyboardActive = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            #if os(iOS)
            if case .connected = session.phase {
                VNCIOSControlStrip(
                    session: session,
                    inputState: iosInputState,
                    securityStatus: session.securityStatus,
                    isKeyboardActive: $isKeyboardActive,
                    onDisconnect: {
                        Task { await session.disconnect() }
                        onDisconnect()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

                VNCKeyboardInputView(
                    session: session,
                    inputState: iosInputState,
                    isActive: $isKeyboardActive
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
            #endif
        }
        .navigationTitle(session.serverName.isEmpty ? session.peerLabel : session.serverName)
        #if os(macOS)
        .navigationSubtitle(statusText)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                VNCConnectionSecurityMenu(status: session.securityStatus)
            }
            ToolbarItem(placement: .automatic) {
                Button("Disconnect") {
                    Task { await session.disconnect() }
                    onDisconnect()
                }
                .foregroundColor(.red)
            }
        }
        .sheet(isPresented: $session.needsPassword) {
            VNCPasswordSheet(
                title: vncPasswordTitle,
                message: vncPasswordMessage,
                password: $session.vncPassword,
                rememberCredentials: $session.rememberCredentials,
                requireLocalAuthenticationForSavedCredentials: $session.requireLocalAuthenticationForSavedCredentials,
                onConnect: { Task { await session.retryWithPassword() } },
                onCancel: onDisconnect
            )
        }
        .sheet(isPresented: $session.needsCredentials) {
            VNCCredentialsSheet(
                username: $session.username,
                password: $session.vncPassword,
                rememberCredentials: $session.rememberCredentials,
                requireLocalAuthenticationForSavedCredentials: $session.requireLocalAuthenticationForSavedCredentials,
                onConnect: { Task { await session.retryWithCredentials() } },
                onCancel: onDisconnect
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(session.peerLabel)…")
                    .foregroundColor(.secondary)
                VNCConnectionSecurityBadge(status: session.securityStatus)
            }

        case .authenticating:
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                Text("Authenticating…")
                    .foregroundColor(.secondary)
                VNCConnectionSecurityBadge(status: session.securityStatus)
            }

        case .connected:
            vncCanvas

        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text("Connection Failed")
                    .font(.headline)
                Text(reason)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Dismiss") { onDisconnect() }
                    .buttonStyle(.bordered)
            }

        case .ended(let reason):
            VStack(spacing: 12) {
                Image(systemName: "rectangle.badge.xmark")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Session Ended")
                    .font(.headline)
                Text(reason)
                    .foregroundColor(.secondary)
                Button("Done") { onDisconnect() }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var vncCanvas: some View {
        #if os(macOS)
        VNCInputView(session: session)
        #else
        if let image = session.currentImage {
            GeometryReader { geo in
                let imgW = CGFloat(session.serverWidth)
                let imgH = CGFloat(session.serverHeight)
                let scale = min(geo.size.width / imgW, geo.size.height / imgH, 1.0)
                let displayW = imgW * scale
                let displayH = imgH * scale
                let offsetX = (geo.size.width - displayW) / 2
                let offsetY = (geo.size.height - displayH) / 2

                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayW, height: displayH)
                    .position(x: offsetX + displayW / 2, y: offsetY + displayH / 2)

                VNCIOSTouchInputOverlay(
                    session: session,
                    inputState: iosInputState,
                    serverSize: CGSize(width: imgW, height: imgH),
                    displayScale: scale
                )
                .frame(width: displayW, height: displayH)
                .position(x: offsetX + displayW / 2, y: offsetY + displayH / 2)
            }
        } else {
            ProgressView("Waiting for framebuffer…")
        }
        #endif
    }

    private var statusText: String {
        switch session.phase {
        case .connecting: return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .connected: return "\(session.serverWidth)×\(session.serverHeight) — \(session.profile.displayName)"
        case .failed: return "Failed"
        case .ended: return "Ended"
        }
    }

    private var vncPasswordTitle: String {
        session.profile == .macScreenSharing ? "Legacy VNC Password Required" : "VNC Password Required"
    }

    private var vncPasswordMessage: String {
        if session.profile == .macScreenSharing {
            return "The Mac did not accept or offer macOS account authentication. Enter the separate VNC password from Screen Sharing settings; do not reuse an admin password."
        }
        return "Enter the VNC password configured on the remote host."
    }
}

private struct VNCConnectionSecurityBadge: View {
    let status: RemoteSecurityStatus

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbolName)
                .foregroundColor(status.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                Text(status.detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                if let action = status.recommendedAction {
                    Text(action)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.orange)
                        .lineLimit(3)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct VNCConnectionSecurityMenu: View {
    let status: RemoteSecurityStatus

    var body: some View {
        Menu {
            Label(status.title, systemImage: status.symbolName)
            Text(status.detail)
            if let action = status.recommendedAction {
                Divider()
                Label(action, systemImage: "exclamationmark.triangle")
            }
        } label: {
            Image(systemName: status.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(status.tint)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection security")
    }
}

extension RemoteSecurityStatus {
    var symbolName: String {
        switch level {
        case .encrypted:
            return "lock.shield"
        case .networkProtected:
            return "network.badge.shield.half.filled"
        case .legacyAuth:
            return "lock.trianglebadge.exclamationmark"
        case .unprotected:
            return "exclamationmark.shield"
        case .unknown:
            return "shield.lefthalf.filled"
        }
    }

    var tint: Color {
        switch level {
        case .encrypted:
            return .green
        case .networkProtected:
            return .blue
        case .legacyAuth:
            return .orange
        case .unprotected:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

#if os(iOS)
private struct VNCIOSTouchInputOverlay: UIViewRepresentable {
    @ObservedObject var session: VNCSession
    @ObservedObject var inputState: VNCIOSInputState
    let serverSize: CGSize
    let displayScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, inputState: inputState, serverSize: serverSize, displayScale: displayScale)
    }

    func makeUIView(context: Context) -> TouchInputView {
        let view = TouchInputView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = context.coordinator

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        singleTap.require(toFail: doubleTap)

        let rightTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        rightTap.numberOfTapsRequired = 1
        rightTap.delegate = context.coordinator

        let middleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMiddleTap(_:)))
        middleTap.numberOfTouchesRequired = 3
        middleTap.numberOfTapsRequired = 1
        middleTap.delegate = context.coordinator

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(rightTap)
        view.addGestureRecognizer(middleTap)

        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        drag.delegate = context.coordinator
        view.addGestureRecognizer(drag)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPressDrag(_:)))
        longPress.minimumPressDuration = 0.42
        longPress.allowableMovement = 16
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)

        let scroll = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = context.coordinator
        view.addGestureRecognizer(scroll)

        context.coordinator.dragRecognizer = drag
        context.coordinator.longPressRecognizer = longPress
        context.coordinator.scrollRecognizer = scroll
        return view
    }

    func updateUIView(_ uiView: TouchInputView, context: Context) {
        context.coordinator.session = session
        context.coordinator.inputState = inputState
        context.coordinator.serverSize = serverSize
        context.coordinator.displayScale = displayScale
    }

    final class TouchInputView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.contains(point)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var session: VNCSession?
        var inputState: VNCIOSInputState
        var serverSize: CGSize
        var displayScale: CGFloat
        weak var dragRecognizer: UIPanGestureRecognizer?
        weak var longPressRecognizer: UILongPressGestureRecognizer?
        weak var scrollRecognizer: UIPanGestureRecognizer?
        private var scrollRemainder: CGFloat = 0
        private var isDragging = false
        private let scrollStep: CGFloat = 18

        init(session: VNCSession, inputState: VNCIOSInputState, serverSize: CGSize, displayScale: CGFloat) {
            self.session = session
            self.inputState = inputState
            self.serverSize = serverSize
            self.displayScale = displayScale
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))
            sendClick(at: point, button: 0)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))
            sendClick(at: point, button: 0)
            sendClick(at: point, button: 0)
        }

        @objc func handleRightTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))
            sendClick(at: point, button: 2)
        }

        @objc func handleMiddleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))
            sendClick(at: point, button: 1)
        }

        @objc func handleDrag(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))

            switch recognizer.state {
            case .began:
                session?.sendMouseMove(x: point.x, y: point.y)
            case .changed:
                session?.sendMouseMove(x: point.x, y: point.y, buttons: isDragging ? 0x01 : 0)
            case .ended, .cancelled, .failed:
                if isDragging {
                    session?.sendMouseClick(x: point.x, y: point.y, button: 0, isDown: false)
                    isDragging = false
                }
            default:
                break
            }
        }

        @objc func handleLongPressDrag(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))

            switch recognizer.state {
            case .began:
                isDragging = true
                session?.sendMouseMove(x: point.x, y: point.y)
                session?.sendMouseClick(x: point.x, y: point.y, button: 0, isDown: true)
            case .changed:
                session?.sendMouseMove(x: point.x, y: point.y, buttons: 0x01)
            case .ended, .cancelled, .failed:
                session?.sendMouseClick(x: point.x, y: point.y, button: 0, isDown: false)
                isDragging = false
            default:
                break
            }
        }

        @objc func handleScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = remotePoint(from: recognizer.location(in: view))

            switch recognizer.state {
            case .began:
                scrollRemainder = 0
            case .changed:
                let translation = recognizer.translation(in: view)
                scrollRemainder += translation.y
                recognizer.setTranslation(.zero, in: view)

                while abs(scrollRemainder) >= scrollStep {
                    session?.sendScroll(x: point.x, y: point.y, deltaY: scrollRemainder > 0 ? 1 : -1)
                    scrollRemainder += scrollRemainder > 0 ? -scrollStep : scrollStep
                }
            case .ended, .cancelled, .failed:
                scrollRemainder = 0
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            (gestureRecognizer === dragRecognizer && otherGestureRecognizer === longPressRecognizer) ||
            (gestureRecognizer === longPressRecognizer && otherGestureRecognizer === dragRecognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        private func sendClick(at point: (x: Int, y: Int), button: Int) {
            inputState.sendMouseClick(session: session, x: point.x, y: point.y, button: button)
        }

        private func remotePoint(from localPoint: CGPoint) -> (x: Int, y: Int) {
            guard displayScale > 0, serverSize.width > 0, serverSize.height > 0 else {
                return (0, 0)
            }

            let x = Int((localPoint.x / displayScale).rounded(.down))
            let y = Int((localPoint.y / displayScale).rounded(.down))
            return (
                max(0, min(Int(serverSize.width) - 1, x)),
                max(0, min(Int(serverSize.height) - 1, y))
            )
        }
    }
}

private enum VNCKeySym {
    static let backspace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let returnKey: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B
    static let delete: UInt32 = 0xFFFF
    static let home: UInt32 = 0xFF50
    static let left: UInt32 = 0xFF51
    static let up: UInt32 = 0xFF52
    static let right: UInt32 = 0xFF53
    static let down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55
    static let pageDown: UInt32 = 0xFF56
    static let end: UInt32 = 0xFF57
    static let shiftLeft: UInt32 = 0xFFE1
    static let controlLeft: UInt32 = 0xFFE3
    static let altLeft: UInt32 = 0xFFE9
    static let superLeft: UInt32 = 0xFFEB

    static func function(_ index: Int) -> UInt32 {
        UInt32(0xFFBD + max(1, min(12, index)))
    }
}

private enum VNCIOSModifier: CaseIterable, Identifiable {
    case shift
    case control
    case alt
    case windows

    var id: String { label }

    var label: String {
        switch self {
        case .shift: return "Shift"
        case .control: return "Control"
        case .alt: return "Alt"
        case .windows: return "Windows"
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "S"
        case .control: return "C"
        case .alt: return "A"
        case .windows: return "Win"
        }
    }

    var keysym: UInt32 {
        switch self {
        case .shift: return VNCKeySym.shiftLeft
        case .control: return VNCKeySym.controlLeft
        case .alt: return VNCKeySym.altLeft
        case .windows: return VNCKeySym.superLeft
        }
    }
}

@MainActor
private final class VNCIOSInputState: ObservableObject {
    @Published private var states: [VNCIOSModifier: ModifierLatchState] = Dictionary(
        uniqueKeysWithValues: VNCIOSModifier.allCases.map { ($0, .off) }
    )

    func state(for modifier: VNCIOSModifier) -> ModifierLatchState {
        states[modifier] ?? .off
    }

    func toggleMomentary(_ modifier: VNCIOSModifier) {
        switch state(for: modifier) {
        case .off:
            states[modifier] = .momentary
        case .momentary, .locked:
            states[modifier] = .off
        }
    }

    func toggleLocked(_ modifier: VNCIOSModifier) {
        states[modifier] = state(for: modifier) == .locked ? .off : .locked
    }

    func clearAll() {
        states = Dictionary(uniqueKeysWithValues: VNCIOSModifier.allCases.map { ($0, .off) })
    }

    func sendText(_ text: String, session: VNCSession?) {
        for scalar in text.unicodeScalars {
            sendKey(scalar.value, session: session)
        }
    }

    func sendKey(_ key: UInt32, session: VNCSession?, explicitModifiers: [UInt32] = []) {
        let modifiers = mergedModifiers(explicitModifiers)
        if modifiers.isEmpty {
            session?.sendKeyTap(code: key)
        } else {
            session?.sendKeyCombo(code: key, modifiers: modifiers)
        }
        clearMomentary()
    }

    func sendMouseClick(session: VNCSession?, x: Int, y: Int, button: Int) {
        session?.sendMouseClick(x: x, y: y, button: button, isDown: true)
        session?.sendMouseClick(x: x, y: y, button: button, isDown: false)
        clearMomentary()
    }

    private func mergedModifiers(_ explicit: [UInt32]) -> [UInt32] {
        var result = explicit
        for modifier in VNCIOSModifier.allCases where state(for: modifier) != .off {
            let keysym = modifier.keysym
            if !result.contains(keysym) {
                result.append(keysym)
            }
        }
        return result
    }

    private func clearMomentary() {
        var next = states
        for (modifier, state) in states where state == .momentary {
            next[modifier] = .off
        }
        states = next
    }
}

private struct VNCIOSControlStrip: View {
    @ObservedObject var session: VNCSession
    @ObservedObject var inputState: VNCIOSInputState
    let securityStatus: RemoteSecurityStatus
    @Binding var isKeyboardActive: Bool
    var onDisconnect: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                iconButton(systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard",
                           label: isKeyboardActive ? "Hide keyboard" : "Show keyboard") {
                    isKeyboardActive.toggle()
                }

                VNCConnectionSecurityMenu(status: securityStatus)

                ForEach(VNCIOSModifier.allCases) { modifier in
                    modifierButton(modifier)
                }

                specialKeysMenu
                arrowsMenu
                functionKeysMenu
                windowsMenu

                iconButton(systemName: "xmark.circle", label: "Disconnect", tint: .red) {
                    onDisconnect()
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 58)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
    }

    private func modifierButton(_ modifier: VNCIOSModifier) -> some View {
        let state = inputState.state(for: modifier)
        return Text(modifier.symbol)
            .font(.system(size: modifier == .windows ? 12 : 15, weight: .semibold))
            .frame(width: 38, height: 38)
            .foregroundStyle(state == .off ? Color.primary : Color.white)
            .background(modifierBackground(for: state))
            .clipShape(Circle())
            .onTapGesture(count: 2) {
                inputState.toggleLocked(modifier)
            }
            .onTapGesture {
                inputState.toggleMomentary(modifier)
            }
            .accessibilityLabel("\(modifier.label) modifier")
    }

    private func modifierBackground(for state: ModifierLatchState) -> Color {
        switch state {
        case .off: return Color.primary.opacity(0.08)
        case .momentary: return Color.accentColor.opacity(0.72)
        case .locked: return Color.accentColor
        }
    }

    private var specialKeysMenu: some View {
        Menu {
            Button("Escape") { inputState.sendKey(VNCKeySym.escape, session: session) }
            Button("Tab") { inputState.sendKey(VNCKeySym.tab, session: session) }
            Button("Return") { inputState.sendKey(VNCKeySym.returnKey, session: session) }
            Button("Backspace") { inputState.sendKey(VNCKeySym.backspace, session: session) }
            Button("Delete") { inputState.sendKey(VNCKeySym.delete, session: session) }
            Button("Home") { inputState.sendKey(VNCKeySym.home, session: session) }
            Button("End") { inputState.sendKey(VNCKeySym.end, session: session) }
            Button("Page Up") { inputState.sendKey(VNCKeySym.pageUp, session: session) }
            Button("Page Down") { inputState.sendKey(VNCKeySym.pageDown, session: session) }
            Button("Clear Modifiers") { inputState.clearAll() }
        } label: {
            Image(systemName: "command.square")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Special keys")
    }

    private var arrowsMenu: some View {
        Menu {
            Button("Up") { inputState.sendKey(VNCKeySym.up, session: session) }
            Button("Down") { inputState.sendKey(VNCKeySym.down, session: session) }
            Button("Left") { inputState.sendKey(VNCKeySym.left, session: session) }
            Button("Right") { inputState.sendKey(VNCKeySym.right, session: session) }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arrow keys")
    }

    private var functionKeysMenu: some View {
        Menu {
            ForEach(1...12, id: \.self) { index in
                Button("F\(index)") {
                    inputState.sendKey(VNCKeySym.function(index), session: session)
                }
            }
        } label: {
            Text("F")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Function keys")
    }

    private var windowsMenu: some View {
        Menu {
            Button("Ctrl Alt Del") {
                session.sendKeyCombo(code: VNCKeySym.delete, modifiers: [VNCKeySym.controlLeft, VNCKeySym.altLeft])
            }
            Button("Alt Tab") {
                session.sendKeyCombo(code: VNCKeySym.tab, modifiers: [VNCKeySym.altLeft])
            }
            Button("Windows") {
                inputState.sendKey(VNCKeySym.superLeft, session: session)
            }
            Button("Windows D") {
                session.sendKeyCombo(code: 0x0064, modifiers: [VNCKeySym.superLeft])
            }
            Button("Windows L") {
                session.sendKeyCombo(code: 0x006C, modifiers: [VNCKeySym.superLeft])
            }
        } label: {
            Image(systemName: "pc")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Windows shortcuts")
    }

    private func iconButton(
        systemName: String,
        label: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct VNCKeyboardInputView: UIViewRepresentable {
    @ObservedObject var session: VNCSession
    @ObservedObject var inputState: VNCIOSInputState
    @Binding var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, inputState: inputState, isActive: $isActive)
    }

    func makeUIView(context: Context) -> VNCKeyboardTextField {
        let field = VNCKeyboardTextField()
        field.coordinator = context.coordinator
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .default
        field.returnKeyType = .default
        return field
    }

    func updateUIView(_ uiView: VNCKeyboardTextField, context: Context) {
        context.coordinator.session = session
        context.coordinator.inputState = inputState
        context.coordinator.isActive = $isActive
        if isActive && !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !isActive && uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        weak var session: VNCSession?
        var inputState: VNCIOSInputState
        var isActive: Binding<Bool>

        init(session: VNCSession, inputState: VNCIOSInputState, isActive: Binding<Bool>) {
            self.session = session
            self.inputState = inputState
            self.isActive = isActive
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.isActive.wrappedValue = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.isActive.wrappedValue = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            inputState.sendKey(VNCKeySym.returnKey, session: session)
            return false
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                inputState.sendKey(VNCKeySym.backspace, session: session)
            } else {
                inputState.sendText(string, session: session)
            }
            return false
        }
    }
}

private final class VNCKeyboardTextField: UITextField {
    weak var coordinator: VNCKeyboardInputView.Coordinator?

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleSpecialKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [.control], action: #selector(handleSpecialKey(_:))),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleSpecialKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleSpecialKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleSpecialKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleSpecialKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleSpecialKey(_:))),
        ]
    }

    override func deleteBackward() {
        coordinator?.inputState.sendKey(VNCKeySym.backspace, session: coordinator?.session)
    }

    @objc private func handleSpecialKey(_ command: UIKeyCommand) {
        guard let coordinator else { return }
        let modifiers = vncModifiers(from: command.modifierFlags)
        switch command.input {
        case UIKeyCommand.inputEscape:
            coordinator.inputState.sendKey(VNCKeySym.escape, session: coordinator.session, explicitModifiers: modifiers)
        case "\t":
            coordinator.inputState.sendKey(VNCKeySym.tab, session: coordinator.session, explicitModifiers: modifiers)
        case UIKeyCommand.inputUpArrow:
            coordinator.inputState.sendKey(VNCKeySym.up, session: coordinator.session, explicitModifiers: modifiers)
        case UIKeyCommand.inputDownArrow:
            coordinator.inputState.sendKey(VNCKeySym.down, session: coordinator.session, explicitModifiers: modifiers)
        case UIKeyCommand.inputLeftArrow:
            coordinator.inputState.sendKey(VNCKeySym.left, session: coordinator.session, explicitModifiers: modifiers)
        case UIKeyCommand.inputRightArrow:
            coordinator.inputState.sendKey(VNCKeySym.right, session: coordinator.session, explicitModifiers: modifiers)
        default:
            break
        }
    }

    private func vncModifiers(from flags: UIKeyModifierFlags) -> [UInt32] {
        var modifiers: [UInt32] = []
        if flags.contains(.shift) { modifiers.append(VNCKeySym.shiftLeft) }
        if flags.contains(.control) { modifiers.append(VNCKeySym.controlLeft) }
        if flags.contains(.alternate) { modifiers.append(VNCKeySym.altLeft) }
        if flags.contains(.command) { modifiers.append(VNCKeySym.superLeft) }
        return modifiers
    }
}
#endif

// MARK: - Password / Credentials Sheets (macOS 11.5+)

private struct VNCPasswordSheet: View {
    let title: String
    let message: String
    @Binding var password: String
    @Binding var rememberCredentials: Bool
    @Binding var requireLocalAuthenticationForSavedCredentials: Bool
    var onConnect: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Toggle("Remember in Keychain", isOn: $rememberCredentials)
                .frame(maxWidth: 260)
            if rememberCredentials {
                Toggle("Require Touch ID / Face ID / passcode before reuse", isOn: $requireLocalAuthenticationForSavedCredentials)
                    .frame(maxWidth: 260)
            }
            Text("Saved Mac Screen Sharing credentials stay in this device's Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { onConnect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}

private struct VNCCredentialsSheet: View {
    @Binding var username: String
    @Binding var password: String
    @Binding var rememberCredentials: Bool
    @Binding var requireLocalAuthenticationForSavedCredentials: Bool
    var onConnect: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("macOS Login Required").font(.headline)
            Text("Enter the macOS username and password for the remote Mac.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Toggle("Remember in Keychain", isOn: $rememberCredentials)
                .frame(maxWidth: 260)
            if rememberCredentials {
                Toggle("Require Touch ID / Face ID / passcode before reuse", isOn: $requireLocalAuthenticationForSavedCredentials)
                    .frame(maxWidth: 260)
            }
            Text("Saved VNC credentials stay in this device's Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { onConnect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
