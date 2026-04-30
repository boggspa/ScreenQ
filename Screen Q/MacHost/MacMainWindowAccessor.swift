//
//  MacMainWindowAccessor.swift
//  Screen Q
//

#if os(macOS)
import AppKit
import SwiftUI

struct MacMainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        registerWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        registerWindow(for: nsView)
    }

    private func registerWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            MacWindowRegistry.shared.registerMainWindow(window)
        }
    }
}
#endif
