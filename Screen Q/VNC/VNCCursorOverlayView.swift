//
//  VNCCursorOverlayView.swift
//  Screen Q
//
//  Renders a visible cursor indicator on the iOS VNC viewer canvas.
//  Tracks the last pointer position sent to the server and shows a
//  small arrow cursor at the corresponding screen-space coordinates.
//  Auto-hides after 3 seconds of inactivity.
//

#if os(iOS)
import SwiftUI

struct VNCCursorOverlayView: View {
    @ObservedObject var session: VNCSession
    let serverSize: CGSize
    let displayScale: CGFloat

    var body: some View {
        if session.cursorVisible, serverSize.width > 0, serverSize.height > 0 {
            cursorImage
                .position(cursorPosition)
                .allowsHitTesting(false)
                .animation(.linear(duration: 0.016), value: session.cursorViewX)
                .animation(.linear(duration: 0.016), value: session.cursorViewY)
                .transition(.opacity)
        }
    }

    private var cursorPosition: CGPoint {
        CGPoint(
            x: CGFloat(session.cursorViewX) * displayScale,
            y: CGFloat(session.cursorViewY) * displayScale
        )
    }

    @ViewBuilder
    private var cursorImage: some View {
        if let cgImage = session.cursorImage {
            // Server-provided cursor shape. Offset by hotspot.
            let hotspot = session.cursorHotspot
            Image(decorative: cgImage, scale: 1.0)
                .interpolation(.none)
                .offset(
                    x: CGFloat(cgImage.width) / 2 - hotspot.x,
                    y: CGFloat(cgImage.height) / 2 - hotspot.y
                )
        } else {
            // Fallback generic cursor.
            ZStack {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black.opacity(0.45))
                    .offset(x: 0.5, y: 0.5)

                Image(systemName: "cursorarrow")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }
            .offset(x: 3, y: 3)
        }
    }
}
#endif
