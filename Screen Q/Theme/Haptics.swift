//
//  Haptics.swift
//  Screen Q  ·  Theme
//
//  Cross-platform haptic helper. No-op on macOS, UIKit feedback on iOS.
//  Call from every toggle, mode switch, bookmark, destructive confirm so
//  the app feels alive on iPhone / iPad.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

enum SQHaptics {

    /// Light tap — toggles, segmented control changes, picker rolls.
    static func tap() {
        #if os(iOS)
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
        #endif
    }

    /// Medium thud — bookmarks, mode switches, destructive arms.
    static func bump() {
        #if os(iOS)
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
        #endif
    }

    /// Notification: success.
    static func success() {
        #if os(iOS)
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.success)
        #endif
    }

    /// Notification: warning.
    static func warning() {
        #if os(iOS)
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.warning)
        #endif
    }

    /// Notification: error.
    static func error() {
        #if os(iOS)
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.error)
        #endif
    }
}
