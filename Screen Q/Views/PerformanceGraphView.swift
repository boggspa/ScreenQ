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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ForEach(Metric.allCases, id: \.rawValue) { metric in
                    Button(metric.rawValue) {
                        selectedMetric = metric
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(selectedMetric == metric ? .bold : .regular))
                    .foregroundColor(selectedMetric == metric ? .primary : .secondary)
                }
                Spacer()
                if let last = history.samples.last {
                    Text(currentLabel(last))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            sparkline
                .frame(height: 32)
        }
        .padding(8)
        .background(Color.black.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var sparkline: some View {
        let values = history.samples.map { value(for: $0) }
        let maxVal = max(1, values.max() ?? 1)

        GeometryReader { geo in
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
            .stroke(lineColor, lineWidth: 1.5)
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
        case .bandwidth: return .blue
        case .fps: return .green
        case .delay: return .orange
        case .rtt: return .orange
        }
    }
}
