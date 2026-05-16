//
//  SQStatsHUD.swift
//  Screen Q  ·  Theme / In-Session
//
//  Floating performance HUD. Replaces ad-hoc "stats labels" in viewer
//  status bars with a single draggable chip the user can collapse or
//  position anywhere on the canvas.
//
//  - Compact: shows whichever of fps / kbps / rttMs are non-nil, plus a
//    chevron to collapse.
//  - Collapsed: shrinks to just FPS (or a chevron icon if FPS is nil).
//  - Draggable: a long-press starts a drag and updates `anchor`. Callers
//    persist `anchor` in `ViewerControlPreferences`.
//
//  Monospaced digits stop the chip from juddering as numbers tick.
//
//  Deployment targets: macOS 11.5+, iOS 17+. No `.tint`, `.indigo`,
//  `.teal`, `.ultraThinMaterial`.
//

import SwiftUI

struct SQStatsHUD: View {

    struct Stats: Equatable {
        var fps: Double?
        var kbps: Double?
        var rttMs: Double?
        var bytesIn: UInt64?
        var bytesOut: UInt64?

        init(fps: Double? = nil,
             kbps: Double? = nil,
             rttMs: Double? = nil,
             bytesIn: UInt64? = nil,
             bytesOut: UInt64? = nil) {
            self.fps = fps
            self.kbps = kbps
            self.rttMs = rttMs
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
        }
    }

    let stats: Stats
    @Binding var isCollapsed: Bool
    @Binding var anchor: CGPoint

    /// When true the HUD is draggable via long-press → drag. Set false
    /// for cases where the parent provides its own positioning.
    var allowsDrag: Bool = true

    @State private var dragStart: CGPoint?

    var body: some View {
        Group {
            if isCollapsed {
                collapsedChip
            } else {
                expandedChip
            }
        }
        .screenQGlass(cornerRadius: ScreenQTheme.pillCornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double-tap to \(isCollapsed ? "expand" : "collapse"). Drag to move.")
        .gesture(allowsDrag ? dragGesture : nil)
        .onTapGesture {
            SQHaptics.tap()
            withAnimation(.easeInOut(duration: 0.18)) {
                isCollapsed.toggle()
            }
        }
        .offset(x: anchor.x, y: anchor.y)
    }

    private var expandedChip: some View {
        HStack(spacing: 8) {
            if let fps = stats.fps {
                statLabel(systemImage: "speedometer", value: String(format: "%.0f", fps), unit: "fps")
            }
            if let kbps = stats.kbps {
                statLabel(systemImage: "arrow.down.circle", value: kbpsValue(kbps), unit: "kbps")
            }
            if let rtt = stats.rttMs {
                statLabel(systemImage: "timer", value: String(format: "%.0f", rtt), unit: "ms")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var collapsedChip: some View {
        HStack(spacing: 4) {
            if let fps = stats.fps {
                Text(String(format: "%.0f", fps))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigitIfAvailable()
                    .foregroundColor(.white)
                Text("fps")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            } else {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func statLabel(systemImage: String, value: String, unit: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigitIfAvailable()
                .foregroundColor(.white)
            Text(unit)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private func kbpsValue(_ kbps: Double) -> String {
        if kbps >= 1000 {
            return String(format: "%.1fM", kbps / 1000)
        }
        return String(format: "%.0f", kbps)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = anchor
                }
                let start = dragStart ?? .zero
                anchor = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
            }
            .onEnded { _ in
                dragStart = nil
                SQHaptics.tap()
            }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let fps = stats.fps { parts.append("\(Int(fps)) frames per second") }
        if let kbps = stats.kbps { parts.append("\(Int(kbps)) kbps") }
        if let rtt = stats.rttMs { parts.append("\(Int(rtt)) milliseconds RTT") }
        if parts.isEmpty { return "Stats HUD" }
        return parts.joined(separator: ", ")
    }
}

// MARK: - macOS 12+ guard for monospacedDigit()

private extension Text {
    func monospacedDigitIfAvailable() -> Text {
        if #available(macOS 12.0, iOS 15.0, *) {
            return self.monospacedDigit()
        }
        return self
    }
}

#Preview("SQStatsHUD") {
    VStack(spacing: 30) {
        SQStatsHUD(
            stats: .init(fps: 58, kbps: 1820, rttMs: 22),
            isCollapsed: .constant(false),
            anchor: .constant(.zero)
        )
        SQStatsHUD(
            stats: .init(fps: 58, kbps: 1820, rttMs: 22),
            isCollapsed: .constant(true),
            anchor: .constant(.zero)
        )
    }
    .padding(40)
    .background(Color.black)
}
