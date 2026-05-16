//
//  SystemReportView.swift
//  Screen Q
//
//  Displays a comprehensive system report from the remote host, similar
//  to ARD's system info panel. Shows hardware, software, disk, network,
//  and installed applications.
//

import SwiftUI
import Combine

@MainActor
final class SystemReportState: ObservableObject {
    @Published var report: SystemReportMessage?
    @Published var isLoading: Bool = false

    var requestReport: (() -> Void)?

    func refresh() {
        isLoading = true
        requestReport?()
    }

    func handleReport(_ report: SystemReportMessage) {
        self.report = report
        self.isLoading = false
    }
}

struct SystemReportView: View {

    @ObservedObject var state: SystemReportState

    var body: some View {
        Group {
            if let report = state.report {
                reportContent(report)
            } else if state.isLoading {
                ZStack {
                    ScreenQTheme.heroBackground.ignoresSafeArea()
                    VStack(spacing: 12) {
                        ScreenQActivityTrail(tint: ScreenQTheme.cosmicCyan)
                        Text("Collecting system information…")
                            .font(.sqHeadline)
                            .foregroundColor(.primary)
                        Text("This may take a moment for very large machines.")
                            .font(.sqCallout)
                            .foregroundColor(.secondary)
                    }
                    .padding(28)
                    .screenQGlass()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    ScreenQTheme.heroBackground.ignoresSafeArea()
                    SQEmptyState(
                        icon: "doc.text.magnifyingglass",
                        title: "No report loaded",
                        message: "Fetch a comprehensive snapshot of hardware, software, disk, and network for this host.",
                        tint: ScreenQTheme.cosmicViolet,
                        primary: .init("Request Report", systemImage: "arrow.clockwise") {
                            SQHaptics.tap()
                            state.refresh()
                        }
                    )
                    .screenQCard(tint: ScreenQTheme.cosmicViolet)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 560)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func reportContent(_ r: SystemReportMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                HStack(alignment: .center, spacing: 12) {
                    ScreenQBrandMark(size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.hostname)
                            .font(.sqTitle)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("System Report")
                            .font(.sqCallout)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        SQHaptics.tap()
                        state.refresh()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .accessibilityHidden(true)
                            Text("Refresh")
                        }
                        .font(.sqHeadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(ScreenQTheme.accent(ScreenQTheme.cosmicCyan)))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isLoading)
                    .accessibilityLabel("Refresh report")
                }

                infoSection("System", icon: "desktopcomputer", tint: ScreenQTheme.cosmicCyan) {
                    row("Hostname", r.hostname)
                    row("macOS", "\(r.macOSVersion) (\(r.buildNumber))")
                    row("Model", r.hardwareModel)
                    if let serial = r.serialNumber {
                        row("Serial", serial)
                    }
                    row("Uptime", formatUptime(r.uptimeSeconds))
                }

                infoSection("Hardware", icon: "cpu", tint: ScreenQTheme.cosmicViolet) {
                    row("CPU", r.cpuType)
                    row("Cores", "\(r.cpuCoreCount)")
                    row("Memory", String(format: "%.1f GB", r.memoryGB))
                }

                infoSection("Storage", icon: "internaldrive", tint: ScreenQTheme.cosmicTeal) {
                    row("Total", String(format: "%.1f GB", r.diskTotalGB))
                    row("Free", String(format: "%.1f GB", r.diskFreeGB))
                    row("Used", String(format: "%.1f GB", r.diskTotalGB - r.diskFreeGB))

                    let usedFrac = (r.diskTotalGB - r.diskFreeGB) / max(1, r.diskTotalGB)
                    diskUsageBar(fraction: usedFrac)

                    HStack(spacing: 6) {
                        SQPill(
                            text: String(format: "%.0f%% used", usedFrac * 100),
                            status: diskUsageStatus(used: r.diskTotalGB - r.diskFreeGB, total: r.diskTotalGB)
                        )
                        Spacer()
                    }
                }

                infoSection("Network", icon: "network", tint: ScreenQTheme.cosmicMint) {
                    if r.ipAddresses.isEmpty {
                        SQEmptyState(
                            icon: "wifi.slash",
                            title: "No interfaces reported",
                            message: "The host did not report any IPv4 / IPv6 addresses.",
                            tint: ScreenQTheme.cosmicMint,
                            compact: true
                        )
                    } else {
                        ForEach(r.ipAddresses, id: \.self) { addr in
                            Text(addr)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                    }
                }

                infoSection(
                    "Applications (\(r.installedApps.count))",
                    icon: "app.badge",
                    tint: ScreenQTheme.cosmicAmber
                ) {
                    if r.installedApps.isEmpty {
                        SQEmptyState(
                            icon: "app.dashed",
                            title: "No applications reported",
                            message: "The host returned an empty application list.",
                            tint: ScreenQTheme.cosmicAmber,
                            compact: true
                        )
                    } else {
                        ForEach(Array(r.installedApps.enumerated()), id: \.offset) { _, app in
                            HStack {
                                Text(app.name).font(.sqBody)
                                Spacer()
                                if let v = app.version {
                                    Text(v).font(.sqCaption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private func infoSection<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                Spacer()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenQCard(tint: tint)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.sqCallout)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.sqBody)
                .foregroundColor(.primary)
            Spacer()
        }
    }

    private func diskUsageBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        ScreenQTheme.accent(
                            barColor(fraction: fraction)
                        )
                    )
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, fraction))))
            }
        }
        .frame(height: 8)
        .padding(.vertical, 2)
    }

    private func barColor(fraction: Double) -> Color {
        if fraction > 0.9 { return ScreenQTheme.cosmicRose }
        if fraction > 0.75 { return ScreenQTheme.cosmicAmber }
        return ScreenQTheme.cosmicMint
    }

    private func diskUsageStatus(used: Double, total: Double) -> SQStatus {
        let pct = used / max(1, total)
        if pct > 0.9 { return .error }
        if pct > 0.75 { return .attention }
        return .healthy
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        return "\(hours)h \(mins)m"
    }
}
