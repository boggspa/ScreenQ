//
//  MainActorHelpers.swift
//  Screen Q
//

import Foundation

/// Hop to the main actor and run the closure synchronously when already on
/// the main actor; otherwise dispatch and await. Useful for callback-driven
/// APIs (Network.framework) that need to update `@MainActor` state.
@inline(__always)
func onMain(_ block: @MainActor @Sendable @escaping () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            block()
        }
    } else {
        Task { @MainActor in
            block()
        }
    }
}
