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
        let special: [(UIKeyboardHIDUsage, String)] = [
            (.keyboardEscape, UIKeyCommand.inputEscape),
            (.keyboardTab, "\t"),
            (.keyboardUpArrow, UIKeyCommand.inputUpArrow),
            (.keyboardDownArrow, UIKeyCommand.inputDownArrow),
            (.keyboardLeftArrow, UIKeyCommand.inputLeftArrow),
            (.keyboardRightArrow, UIKeyCommand.inputRightArrow),
        ]
        for (_, input) in special {
            cmds.append(UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleSpecialKey(_:))))
            cmds.append(UIKeyCommand(input: input, modifierFlags: [.shift], action: #selector(handleSpecialKey(_:))))
            cmds.append(UIKeyCommand(input: input, modifierFlags: [.control], action: #selector(handleSpecialKey(_:))))
            cmds.append(UIKeyCommand(input: input, modifierFlags: [.alternate], action: #selector(handleSpecialKey(_:))))
            cmds.append(UIKeyCommand(input: input, modifierFlags: [.command], action: #selector(handleSpecialKey(_:))))
        }

        let namedKeys: [(String, KeyCode)] = [
            (" ", .spacebar),
            ("\u{8}", .backspace)
        ]
        for (input, _) in namedKeys {
            cmds.append(UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleNamedKey(_:))))
            cmds.append(UIKeyCommand(input: input, modifierFlags: [.command], action: #selector(handleNamedKey(_:))))
            cmds.append(UIKeyCommand(input: input, modifierFlags: [.control], action: #selector(handleNamedKey(_:))))
        }

        let shortcutLetters = ["a", "c", "d", "f", "h", "l", "m", "q", "v", "w", "x", "z"]
        for letter in shortcutLetters {
            cmds.append(UIKeyCommand(input: letter, modifierFlags: [.command], action: #selector(handleShortcutKey(_:))))
            cmds.append(UIKeyCommand(input: letter, modifierFlags: [.command, .shift], action: #selector(handleShortcutKey(_:))))
            cmds.append(UIKeyCommand(input: letter, modifierFlags: [.control], action: #selector(handleShortcutKey(_:))))
            cmds.append(UIKeyCommand(input: letter, modifierFlags: [.alternate], action: #selector(handleShortcutKey(_:))))
        }
        return cmds
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

    private func keyModifiers(from flags: UIKeyModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

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
