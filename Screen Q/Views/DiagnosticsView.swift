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

struct DiagnosticsView: View {

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    @State private var results: [SelfTests.Result] = []
    @State private var lastRun: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Self-tests")
                        .font(.title2).bold()
                    Spacer()
                    Button("Run") { runTests() }
                        .buttonStyle(.bordered)
                }
                if let lastRun {
                    Text("Last run: \(Self.timeFormatter.string(from: lastRun))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if results.isEmpty {
                    Text("No tests have been run yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(results) { r in
                        HStack(alignment: .top) {
                            Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundColor(r.passed ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.headline)
                                if let detail = r.detail {
                                    Text(detail).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Diagnostics")
    }

    private func runTests() {
        results = SelfTests.runAll()
        lastRun = Date()
    }
}
