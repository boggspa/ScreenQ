//
//  ReplayKitBroadcastModel.swift
//  Screen Q
//
//  Models the iOS / iPadOS broadcast picker state + provides a SwiftUI
//  representable wrapper around RPSystemBroadcastPickerView. Apple does not
//  expose any third-party API to inject touches into iOS / iPadOS, so the
//  host on those platforms is strictly view-only.
//

#if os(iOS)
import Foundation
import ReplayKit
import SwiftUI
import UIKit
import Combine

@MainActor
final class ReplayKitBroadcastModel: ObservableObject {

    static let defaultBroadcastExtensionBundleID: String? = nil

    /// Public builds do not ship the experimental Broadcast Upload Extension.
    /// Set this from a development build only after wiring a working transport.
    @Published var broadcastExtensionBundleID: String? = defaultBroadcastExtensionBundleID

    @Published private(set) var isBroadcastingHint: Bool = false

    /// Notify the user that no extension is wired. We still allow the picker
    /// to display, but clearly label the limitation.
    var hasExtensionConfigured: Bool { broadcastExtensionBundleID != nil }
}

/// SwiftUI bridge for `RPSystemBroadcastPickerView`.
struct BroadcastPicker: UIViewRepresentable {

    var preferredExtensionBundleID: String?
    var showsMicrophoneButton: Bool = false

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = preferredExtensionBundleID
        picker.showsMicrophoneButton = showsMicrophoneButton
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = preferredExtensionBundleID
        uiView.showsMicrophoneButton = showsMicrophoneButton
    }
}

#endif
