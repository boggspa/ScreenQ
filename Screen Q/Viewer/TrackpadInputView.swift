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
    var onViewportChange: ((ViewportTransform) -> Void)?
    var onViewportScaleChange: ((CGFloat?) -> Void)?
    var onControlsToggle: (() -> Void)?
    var onDragFeedbackChange: ((IOSDragFeedback?) -> Void)?

    private var longPressTimer: Timer?
    private var pendingTwoFingerTapTimer: Timer?
    private var lastTouchCount: Int = 0
    private var previousScrollPoint: CGPoint?
    private var previousPinchCenter: CGPoint?
    private var pinchStartDistance: CGFloat?
    private var previousPinchDistance: CGFloat?
    private var isViewportGesture = false
    private var touchStartTime: Date?
    private var touchStartPoint: CGPoint = .zero
    private var touchStartCenter: CGPoint = .zero
    private var isDragging = false
    private var dragButton: PointerButton?
    private var didMoveBeyondTap = false
    private var lastTwoFingerTapTime: Date?
    private let longPressDuration: TimeInterval = 0.5
    private let tapMaxDistance: CGFloat = 10
    private let pinchActivationDistance: CGFloat = 8
    private let pinchActivationRatio: CGFloat = 0.03
    private let doubleTapInterval: TimeInterval = 0.32
    private let edgeActivationInset: CGFloat = 28
    private let edgeSwipeDistance: CGFloat = 52

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        if #available(iOS 13.4, *) {
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
        }
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let allTouches = event?.allTouches ?? touches
        lastTouchCount = allTouches.count
        didMoveBeyondTap = false
        touchStartTime = Date()
        touchStartCenter = averageLocation(allTouches)
        touchStartPoint = touches.first?.location(in: self) ?? touchStartCenter

        if allTouches.count == 1, touchMode != .scrollOnly {
            isDragging = false

            // One-finger long press begins a left-button drag.
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard !self.didMoveBeyondTap else { return }
                    self.inputMapper?.sendPointerDown(localPoint: self.touchStartPoint, button: .left)
                    self.dragButton = .left
                    self.isDragging = true
                    self.onDragFeedbackChange?(IOSDragFeedback(kind: .left, point: self.touchStartPoint))
                }
            }
        } else if allTouches.count == 2 {
            // Two-finger scroll / pinch starting point. A stationary two-finger
            // hold starts a secondary-button drag.
            let center = averageLocation(allTouches)
            previousScrollPoint = center
            previousPinchCenter = center
            let distance = distanceBetweenTouches(allTouches)
            pinchStartDistance = distance
            previousPinchDistance = distance
            isViewportGesture = false
            longPressTimer?.invalidate()
            if touchMode != .scrollOnly {
                longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.didMoveBeyondTap, !self.isViewportGesture else { return }
                        self.inputMapper?.sendPointerDown(localPoint: center, button: .right)
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

        // Cancel long-press if moved too far.
        if touchStartTime != nil, allTouches.count == 1, touchMode != .scrollOnly {
            if let touch = touches.first {
                let loc = touch.location(in: self)
                mapper.sendPointerMove(localPoint: loc)
                if isDragging {
                    onDragFeedbackChange?(IOSDragFeedback(kind: dragButton == .right ? .right : .left, point: loc))
                }
            }
        }

        if allTouches.count == 2 {
            // Keep normal trackpad scrolling intact. Only switch this
            // two-finger gesture to local viewport control once the finger
            // spacing clearly changes like a pinch.
            let center = averageLocation(allTouches)
            let distance = distanceBetweenTouches(allTouches)
            let startDistance = max(pinchStartDistance ?? distance, 1)
            let distanceChange = abs(distance - startDistance)
            let ratioChange = abs(distance / startDistance - 1)

            if isViewportGesture || distanceChange > pinchActivationDistance || ratioChange > pinchActivationRatio {
                isViewportGesture = true
                longPressTimer?.invalidate()
                applyViewportGesture(center: center, distance: distance)
            } else if isDragging {
                mapper.sendPointerMove(localPoint: center)
                onDragFeedbackChange?(IOSDragFeedback(kind: dragButton == .right ? .right : .left, point: center))
            } else if let prev = previousScrollPoint {
                let dx = Double(center.x - prev.x) * 3.0
                let dy = Double(center.y - prev.y) * 3.0
                mapper.sendScroll(deltaX: dx, deltaY: dy, localPoint: center)
            }
            previousScrollPoint = center
            previousPinchCenter = center
            previousPinchDistance = distance
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let mapper = inputMapper else { return }
        longPressTimer?.invalidate()
        onViewportScaleChange?(nil)

        if isDragging {
            let loc = touches.first?.location(in: self) ?? touchStartCenter
            mapper.sendPointerUp(localPoint: loc, button: dragButton ?? .left)
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
                mapper.sendTap(localPoint: endPoint, button: .left)
            case 2:
                handleTwoFingerTap(at: touchStartCenter)
            case 3:
                mapper.sendTap(localPoint: touchStartCenter, button: .middle)
            default:
                break
            }
        }

        resetGestureState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressTimer?.invalidate()
        pendingTwoFingerTapTimer?.invalidate()
        onViewportScaleChange?(nil)
        clearDragState()
        resetGestureState()
    }

    private func resetGestureState() {
        previousScrollPoint = nil
        previousPinchCenter = nil
        pinchStartDistance = nil
        previousPinchDistance = nil
        isViewportGesture = false
        lastTouchCount = 0
        touchStartTime = nil
        didMoveBeyondTap = false
    }

    private func clearDragState() {
        isDragging = false
        dragButton = nil
        onDragFeedbackChange?(nil)
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
                self.inputMapper?.sendTap(localPoint: point, button: .right)
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

    private func applyViewportGesture(center: CGPoint, distance: CGFloat) {
        let geometry = CanvasGeometry(
            canvasSize: canvasSize,
            remotePixelSize: remotePixelSize,
            fit: fit,
            viewport: viewport
        )

        var nextViewport = viewport
        if let previousDistance = previousPinchDistance, previousDistance > 0 {
            let magnification = distance / previousDistance
            nextViewport = nextViewport.applyingMagnification(magnification, around: center, in: geometry)
        }
        if let previousCenter = previousPinchCenter {
            let delta = CGSize(width: center.x - previousCenter.x, height: center.y - previousCenter.y)
            nextViewport = nextViewport.translated(by: delta, in: geometry)
        }

        if nextViewport != viewport {
            viewport = nextViewport
            onViewportChange?(nextViewport)
            onViewportScaleChange?(nextViewport.scale)
        }
    }

    @available(iOS 13.4, *)
    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard touchMode == .trackpad else { return }
        let loc = recognizer.location(in: self)
        inputMapper?.sendPointerMove(localPoint: loc)
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
}
#endif
