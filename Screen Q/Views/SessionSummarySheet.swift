//
//  SessionSummarySheet.swift
//  Screen Q
//
//  Cinematic end-of-session recap. Shown when a viewer session naturally
//  ends or the user taps Disconnect — surfaces duration + transfer stats
//  and lets the user save the connection (when unsaved) or reconnect in
//  a single tap. Mirrors the cinematic backdrop used by the connect /
//  handshake screens so the visual language stays consistent.
//

import SwiftUI

struct SessionSummarySheet: View {

    struct Stats: Equatable, Identifiable {
        let id = UUID()
        let duration: TimeInterval
        let bytesIn: UInt64
        let bytesOut: UInt64
        let averageRTT: Double?     // milliseconds
        let peakFPS: Double?
        let protocolName: String
        let hostDisplayName: String
    }

    let stats: Stats
    let isAlreadySaved: Bool
    let onConnectAgain: () -> Void
    let onSaveToFavorites: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            ScreenQTheme.cinematicBackdrop
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    ScreenQTheme.cosmicCyan.opacity(0.20),
                    Color.clear
                ],
                center: .center,
                startRadius: 8,
                endRadius: 320
            )
            .ignoresSafeArea()

            card
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(maxWidth: 560)
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 16) {
            header
            subtitle
            statsGrid
            actionRow
        }
        .padding(22)
        .screenQGlass(cornerRadius: 22)
        .overlay(doneButton, alignment: .topTrailing)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ScreenQBrandMark(size: 56)
            Text("Session ended")
                .font(.sqTitle)
                .foregroundColor(.white)
        }
    }

    private var subtitle: some View {
        HStack(spacing: 8) {
            Text(stats.hostDisplayName)
                .font(.sqHeadline)
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
            SQPill(text: stats.protocolName, status: .info, compact: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Stats grid

    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            statCell(
                value: stats.duration.sqDurationString,
                label: "Duration",
                systemImage: "clock.fill"
            )
            statCell(
                value: stats.bytesIn.sqByteString,
                label: "Received",
                systemImage: "arrow.down.circle.fill"
            )
            statCell(
                value: stats.bytesOut.sqByteString,
                label: "Sent",
                systemImage: "arrow.up.circle.fill"
            )
            statCell(
                value: rttString,
                label: "Avg RTT",
                systemImage: "timer"
            )
            statCell(
                value: peakFPSString,
                label: "Peak FPS",
                systemImage: "speedometer"
            )
        }
    }

    private func statCell(value: String, label: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.60))
                    .accessibilityHidden(true)
                Text(label)
                    .font(.sqCaption)
                    .foregroundColor(.white.opacity(0.60))
            }
            Text(value)
                .font(.sqHeadline.monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var rttString: String {
        guard let rtt = stats.averageRTT, rtt > 0 else { return "—" }
        return String(format: "%.0f ms", rtt)
    }

    private var peakFPSString: String {
        guard let fps = stats.peakFPS, fps > 0 else { return "—" }
        return String(format: "%.0f fps", fps)
    }

    // MARK: - Action row

    private var actionRow: some View {
        VStack(spacing: 10) {
            primaryButton
            if showsSaveButton, let onSaveToFavorites {
                secondaryButton(onSaveToFavorites)
            }
        }
        .padding(.top, 4)
    }

    private var showsSaveButton: Bool {
        !isAlreadySaved && onSaveToFavorites != nil
    }

    private var primaryButton: some View {
        Button {
            SQHaptics.tap()
            onConnectAgain()
            onDismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .accessibilityHidden(true)
                Text("Connect again")
            }
            .font(.sqHeadline)
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(ScreenQTheme.cosmicCyan)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connect again")
    }

    private func secondaryButton(_ action: @escaping () -> Void) -> some View {
        Button {
            SQHaptics.bump()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .accessibilityHidden(true)
                Text("Save to favorites")
            }
            .font(.sqHeadline)
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save to favorites")
    }

    private var doneButton: some View {
        Button {
            SQHaptics.tap()
            onDismiss()
        } label: {
            Text("Done")
                .font(.sqCallout.weight(.semibold))
                .foregroundColor(.white.opacity(0.78))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Done")
    }
}

// MARK: - Formatting helpers

private extension TimeInterval {
    /// Formatted as "01:42" for under-an-hour sessions and "1h 12m 03s"
    /// once a session crosses the hour mark. Always returns "00:00" for
    /// zero / negative values rather than a confusing "-1s".
    var sqDurationString: String {
        guard self.isFinite, self > 0 else { return "00:00" }
        let total = Int(self.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

private extension UInt64 {
    /// Human-readable byte string ("12.3 MB"). Wraps `ByteCountFormatter`
    /// so we stay consistent with the rest of the diagnostics surface.
    var sqByteString: String {
        let clamped = Swift.min(self, UInt64(Int64.max))
        return ByteCountFormatter().string(fromByteCount: Int64(clamped))
    }
}

#if DEBUG
#Preview("Session ended — unsaved") {
    SessionSummarySheet(
        stats: SessionSummarySheet.Stats(
            duration: 124,
            bytesIn: 18_452_103,
            bytesOut: 1_204_223,
            averageRTT: 42,
            peakFPS: 58,
            protocolName: "Screen Q",
            hostDisplayName: "Studio Mac"
        ),
        isAlreadySaved: false,
        onConnectAgain: {},
        onSaveToFavorites: {},
        onDismiss: {}
    )
}

#Preview("Session ended — saved") {
    SessionSummarySheet(
        stats: SessionSummarySheet.Stats(
            duration: 4_392,
            bytesIn: 1_482_452_103,
            bytesOut: 4_204_223,
            averageRTT: nil,
            peakFPS: nil,
            protocolName: "VNC",
            hostDisplayName: "remote-build-mac.local"
        ),
        isAlreadySaved: true,
        onConnectAgain: {},
        onSaveToFavorites: nil,
        onDismiss: {}
    )
}
#endif
