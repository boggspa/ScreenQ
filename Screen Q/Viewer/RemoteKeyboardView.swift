//
//  RemoteKeyboardView.swift
//  Screen Q
//
//  iOS on-screen keyboard input: a hidden UITextField becomes first responder
//  to raise the iOS keyboard. Each keystroke is forwarded individually to the
//  remote host via InputMappingService, giving character-by-character control
//  rather than "type then send" batching.
//

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - SwiftUI wrapper

struct RemoteKeyboardView: UIViewRepresentable {

    let inputMapper: InputMappingService
    @Binding var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(inputMapper: inputMapper, isActive: $isActive)
    }

    func makeUIView(context: Context) -> RemoteKeyboardTextField {
        let field = RemoteKeyboardTextField()
        field.coordinator = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .default
        field.returnKeyType = .default
        // Keep the field invisible but in the view hierarchy.
        field.alpha = 0.01
        field.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        return field
    }

    func updateUIView(_ uiView: RemoteKeyboardTextField, context: Context) {
        context.coordinator.inputMapper = inputMapper
        context.coordinator.isActive = $isActive
        if isActive && !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !isActive && uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextFieldDelegate {

        var inputMapper: InputMappingService
        var isActive: Binding<Bool>

        init(inputMapper: InputMappingService, isActive: Binding<Bool>) {
            self.inputMapper = inputMapper
            self.isActive = isActive
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.isActive.wrappedValue = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async { self.isActive.wrappedValue = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            inputMapper.sendKey(.returnKey)
            return false
        }
    }
}

// MARK: - Custom UITextField subclass

/// Intercepts individual key presses (including backspace) and forwards them
/// to the remote host rather than inserting text locally.
final class RemoteKeyboardTextField: UITextField {

    weak var coordinator: RemoteKeyboardView.Coordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = nil
        // Keep a sentinel character so backspace always has something to delete.
        text = " "
        addTarget(self, action: #selector(textDidChange), for: .editingChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var delegate: UITextFieldDelegate? {
        get { coordinator }
        set { /* managed internally */ }
    }

    override var canBecomeFirstResponder: Bool { true }

    // Intercept hardware keyboard commands.
    override var keyCommands: [UIKeyCommand]? {
        var cmds: [UIKeyCommand] = []
        let special: [String] = [
            UIKeyCommand.inputEscape,
            "\t",
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
        ]
        for input in special {
            for modifiers in Self.hardwareModifierCombinations {
                cmds.append(UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(handleSpecialKey(_:))))
            }
        }

        let namedKeys: [(String, KeyCode)] = [
            (" ", .spacebar),
            ("\u{8}", .backspace)
        ]
        for (input, _) in namedKeys {
            for modifiers in Self.hardwareModifierCombinations {
                cmds.append(UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(handleNamedKey(_:))))
            }
        }

        let shortcutLetters = ["a", "c", "d", "f", "h", "l", "m", "q", "v", "w", "x", "z"]
        for letter in shortcutLetters {
            for modifiers in Self.shortcutModifierCombinations {
                cmds.append(UIKeyCommand(input: letter, modifierFlags: modifiers, action: #selector(handleShortcutKey(_:))))
            }
        }
        return cmds
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled = sendHardwareKeys(from: presses)
        if handled.count < presses.count {
            super.pressesBegan(presses.subtracting(handled), with: event)
        }
    }

    private func sendHardwareKeys(from presses: Set<UIPress>) -> Set<UIPress> {
        guard let mapper = coordinator?.inputMapper else { return [] }
        var handled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  let keyCode = keyCode(for: key.keyCode) else {
                continue
            }
            mapper.sendKey(keyCode, modifiers: keyModifiers(from: key.modifierFlags))
            handled.insert(press)
        }
        return handled
    }

    @objc private func handleSpecialKey(_ cmd: UIKeyCommand) {
        guard let mapper = coordinator?.inputMapper else { return }
        let modifiers = keyModifiers(from: cmd.modifierFlags)
        switch cmd.input {
        case UIKeyCommand.inputEscape:
            mapper.sendKey(.escape, modifiers: modifiers)
        case "\t":
            mapper.sendKey(.tab, modifiers: modifiers)
        case UIKeyCommand.inputUpArrow:
            mapper.sendKey(.arrowUp, modifiers: modifiers)
        case UIKeyCommand.inputDownArrow:
            mapper.sendKey(.arrowDown, modifiers: modifiers)
        case UIKeyCommand.inputLeftArrow:
            mapper.sendKey(.arrowLeft, modifiers: modifiers)
        case UIKeyCommand.inputRightArrow:
            mapper.sendKey(.arrowRight, modifiers: modifiers)
        default:
            break
        }
    }

    @objc private func handleNamedKey(_ cmd: UIKeyCommand) {
        guard let mapper = coordinator?.inputMapper else { return }
        let modifiers = keyModifiers(from: cmd.modifierFlags)
        switch cmd.input {
        case " ":
            mapper.sendKey(.spacebar, modifiers: modifiers)
        case "\u{8}":
            mapper.sendKey(.backspace, modifiers: modifiers)
        default:
            break
        }
    }

    @objc private func handleShortcutKey(_ cmd: UIKeyCommand) {
        guard let mapper = coordinator?.inputMapper,
              let input = cmd.input,
              let key = keyCode(for: input.lowercased()) else {
            return
        }
        mapper.sendKey(key, modifiers: keyModifiers(from: cmd.modifierFlags))
    }

    private func keyCode(for input: String) -> KeyCode? {
        switch input {
        case "a": return .a
        case "c": return .c
        case "d": return .d
        case "f": return .f
        case "h": return .h
        case "l": return .l
        case "m": return .m
        case "q": return .q
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "z": return .z
        default: return nil
        }
    }

    private func keyCode(for hidUsage: UIKeyboardHIDUsage) -> KeyCode? {
        switch hidUsage {
        case .keyboardDeleteForward: return .delete
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardF1: return .f1
        case .keyboardF2: return .f2
        case .keyboardF3: return .f3
        case .keyboardF4: return .f4
        case .keyboardF5: return .f5
        case .keyboardF6: return .f6
        case .keyboardF7: return .f7
        case .keyboardF8: return .f8
        case .keyboardF9: return .f9
        case .keyboardF10: return .f10
        case .keyboardF11: return .f11
        case .keyboardF12: return .f12
        default: return nil
        }
    }

    private func keyModifiers(from flags: UIKeyModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    private static let hardwareModifierCombinations: [UIKeyModifierFlags] = [
        [],
        [.shift],
        [.control],
        [.alternate],
        [.command],
        [.shift, .control],
        [.shift, .alternate],
        [.shift, .command],
        [.control, .alternate],
        [.control, .command],
        [.alternate, .command],
        [.shift, .control, .alternate],
        [.shift, .control, .command],
        [.shift, .alternate, .command],
        [.control, .alternate, .command],
        [.shift, .control, .alternate, .command]
    ]

    private static let shortcutModifierCombinations: [UIKeyModifierFlags] = hardwareModifierCombinations.filter { !$0.isEmpty }

    @objc private func textDidChange() {
        guard let mapper = coordinator?.inputMapper else { return }
        let current = text ?? ""

        if current.isEmpty {
            // Backspace was pressed (sentinel was deleted).
            mapper.sendKey(.backspace)
            text = " "  // restore sentinel
        } else if current.count > 1 {
            // Characters were typed. Send each one, then reset to sentinel.
            let typed = current.dropFirst() // skip sentinel space
            if !typed.isEmpty {
                mapper.sendText(String(typed))
            }
            text = " "  // restore sentinel
        }
        // If exactly " " (the sentinel), no change — do nothing.
    }
}
#endif
