//
//  PermissionSet.swift
//  Screen Q
//
//  Granular per-session permission flags modelled after Apple Remote Desktop's
//  privilege masks. Sent inside PairingApprovedMessage so the viewer knows
//  exactly what it is allowed to do, and the host enforces each flag.
//

import Foundation

struct PermissionSet: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let observe         = PermissionSet(rawValue: 1 << 0)
    static let control         = PermissionSet(rawValue: 1 << 1)
    static let clipboard       = PermissionSet(rawValue: 1 << 2)
    static let fileTransfer    = PermissionSet(rawValue: 1 << 3)
    static let remoteCommand   = PermissionSet(rawValue: 1 << 4)
    static let systemActions   = PermissionSet(rawValue: 1 << 5)  // restart, sleep, lock, etc.
    static let packageInstall  = PermissionSet(rawValue: 1 << 6)
    static let audioForward    = PermissionSet(rawValue: 1 << 7)
    static let reportInfo      = PermissionSet(rawValue: 1 << 8)

    /// Default for a full-access admin session.
    static let fullAccess: PermissionSet = [
        .observe, .control, .clipboard, .fileTransfer,
        .remoteCommand, .systemActions, .packageInstall,
        .audioForward, .reportInfo
    ]

    /// View-only: can observe and hear audio.
    static let viewOnly: PermissionSet = [.observe, .audioForward]

    /// Standard user: observe, control, clipboard, file transfer, audio.
    static let standard: PermissionSet = [
        .observe, .control, .clipboard, .fileTransfer, .audioForward
    ]

    // MARK: - Human-readable labels

    static let allCases: [(flag: PermissionSet, label: String, icon: String)] = [
        (.observe,        "Observe screen",           "eye"),
        (.control,        "Control (pointer & keyboard)", "cursorarrow.click.2"),
        (.clipboard,      "Clipboard sharing",        "doc.on.clipboard"),
        (.fileTransfer,   "File transfer",            "doc.badge.arrow.up"),
        (.remoteCommand,  "Remote Unix commands",     "terminal"),
        (.systemActions,  "System actions (restart/sleep/lock)", "power"),
        (.packageInstall, "Install packages (.pkg)",  "shippingbox"),
        (.audioForward,   "Audio forwarding",         "speaker.wave.2"),
        (.reportInfo,     "System report / audit",    "info.circle"),
    ]
}
