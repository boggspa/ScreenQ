//
//  ByteFormatting.swift
//  Screen Q
//

import Foundation

enum ByteFormatting {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func human(_ bytes: Int) -> String {
        formatter.string(fromByteCount: Int64(max(0, bytes)))
    }

    static func bitsPerSecond(_ bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        if bits >= 1_000_000 {
            return String(format: "%.2f Mb/s", bits / 1_000_000)
        } else if bits >= 1_000 {
            return String(format: "%.1f kb/s", bits / 1_000)
        }
        return String(format: "%.0f b/s", bits)
    }

    static func bytesPerSecond(_ bytesPerSecond: Double) -> String {
        "\(human(Int(bytesPerSecond)))/s"
    }
}
