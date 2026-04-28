//
//  SystemActionService.swift
//  Screen Q
//
//  Executes system-level actions (restart, sleep, lock, etc.) on the host
//  Mac when requested by a remote viewer with .systemActions permission.
//

#if os(macOS)
import Foundation
import AppKit

@MainActor
final class SystemActionService {

    func perform(_ msg: SystemActionMessage) -> SystemActionResultMessage {
        let result: (success: Bool, message: String?)

        switch msg.action {
        case .restart:
            result = runAppleScript("tell application \"System Events\" to restart")
        case .shutdown:
            result = runAppleScript("tell application \"System Events\" to shut down")
        case .sleep:
            result = runAppleScript("tell application \"System Events\" to sleep")
        case .logOut:
            result = runAppleScript("tell application \"System Events\" to log out")
        case .lockScreen:
            result = runShell("/usr/bin/pmset", arguments: ["displaysleepnow"])
        case .wake:
            // Wake doesn't make sense when we're the host (we're already awake).
            result = (true, "Host is already awake")
        }

        return SystemActionResultMessage(
            actionID: msg.actionID,
            success: result.success,
            message: result.message
        )
    }

    private func runAppleScript(_ source: String) -> (Bool, String?) {
        let script = NSAppleScript(source: source)
        var errorDict: NSDictionary?
        script?.executeAndReturnError(&errorDict)
        if let error = errorDict {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            Logger.shared.error("SystemAction AppleScript failed: \(msg)")
            return (false, msg)
        }
        return (true, nil)
    }

    private func runShell(_ path: String, arguments: [String] = []) -> (Bool, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, output.isEmpty ? nil : output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
#endif
