//
//  BundleIdentity.swift
//  Screen Q
//
//  Centralizes reverse-DNS identifiers so forks and local builds inherit the
//  active PRODUCT_BUNDLE_IDENTIFIER instead of sharing developer-local strings.
//

import Foundation

nonisolated enum BundleIdentity {
    static let identifier: String = Bundle.main.bundleIdentifier ?? "app.screenq.Screen-Q"

    static func service(_ suffix: String) -> String {
        "\(identifier).\(suffix)"
    }
}
