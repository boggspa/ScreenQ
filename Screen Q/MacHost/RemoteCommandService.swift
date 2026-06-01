//
//  RemoteCommandService.swift
//  Screen Q
//
//  Executes shell commands requested by a remote viewer. Streams stdout
//  and stderr back as CommandOutputMessages. Commands are sandboxed by
//  the PermissionSet (.remoteCommand) flag.
//

#if os(macOS)
import Foundation

@MainActor
final class RemoteCommandService {

    private var runningProcesses: [UUID: Process] = [:]
    var sendOutput: ((CommandOutputMessage) -> Void)?

    func execute(_ cmd: RemoteCommandMessage) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd.command)
        process.arguments = cmd.arguments
        if let wd = cmd.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        if let env = cmd.environment {
            var current = ProcessInfo.processInfo.environment
            for (k, v) in env { current[k] = v }
            process.environment = current
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let commandID = cmd.commandID
        let sender = self.sendOutput

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let msg = CommandOutputMessage(
                commandID: commandID,
                stream: .stdout,
                base64Data: data.base64EncodedString(),
                isComplete: false,
                exitCode: nil
            )
            Task { @MainActor in sender?(msg) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let msg = CommandOutputMessage(
                commandID: commandID,
                stream: .stderr,
                base64Data: data.base64EncodedString(),
                isComplete: false,
                exitCode: nil
            )
            Task { @MainActor in sender?(msg) }
        }

        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            // Read any remaining data.
            let remainStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let remainStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let terminationStatus = proc.terminationStatus
            guard let service = self else { return }

            Task { @MainActor in
                if !remainStdout.isEmpty {
                    sender?(CommandOutputMessage(
                        commandID: commandID, stream: .stdout,
                        base64Data: remainStdout.base64EncodedString(),
                        isComplete: false, exitCode: nil
                    ))
                }
                if !remainStderr.isEmpty {
                    sender?(CommandOutputMessage(
                        commandID: commandID, stream: .stderr,
                        base64Data: remainStderr.base64EncodedString(),
                        isComplete: false, exitCode: nil
                    ))
                }
                // Send completion.
                sender?(CommandOutputMessage(
                    commandID: commandID, stream: .stdout,
                    base64Data: "",
                    isComplete: true,
                    exitCode: terminationStatus
                ))
                service.runningProcesses.removeValue(forKey: commandID)
            }
        }

        do {
            try process.run()
            runningProcesses[commandID] = process
            Logger.shared.info("RemoteCommand: started \(cmd.command) \(cmd.arguments.joined(separator: " "))")

            // Timeout support.
            if let timeout = cmd.timeout, timeout > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning {
                        process.terminate()
                        Logger.shared.warn("RemoteCommand: timed out after \(timeout)s")
                    }
                }
            }
        } catch {
            let msg = CommandOutputMessage(
                commandID: commandID, stream: .stderr,
                base64Data: Data(error.localizedDescription.utf8).base64EncodedString(),
                isComplete: true, exitCode: -1
            )
            sendOutput?(msg)
        }
    }

    func cancelAll() {
        for (_, process) in runningProcesses where process.isRunning {
            process.terminate()
        }
        runningProcesses.removeAll()
    }
}
#endif
