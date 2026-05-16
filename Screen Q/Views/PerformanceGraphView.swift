//
//  PerformanceGraphView.swift
//  Screen Q
//
//  A compact real-time sparkline view that visualises bandwidth, frame rate,
//  frame delay, and round-trip latency. Shown in the viewer's stats overlay.
//

import SwiftUI
import Combine

@MainActor
final class PerformanceHistory: ObservableObject {
    struct Sample: Identifiable {
        let id = UUID()
        let timestamp: Date
        let fps: Double
        let bandwidthBps: Double
        let frameDelayMs: Double
        let rttMs: Double
    }

    @Published private(set) var samples: [Sample] = []
    private let maxSamples = 120  // ~2 min at 1/sec

    func record(stats: TransportStats) {
        let sample = Sample(
            timestamp: Date(),
            fps: stats.fps,
            bandwidthBps: stats.bytesPerSecond,
            frameDelayMs: stats.frameLatencyMillis,
            rttMs: stats.roundTripMillis
        )
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}

struct PerformanceGraphView: View {

    @ObservedObject var history: PerformanceHistory
    @State private var selectedMetric: Metric = .bandwidth

    enum Metric: String, CaseIterable {
        case bandwidth = "Bandwidth"
        case fps = "FPS"
        case delay = "Delay"
        case rtt = "RTT"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(Metric.allCases, id: \.rawValue) { metric in
                    Button {
                        SQHaptics.tap()
                        selectedMetric = metric
                    } label: {
                        SQPill(
                            text: metric.rawValue,
                            status: pillStatus(for: metric),
                            compact: true
                        )
                        .opacity(selectedMetric == metric ? 1.0 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(metric.rawValue) metric")
                }
                Spacer()
                if let last = history.samples.last {
                    Text(currentLabel(last))
                        .font(.sqCaption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if history.samples.count < 2 {
                placeholderTrack
            } else {
                sparkline
                    .frame(height: 36)
            }

            HStack {
                Text("now")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(history.samples.count) samples")
                    .font(.sqCaption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .screenQCard(tint: ScreenQTheme.cosmicCyan, padding: 10)
        .accessibilityLabel("Performance graph showing \(selectedMetric.rawValue)")
    }

    private var placeholderTrack: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ScreenQTheme.cosmicCyan)
            Text("Collecting samples…")
                .font(.sqCaption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ScreenQTheme.cosmicCyan.opacity(0.08))
        )
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var sparkline: some View {
        let values = history.samples.map { value(for: $0) }
        let maxVal = max(1, values.max() ?? 1)

        GeometryReader { geo in
            ZStack {
                // Fill under line
                Path { path in
                    guard values.count > 1 else { return }
                    let step = geo.size.width / CGFloat(max(1, values.count - 1))
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    for (i, val) in values.enumerated() {
                        let x = CGFloat(i) * step
                        let y = geo.size.height * (1 - CGFloat(val / maxVal))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [lineColor.opacity(0.35), lineColor.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard values.count > 1 else { return }
                    let step = geo.size.width / CGFloat(max(1, values.count - 1))
                    for (i, val) in values.enumerated() {
                        let x = CGFloat(i) * step
                        let y = geo.size.height * (1 - CGFloat(val / maxVal))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(lineColor, lineWidth: 1.6)
            }
        }
    }

    private func value(for sample: PerformanceHistory.Sample) -> Double {
        switch selectedMetric {
        case .bandwidth: return sample.bandwidthBps
        case .fps: return sample.fps
        case .delay: return sample.frameDelayMs
        case .rtt: return sample.rttMs
        }
    }

    private func currentLabel(_ sample: PerformanceHistory.Sample) -> String {
        switch selectedMetric {
        case .bandwidth: return ByteFormatting.bitsPerSecond(sample.bandwidthBps)
        case .fps: return String(format: "%.0f fps", sample.fps)
        case .delay: return String(format: "%.0f ms", sample.frameDelayMs)
        case .rtt: return String(format: "%.0f ms", sample.rttMs)
        }
    }

    private var lineColor: Color {
        switch selectedMetric {
        case .bandwidth: return ScreenQTheme.cosmicCyan
        case .fps: return ScreenQTheme.cosmicMint
        case .delay: return ScreenQTheme.cosmicAmber
        case .rtt: return ScreenQTheme.cosmicAmber
        }
    }

    private func pillStatus(for metric: Metric) -> SQStatus {
        switch metric {
        case .bandwidth: return .info
        case .fps:       return .healthy
        case .delay:     return .attention
        case .rtt:       return .attention
        }
    }
}
