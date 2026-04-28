//
//  RemoteTerminalView.swift
//  Screen Q
//
//  A terminal-like view for executing shell commands on the remote host
//  and viewing stdout/stderr output in real time. Requires .remoteCommand
//  permission.
//

import SwiftUI
import Combine

@MainActor
final class RemoteTerminalState: ObservableObject {

    struct OutputLine: Identifiable {
        let id = UUID()
        let stream: CommandOutputMessage.OutputStream
        let text: String
        let timestamp: Date = Date()
    }

    struct CommandRecord: Identifiable {
        let id: UUID  // commandID
        let command: String
        var lines: [OutputLine] = []
        var isComplete: Bool = false
        var exitCode: Int32?
    }

    @Published var history: [CommandRecord] = []
    @Published var currentInput: String = ""
    @Published var isRunning: Bool = false

    var sendCommand: ((RemoteCommandMessage) -> Void)?

    func submit() {
        let input = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let cmdID = UUID()
        let msg = RemoteCommandMessage(
            commandID: cmdID,
            command: "/bin/bash",
            arguments: ["-c", input],
            workingDirectory: nil,
            environment: nil,
            timeout: 300  // 5 min default
        )

        history.append(CommandRecord(id: cmdID, command: input))
        isRunning = true
        currentInput = ""
        sendCommand?(msg)
    }

    func handleOutput(_ output: CommandOutputMessage) {
        guard let idx = history.firstIndex(where: { $0.id == output.commandID }) else { return }

        if !output.base64Data.isEmpty,
           let data = Data(base64Encoded: output.base64Data),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            let line = OutputLine(stream: output.stream, text: text)
            history[idx].lines.append(line)
        }

        if output.isComplete {
            history[idx].isComplete = true
            history[idx].exitCode = output.exitCode
            isRunning = false
        }
    }
}

struct RemoteTerminalView: View {

    @ObservedObject var state: RemoteTerminalState
    @State private var inputFocused: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.history) { record in
                            commandBlock(record)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: state.history.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .background(Color.black)

            Divider()

            HStack(spacing: 8) {
                Text("$")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.green)
                TextField("Enter command…", text: $state.currentInput, onCommit: { state.submit() })
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .disabled(state.isRunning)

                if state.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Run") { state.submit() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state.currentInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            #if os(macOS)
            .background(Color(NSColor.windowBackgroundColor))
            #else
            .background(Color(.systemBackground))
            #endif
        }
        .onAppear { inputFocused = true }
    }

    @ViewBuilder
    private func commandBlock(_ record: RemoteTerminalState.CommandRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("$")
                    .foregroundColor(.green)
                Text(record.command)
                    .foregroundColor(.white)
                Spacer()
                if record.isComplete {
                    let code = record.exitCode ?? 0
                    Text("exit \(code)")
                        .foregroundColor(code == 0 ? .green : .red)
                        .font(.system(.caption2, design: .monospaced))
                }
            }
            .font(.system(.body, design: .monospaced))

            ForEach(record.lines) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(line.stream == .stderr ? .red : .white.opacity(0.85))

            }
        }
        .padding(.bottom, 6)
    }
}
