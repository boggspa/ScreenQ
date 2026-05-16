//
//  DiagnosticsView.swift
//  Screen Q
//
//  Visible diagnostic surface. Runs the deterministic self-tests bundled in
//  Tests/SelfTests.swift and shows results inline. Useful both as a sanity
//  check during development and as a manual verification step on devices
//  where setting up XCTest targets isn't worth it.
//

import SwiftUI

/// Thin wrapper that keeps the existing sheet / NavigationLink call sites
/// working. Embeds `DiagnosticsSettingsContent` so the same surface can be
/// reused inside the unified Settings pane.
struct DiagnosticsView: View {
    var body: some View {
        DiagnosticsSettingsContent()
            .navigationTitle("Diagnostics")
    }
}

/// The full Diagnostics surface, extracted so it can be embedded in the
/// Settings pane (`SettingsScene.Tab.diagnostics`) and in the legacy sheet
/// / NavigationLink entry point.
struct DiagnosticsSettingsContent: View {

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    @State private var results: [SelfTests.Result] = []
    @State private var lastRun: Date?
    @State private var isRunning: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                SQSectionHeader(
                    "Self-tests",
                    subtitle: subtitle,
                    action: .init("Run", systemImage: "play.circle.fill") {
                        SQHaptics.tap()
                        runTests()
                    }
                )

                if isRunning {
                    HStack(spacing: 10) {
                        ScreenQActivityTrail(tint: ScreenQTheme.cosmicCyan)
                        Text("Running self-tests…")
                            .font(.sqCallout)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .screenQCard(tint: ScreenQTheme.cosmicCyan, padding: 14)
                } else if results.isEmpty {
                    SQEmptyState(
                        icon: "waveform.path.ecg.rectangle",
                        title: "No tests have been run",
                        message: "Run the bundled self-tests to verify protocol, transport, and crypto invariants.",
                        tint: ScreenQTheme.cosmicCyan,
                        primary: .init("Run Self-Tests", systemImage: "play.fill") {
                            SQHaptics.tap()
                            runTests()
                        }
                    )
                    .screenQCard(tint: ScreenQTheme.cosmicCyan)
                } else {
                    resultsSummary

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { r in
                            DiagnosticsRow(result: r)
                                .padding(.vertical, 10)
                            if r.id != results.last?.id {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .screenQCard(
                        tint: failingCount == 0 ? ScreenQTheme.cosmicMint : ScreenQTheme.cosmicRose,
                        padding: 14
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ScreenQTheme.heroBackground.ignoresSafeArea())
    }

    private var subtitle: String? {
        guard let lastRun else { return nil }
        return "Last run: \(Self.timeFormatter.string(from: lastRun))"
    }

    private var failingCount: Int {
        results.filter { !$0.passed }.count
    }

    private var resultsSummary: some View {
        HStack(spacing: 8) {
            SQPill(
                text: "\(results.count - failingCount) passing",
                status: .healthy
            )
            if failingCount > 0 {
                SQPill(text: "\(failingCount) failing", status: .error)
            }
            Spacer()
        }
    }

    private func runTests() {
        isRunning = true
        results = SelfTests.runAll()
        lastRun = Date()
        isRunning = false
        if results.contains(where: { !$0.passed }) {
            SQHaptics.warning()
        } else {
            SQHaptics.success()
        }
    }
}

private struct DiagnosticsRow: View {
    let result: SelfTests.Result

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(result.passed ? ScreenQTheme.cosmicMint : ScreenQTheme.cosmicRose)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.sqHeadline)
                    .foregroundColor(.primary)
                if let detail = result.detail {
                    Text(detail)
                        .font(.sqCallout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
