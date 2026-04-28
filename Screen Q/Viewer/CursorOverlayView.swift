//
//  CursorOverlayView.swift
//  Screen Q
//
//  Renders a cursor overlay on the viewer's screen canvas. The cursor
//  position is received via CursorUpdateMessages independently of the
//  video frame stream, so it updates at up to 120Hz — much faster than
//  the video framerate. This halves perceived pointer latency.
//

import SwiftUI
import Combine

@MainActor
final class CursorOverlayState: ObservableObject {
    @Published var x: Double = 0
    @Published var y: Double = 0
    @Published var visible: Bool = false
    @Published var cursorType: String = "arrow"
    @Published var cursorImage: CGImage?
    @Published var hotSpotX: Double = 0
    @Published var hotSpotY: Double = 0

    func update(_ msg: CursorUpdateMessage) {
        x = msg.x
        y = msg.y
        visible = msg.visible
        cursorType = msg.cursorType
        if let b64 = msg.imageData,
           let data = Data(base64Encoded: b64),
           let provider = CGDataProvider(data: data as CFData),
           let img = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            cursorImage = img
            hotSpotX = msg.hotSpotX ?? 0
            hotSpotY = msg.hotSpotY ?? 0
        }
    }
}

struct CursorOverlayView: View {
    @ObservedObject var state: CursorOverlayState
    let canvasGeometry: CanvasGeometry

    var body: some View {
        if state.visible, let position = cursorPosition {
            cursorContent
                .position(position)
                .allowsHitTesting(false)
                .animation(.linear(duration: 0.016), value: state.x)
                .animation(.linear(duration: 0.016), value: state.y)
        }
    }

    private var cursorPosition: CGPoint? {
        canvasGeometry.localPoint(for: NormalisedPoint(x: state.x, y: state.y))
    }

    @ViewBuilder
    private var cursorContent: some View {
        if let cgImage = state.cursorImage {
            Image(decorative: cgImage, scale: 2.0)
                .offset(
                    x: -state.hotSpotX,
                    y: -state.hotSpotY
                )
        } else {
            Image(systemName: cursorSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
        }
    }

    private var cursorSymbol: String {
        switch state.cursorType {
        case "iBeam":        return "character.cursor.ibeam"
        case "pointingHand": return "hand.point.up.left"
        case "crosshair":    return "plus"
        case "openHand":     return "hand.raised"
        case "closedHand":   return "hand.raised.fill"
        default:             return "cursorarrow"
        }
    }
}
