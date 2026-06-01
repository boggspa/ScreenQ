//
//  CompatOnChange.swift
//  Screen Q
//
//  Back-deployable replacement for SwiftUI's deprecated one-argument
//  onChange(of:perform:) API.
//

import SwiftUI
import Combine

private struct ScreenQOnChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void

    @State private var previousValue: Value?

    func body(content: Content) -> some View {
        content
            .onAppear {
                previousValue = value
            }
            .onReceive(Just(value)) { newValue in
                guard let previousValue else {
                    self.previousValue = newValue
                    return
                }
                guard newValue != previousValue else { return }
                self.previousValue = newValue
                action(newValue)
            }
    }
}

extension View {
    func screenQOnChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        modifier(ScreenQOnChangeModifier(value: value, action: action))
    }
}
