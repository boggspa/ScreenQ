//
//  TrackpadInputView.swift
//  Screen Q
//
//  Advanced touch input handling for iOS viewers. Provides:
//  - Single tap → left click
//  - Long press → right click
//  - Two-finger scroll
//  - Pinch to zoom (optional)
//  - Three-finger drag
//

import SwiftUI

#if os(iOS)
struct TrackpadInputView: UIViewRepresentable {

    let inputMapper: InputMappingService
    let touchMode: TouchMode
    let canvasSize: CGSize
    let remotePixelSize: CGSize
    let fit: Bool
    let viewport: ViewportTransform
    let viewportPanInsets: ViewportPanInsets
    let onViewportChange: (ViewportTransform) -> Void
    let onViewportScaleChange: (CGFloat?) -> Void
    let onControlsToggle: () -> Void
    let onDragFeedbackChange: (IOSDragFeedback?) -> Void

    func makeUIView(context: Context) -> TrackpadTouchView {
        let view = TrackpadTouchView()
        view.inputMapper = inputMapper
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ uiView: TrackpadTouchView, context: Context) {
        uiView.touchMode = touchMode
        uiView.canvasSize = canvasSize
        uiView.remotePixelSize = remotePixelSize
        uiView.fit = fit
        uiView.viewport = viewport
        uiView.viewportPanInsets = viewportPanInsets
        uiView.inputMapper = inputMapper
        uiView.onViewportChange = onViewportChange
        uiView.onViewportScaleChange = onViewportScaleChange
        uiView.onControlsToggle = onControlsToggle
        uiView.onDragFeedbackChange = onDragFeedbackChange
    }
}

struct IOSDragFeedback: Equatable {
    enum Kind: Equatable {
        case left
        case right
    }

    var kind: Kind
    var point: CGPoint
}

final class TrackpadTouchView: UIView {

    var inputMapper: InputMappingService?
    var touchMode: TouchMode = .directTouch
    var canvasSize: CGSize = .zero
    var remotePixelSize: CGSize = .zero
    var fit: Bool = true
    var viewport: ViewportTransform = .identity
    var viewportPanInsets: ViewportPanInsets = .zero
    var onViewportChange: ((ViewportTransform) -> Void)?
    var onViewportScaleChange: ((CGFloat?) -> Void)?
    var onControlsToggle: (() -> Void)?
    var onDragFeedbackChange: ((IOSDragFeedback?) -> Void)?

    private var longPressTimer: Timer?
    private var pendingTwoFingerTapTimer: Timer?
    private var lastTouchCount: Int = 0
    private var twoFingerResolver = TrackpadTwoFingerGestureResolver()
    private var pendingOneFingerTapTimer: Timer?
    private var lastOneFingerTapTime: Date?
    private var touchStartTime: Date?
    private var touchStartPoint: CGPoint = .zero
    private var touchStartCenter: CGPoint = .zero
    private var isDragging = false
    private var dragButton: PointerButton?
    private var didMoveBeyondTap = false
    private var lastTwoFingerTapTime: Date?
    private var previousTrackpadPoint: CGPoint?
    private var previousIndirectScrollTranslation: CGPoint = .zero
    private var lastViewportFollowUpdate = Date.distantPast
    private var localInteractionStarted = false
    private let longPressDuration: TimeInterval = 0.5
    private let tapMaxDistance: CGFloat = 10
    private let doubleTapInterval: TimeInterval = 0.32
    private let edgeActivationInset: CGFloat = 28
    private let edgeSwipeDistance: CGFloat = 52
    private let viewportFollowInset: CGFloat = 78
    private let viewportFollowMaxStep: CGFloat = 42
    private let viewportFollowInterval: TimeInterval = 1.0 / 60.0
    private let trackpadSensitivity: CGFloat = 1.15

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        if #available(iOS 13.4, *) {
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
            configureIndirectPointerGestures()
        }
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let allTouches = event?.allTouches ?? touches
        beginInputInteraction()
        lastTouchCount = allTouches.count
        didMoveBeyondTap = false
        touchStartTime = Date()
        touchStartCenter = averageLocation(allTouches)
        touchStartPoint = touches.first?.location(in: self) ?? touchStartCenter

        if allTouches.count == 1, touchMode != .scrollOnly {
            pendingOneFingerTapTimer?.invalidate()
            pendingOneFingerTapTimer = nil
            isDragging = false
            previousTrackpadPoint = touchStartPoint

            // One-finger long press begins a left-button drag.
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard !self.didMoveBeyondTap else { return }
                    if self.touchMode == .trackpad {
                        self.inputMapper?.sendPointerDownAtCurrent(button: .left)
                    } else {
                        self.inputMapper?.sendPointerDown(localPoint: self.touchStartPoint, button: .left)
                    }
                    self.dragButton = .left
                    self.isDragging = true
                    self.onDragFeedbackChange?(IOSDragFeedback(kind: .left, point: self.touchStartPoint))
                }
            }
        } else if allTouches.count == 2 {
            // Two-finger scroll / pinch starting point. A stationary two-finger
            // hold starts a secondary-button drag.
            let center = averageLocation(allTouches)
            previousTrackpadPoint = center
            let distance = distanceBetweenTouches(allTouches)
            twoFingerResolver.begin(center: center, distance: distance)
            pendingTwoFingerTapTimer?.invalidate()
            pendingTwoFingerTapTimer = nil
            longPressTimer?.invalidate()
            if touchMode != .scrollOnly {
                longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.didMoveBeyondTap else { return }
                        if self.touchMode == .trackpad {
                            self.inputMapper?.sendPointerDownAtCurrent(button: .right)
                        } else {
                            self.inputMapper?.sendPointerDown(localPoint: center, button: .right)
                        }
                        self.dragButton = .right
                        self.isDragging = true
                        self.onDragFeedbackChange?(IOSDragFeedback(kind: .right, point: center))
                    }
                }
            }
        } else if allTouches.count == 3 {
            longPressTimer?.invalidate()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let mapper = inputMapper else { return }
        let allTouches = event?.allTouches ?? touches
        let center = averageLocation(allTouches)
        let movement = hypot(center.x - touchStartCenter.x, center.y - touchStartCenter.y)
        if movement > tapMaxDistance {
            didMoveBeyondTap = true
            if !isDragging {
                longPressTimer?.invalidate()
            }
        }

        // Trackpad mode mirrors Screens-style cursor control: one finger
        // moves the pointer. Direct-touch mode keeps one-finger movement
        // local until a hold-drag has explicitly started.
        if touchStartTime != nil, allTouches.count == 1, touchMode != .scrollOnly {
            if let touch = touches.first {
                let loc = touch.location(in: self)
                if touchMode == .trackpad {
                    let previous = previousTrackpadPoint ?? loc
                    let delta = CGSize(width: loc.x - previous.x, height: loc.y - previous.y)
                    let pointer = mapper.sendPointerMove(relativeLocalDelta: delta, sensitivity: trackpadSensitivity)
                    followViewportIfNeeded(pointer: pointer)
                    previousTrackpadPoint = loc
                } else if isDragging {
                    mapper.sendPointerMove(localPoint: loc)
                }
                if isDragging {
                    onDragFeedbackChange?(IOSDragFeedback(kind: dragButton == .right ? .right : .left, point: loc))
                }
            }
        }

        if allTouches.count == 2 {
            let center = averageLocation(allTouches)
            let distance = distanceBetweenTouches(allTouches)
            if isDragging {
                if touchMode == .trackpad {
                    let previous = previousTrackpadPoint ?? center
                    let delta = CGSize(width: center.x - previous.x, height: center.y - previous.y)
                    let pointer = mapper.sendPointerMove(relativeLocalDelta: delta, sensitivity: trackpadSensitivity)
                    followViewportIfNeeded(pointer: pointer)
                    previousTrackpadPoint = center
                } else {
                    mapper.sendPointerMove(localPoint: center)
                }
                onDragFeedbackChange?(IOSDragFeedback(kind: dragButton == .right ? .right : .left, point: center))
            } else {
                switch twoFingerResolver.update(center: center, distance: distance) {
                case .none:
                    break
                case .remoteScroll(let delta):
                    didMoveBeyondTap = true
                    longPressTimer?.invalidate()
                    if touchMode == .trackpad {
                        mapper.sendScrollAtCurrent(deltaX: Double(delta.width) * 3.0, deltaY: Double(delta.height) * 3.0)
                    } else {
                        mapper.sendScroll(deltaX: Double(delta.width) * 3.0, deltaY: Double(delta.height) * 3.0, localPoint: center)
                    }
                case .viewportPinch(let update):
                    didMoveBeyondTap = true
                    longPressTimer?.invalidate()
                    applyViewportGesture(update)
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let mapper = inputMapper else { return }
        longPressTimer?.invalidate()
        onViewportScaleChange?(nil)

        if isDragging {
            let loc = touches.first?.location(in: self) ?? touchStartCenter
            if touchMode == .trackpad {
                mapper.sendPointerUpAtCurrent(button: dragButton ?? .left)
            } else {
                mapper.sendPointerUp(localPoint: loc, button: dragButton ?? .left)
            }
            clearDragState()
            resetGestureState()
            return
        }

        let endPoint = touches.first?.location(in: self) ?? touchStartCenter
        let elapsed = Date().timeIntervalSince(touchStartTime ?? Date())
        let isQuickTap = !didMoveBeyondTap && elapsed < longPressDuration

        if handleEdgeSwipe(to: endPoint) {
            resetGestureState()
            return
        }

        if isQuickTap, touchMode != .scrollOnly {
            switch lastTouchCount {
            case 1:
                handleOneFingerTap(at: endPoint)
            case 2:
                handleTwoFingerTap(at: touchStartCenter)
            case 3:
                if touchMode == .trackpad {
                    mapper.sendTapAtCurrent(button: .middle)
                } else {
                    mapper.sendTap(localPoint: touchStartCenter, button: .middle)
                }
            default:
                break
            }
        }

        resetGestureState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressTimer?.invalidate()
        pendingOneFingerTapTimer?.invalidate()
        pendingOneFingerTapTimer = nil
        lastOneFingerTapTime = nil
        pendingTwoFingerTapTimer?.invalidate()
        pendingTwoFingerTapTimer = nil
        previousIndirectScrollTranslation = .zero
        onViewportScaleChange?(nil)
        clearDragState()
        resetGestureState()
    }

    private func resetGestureState() {
        twoFingerResolver.reset()
        previousTrackpadPoint = nil
        lastTouchCount = 0
        touchStartTime = nil
        didMoveBeyondTap = false
        endInputInteraction()
    }

    private func clearDragState() {
        isDragging = false
        dragButton = nil
        onDragFeedbackChange?(nil)
    }

    private func beginInputInteraction() {
        guard !localInteractionStarted else { return }
        localInteractionStarted = true
        inputMapper?.beginLocalInteraction()
    }

    private func endInputInteraction() {
        guard localInteractionStarted else { return }
        localInteractionStarted = false
        inputMapper?.endLocalInteraction()
    }

    private func handleOneFingerTap(at point: CGPoint) {
        let now = Date()
        if let last = lastOneFingerTapTime, now.timeIntervalSince(last) < doubleTapInterval {
            pendingOneFingerTapTimer?.invalidate()
            pendingOneFingerTapTimer = nil
            lastOneFingerTapTime = nil
            if touchMode == .trackpad {
                inputMapper?.sendDoubleTapAtCurrent()
            } else {
                inputMapper?.sendDoubleTap(localPoint: point)
            }
            return
        }

        lastOneFingerTapTime = now
        pendingOneFingerTapTimer?.invalidate()
        pendingOneFingerTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.touchMode == .trackpad {
                    self.inputMapper?.sendTapAtCurrent(button: .left)
                } else {
                    self.inputMapper?.sendTap(localPoint: point, button: .left)
                }
                self.pendingOneFingerTapTimer = nil
            }
        }
    }

    private func handleTwoFingerTap(at point: CGPoint) {
        let now = Date()
        if let last = lastTwoFingerTapTime, now.timeIntervalSince(last) < doubleTapInterval {
            pendingTwoFingerTapTimer?.invalidate()
            pendingTwoFingerTapTimer = nil
            lastTwoFingerTapTime = nil
            onControlsToggle?()
            return
        }

        lastTwoFingerTapTime = now
        pendingTwoFingerTapTimer?.invalidate()
        pendingTwoFingerTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.touchMode == .trackpad {
                    self.inputMapper?.sendTapAtCurrent(button: .right)
                } else {
                    self.inputMapper?.sendTap(localPoint: point, button: .right)
                }
                self.pendingTwoFingerTapTimer = nil
            }
        }
    }

    private func handleEdgeSwipe(to endPoint: CGPoint) -> Bool {
        let dx = endPoint.x - touchStartCenter.x
        let dy = endPoint.y - touchStartCenter.y
        guard max(abs(dx), abs(dy)) >= edgeSwipeDistance else { return false }

        let nearTop = touchStartCenter.y <= edgeActivationInset
        let nearBottom = touchStartCenter.y >= bounds.height - edgeActivationInset
        let nearLeft = touchStartCenter.x <= edgeActivationInset
        let nearRight = touchStartCenter.x >= bounds.width - edgeActivationInset

        let target: CGPoint?
        if nearTop && dy > 0 {
            target = CGPoint(x: bounds.midX, y: 2)
        } else if nearBottom && dy < 0 {
            target = CGPoint(x: bounds.midX, y: bounds.maxY - 2)
        } else if nearLeft && dx > 0 {
            target = CGPoint(x: 2, y: bounds.midY)
        } else if nearRight && dx < 0 {
            target = CGPoint(x: bounds.maxX - 2, y: bounds.midY)
        } else if nearTop && nearLeft {
            target = CGPoint(x: 2, y: 2)
        } else if nearTop && nearRight {
            target = CGPoint(x: bounds.maxX - 2, y: 2)
        } else if nearBottom && nearLeft {
            target = CGPoint(x: 2, y: bounds.maxY - 2)
        } else if nearBottom && nearRight {
            target = CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 2)
        } else {
            target = nil
        }

        if let target {
            inputMapper?.sendPointerMove(localPoint: target)
            return true
        }
        return false
    }

    private func applyViewportGesture(_ update: TrackpadTwoFingerGestureResolver.ViewportPinchUpdate) {
        let geometry = CanvasGeometry(
            canvasSize: canvasSize,
            remotePixelSize: remotePixelSize,
            fit: fit,
            viewport: viewport
        )

        var nextViewport = viewport
        if update.previousDistance > 0 {
            let magnification = update.distance / update.previousDistance
            nextViewport = nextViewport.applyingMagnification(magnification, around: update.center, in: geometry)
        }
        let delta = CGSize(
            width: update.center.x - update.previousCenter.x,
            height: update.center.y - update.previousCenter.y
        )
        nextViewport = nextViewport.translated(by: delta, in: geometry)

        if nextViewport != viewport {
            setLocalViewport(nextViewport)
        }
    }

    @available(iOS 13.4, *)
    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard touchMode != .scrollOnly, let inputMapper else { return }
        let loc = recognizer.location(in: self)
        let pointer = inputMapper.sendPointerMove(localPoint: loc)
        if touchMode == .trackpad {
            followViewportIfNeeded(pointer: pointer)
        }
    }

    @available(iOS 13.4, *)
    private func configureIndirectPointerGestures() {
        let primaryClick = indirectPointerTapGesture(buttonMask: .primary, action: #selector(handleIndirectPrimaryClick(_:)))
        let secondaryClick = indirectPointerTapGesture(buttonMask: .secondary, action: #selector(handleIndirectSecondaryClick(_:)))
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleIndirectScroll(_:)))
        scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.allowedScrollTypesMask = [.continuous, .discrete]
        addGestureRecognizer(primaryClick)
        addGestureRecognizer(secondaryClick)
        addGestureRecognizer(scroll)
    }

    @available(iOS 13.4, *)
    private func indirectPointerTapGesture(buttonMask: UIEvent.ButtonMask, action: Selector) -> UITapGestureRecognizer {
        let tap = UITapGestureRecognizer(target: self, action: action)
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        tap.buttonMaskRequired = buttonMask
        return tap
    }

    @available(iOS 13.4, *)
    @objc private func handleIndirectPrimaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, touchMode != .scrollOnly else { return }
        inputMapper?.sendTap(localPoint: recognizer.location(in: self), button: .left)
    }

    @available(iOS 13.4, *)
    @objc private func handleIndirectSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, touchMode != .scrollOnly else { return }
        inputMapper?.sendTap(localPoint: recognizer.location(in: self), button: .right)
    }

    @available(iOS 13.4, *)
    @objc private func handleIndirectScroll(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began:
            previousIndirectScrollTranslation = translation
        case .changed:
            let dx = Double(translation.x - previousIndirectScrollTranslation.x) * 3.0
            let dy = Double(translation.y - previousIndirectScrollTranslation.y) * 3.0
            if dx != 0 || dy != 0 {
                if touchMode == .trackpad {
                    inputMapper?.sendScrollAtCurrent(deltaX: dx, deltaY: dy)
                } else {
                    inputMapper?.sendScroll(deltaX: dx, deltaY: dy, localPoint: recognizer.location(in: self))
                }
            }
            previousIndirectScrollTranslation = translation
        default:
            previousIndirectScrollTranslation = .zero
        }
    }

    private func averageLocation(_ touches: Set<UITouch>) -> CGPoint {
        var x: CGFloat = 0
        var y: CGFloat = 0
        for t in touches {
            let loc = t.location(in: self)
            x += loc.x
            y += loc.y
        }
        let n = CGFloat(max(1, touches.count))
        return CGPoint(x: x / n, y: y / n)
    }

    private func distanceBetweenTouches(_ touches: Set<UITouch>) -> CGFloat {
        let points = touches.map { $0.location(in: self) }
        guard points.count >= 2 else { return 0 }
        return hypot(points[0].x - points[1].x, points[0].y - points[1].y)
    }

    private var currentGeometry: CanvasGeometry {
        CanvasGeometry(
            canvasSize: canvasSize,
            remotePixelSize: remotePixelSize,
            fit: fit,
            viewport: viewport,
            viewportPanInsets: viewportPanInsets
        )
    }

    private func setLocalViewport(_ nextViewport: ViewportTransform) {
        guard nextViewport != viewport else { return }
        viewport = nextViewport
        inputMapper?.canvas = currentGeometry
        onViewportChange?(nextViewport)
        onViewportScaleChange?(nextViewport.scale)
    }

    private func panViewport(by delta: CGSize) {
        guard viewport.scale > ViewportTransform.minimumScale + 0.001 else { return }
        let nextViewport = viewport.translated(by: delta, in: currentGeometry)
        setLocalViewport(nextViewport)
    }

    private func followViewportIfNeeded(pointer: NormalisedPoint?) {
        guard viewport.scale > ViewportTransform.minimumScale + 0.001,
              Date().timeIntervalSince(lastViewportFollowUpdate) >= viewportFollowInterval,
              let pointer,
              let localPoint = currentGeometry.localPoint(for: pointer),
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        let horizontalInset = min(viewportFollowInset, bounds.width * 0.35)
        let verticalInset = min(viewportFollowInset, bounds.height * 0.35)
        var delta = CGSize.zero

        if localPoint.x < horizontalInset {
            delta.width = min(viewportFollowMaxStep, horizontalInset - localPoint.x)
        } else if localPoint.x > bounds.width - horizontalInset {
            delta.width = -min(viewportFollowMaxStep, localPoint.x - (bounds.width - horizontalInset))
        }

        if localPoint.y < verticalInset {
            delta.height = min(viewportFollowMaxStep, verticalInset - localPoint.y)
        } else if localPoint.y > bounds.height - verticalInset {
            delta.height = -min(viewportFollowMaxStep, localPoint.y - (bounds.height - verticalInset))
        }

        guard abs(delta.width) > 0.5 || abs(delta.height) > 0.5 else { return }
        lastViewportFollowUpdate = Date()
        panViewport(by: delta)
    }
}
#endif

nonisolated struct TrackpadTwoFingerGestureResolver {
    enum Action: Equatable {
        case none
        case remoteScroll(delta: CGSize)
        case viewportPinch(ViewportPinchUpdate)
    }

    struct ViewportPinchUpdate: Equatable {
        var center: CGPoint
        var previousCenter: CGPoint
        var distance: CGFloat
        var previousDistance: CGFloat
    }

    private enum Lock {
        case undecided
        case remoteScroll
        case viewportPinch
    }

    private var lock: Lock = .undecided
    private var startCenter: CGPoint?
    private var previousCenter: CGPoint?
    private var startDistance: CGFloat?
    private var previousDistance: CGFloat?
    private let scrollActivationDistance: CGFloat
    private let pinchActivationDistance: CGFloat
    private let pinchActivationRatio: CGFloat
    private let pinchDominanceRatio: CGFloat

    init(
        scrollActivationDistance: CGFloat = 4,
        pinchActivationDistance: CGFloat = 8,
        pinchActivationRatio: CGFloat = 0.03,
        pinchDominanceRatio: CGFloat = 1.2
    ) {
        self.scrollActivationDistance = scrollActivationDistance
        self.pinchActivationDistance = pinchActivationDistance
        self.pinchActivationRatio = pinchActivationRatio
        self.pinchDominanceRatio = pinchDominanceRatio
    }

    mutating func begin(center: CGPoint, distance: CGFloat) {
        lock = .undecided
        startCenter = center
        previousCenter = center
        startDistance = max(distance, 1)
        previousDistance = distance
    }

    mutating func update(center: CGPoint, distance: CGFloat) -> Action {
        guard let startCenter,
              let previousCenter,
              let startDistance,
              let previousDistance else {
            begin(center: center, distance: distance)
            return .none
        }

        let delta = CGSize(width: center.x - previousCenter.x, height: center.y - previousCenter.y)
        if lock == .undecided {
            lock = resolvedLock(
                center: center,
                startCenter: startCenter,
                distance: distance,
                startDistance: startDistance
            )
        }

        let action: Action
        switch lock {
        case .undecided:
            action = .none
        case .remoteScroll:
            action = abs(delta.width) > 0.001 || abs(delta.height) > 0.001
                ? .remoteScroll(delta: delta)
                : .none
        case .viewportPinch:
            action = .viewportPinch(ViewportPinchUpdate(
                center: center,
                previousCenter: previousCenter,
                distance: distance,
                previousDistance: previousDistance
            ))
        }

        self.previousCenter = center
        self.previousDistance = distance
        return action
    }

    mutating func reset() {
        lock = .undecided
        startCenter = nil
        previousCenter = nil
        startDistance = nil
        previousDistance = nil
    }

    private func resolvedLock(
        center: CGPoint,
        startCenter: CGPoint,
        distance: CGFloat,
        startDistance: CGFloat
    ) -> Lock {
        let translation = hypot(center.x - startCenter.x, center.y - startCenter.y)
        let distanceChange = abs(distance - startDistance)
        let ratioChange = abs(distance / max(startDistance, 1) - 1)
        let pinchThresholdPassed = distanceChange >= pinchActivationDistance || ratioChange >= pinchActivationRatio
        let pinchDominatesTranslation = distanceChange >= max(
            pinchActivationDistance,
            translation * pinchDominanceRatio
        )

        if pinchThresholdPassed && pinchDominatesTranslation {
            return .viewportPinch
        }
        if translation >= scrollActivationDistance {
            return .remoteScroll
        }
        return .undecided
    }
}
