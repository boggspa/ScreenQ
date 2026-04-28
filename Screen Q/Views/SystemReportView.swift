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
                ProgressView("Collecting system information…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No report loaded")
                        .foregroundColor(.secondary)
                    Button("Request Report") { state.refresh() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func reportContent(_ r: SystemReportMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoSection("System", icon: "desktopcomputer") {
                    row("Hostname", r.hostname)
                    row("macOS", "\(r.macOSVersion) (\(r.buildNumber))")
                    row("Model", r.hardwareModel)
                    if let serial = r.serialNumber {
                        row("Serial", serial)
                    }
                    row("Uptime", formatUptime(r.uptimeSeconds))
                }

                infoSection("Hardware", icon: "cpu") {
                    row("CPU", r.cpuType)
                    row("Cores", "\(r.cpuCoreCount)")
                    row("Memory", String(format: "%.1f GB", r.memoryGB))
                }

                infoSection("Storage", icon: "internaldrive") {
                    row("Total", String(format: "%.1f GB", r.diskTotalGB))
                    row("Free", String(format: "%.1f GB", r.diskFreeGB))
                    row("Used", String(format: "%.1f GB", r.diskTotalGB - r.diskFreeGB))
                    ProgressView(value: (r.diskTotalGB - r.diskFreeGB) / max(1, r.diskTotalGB))
                        .accentColor(diskUsageColor(used: r.diskTotalGB - r.diskFreeGB, total: r.diskTotalGB))
                }

                infoSection("Network", icon: "network") {
                    ForEach(r.ipAddresses, id: \.self) { addr in
                        Text(addr)
                            .font(.system(.body, design: .monospaced))

                    }
                }

                infoSection("Applications (\(r.installedApps.count))", icon: "app.badge") {
                    ForEach(Array(r.installedApps.enumerated()), id: \.offset) { _, app in
                        HStack {
                            Text(app.name).font(.body)
                            Spacer()
                            if let v = app.version {
                                Text(v).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Refresh") { state.refresh() }
                        .disabled(state.isLoading)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func infoSection(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary).frame(width: 80, alignment: .leading)
            Text(value)
            Spacer()
        }
        .font(.body)
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        return "\(hours)h \(mins)m"
    }

    private func diskUsageColor(used: Double, total: Double) -> Color {
        let pct = used / max(1, total)
        if pct > 0.9 { return .red }
        if pct > 0.75 { return .orange }
        return .green
    }
}
