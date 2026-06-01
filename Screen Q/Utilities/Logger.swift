//
//  Logger.swift
//  Screen Q
//
//  Thin wrapper around os.Logger. We never log pairing codes, encryption
//  keys or video payloads. If you need to add a log call that touches
//  authentication material, redact aggressively.
//

import Foundation
import os

nonisolated final class Logger: @unchecked Sendable {

    static let shared = Logger()

    private let osLog = os.Logger(subsystem: BundleIdentity.identifier, category: "ScreenQ")

    func info(_ message: String, file: String = #fileID, line: Int = #line) {
        osLog.info("\(self.prefix(file, line)): \(message)")
    }

    func debug(_ message: String, file: String = #fileID, line: Int = #line) {
        osLog.debug("\(self.prefix(file, line)): \(message)")
    }

    func warn(_ message: String, file: String = #fileID, line: Int = #line) {
        osLog.warning("\(self.prefix(file, line)): \(message)")
    }

    func error(_ message: String, file: String = #fileID, line: Int = #line) {
        osLog.error("\(self.prefix(file, line)): \(message)")
    }

    private func prefix(_ file: String, _ line: Int) -> String {
        let component = file.split(separator: "/").last ?? Substring(file)
        return "\(component):\(line)"
    }
}
