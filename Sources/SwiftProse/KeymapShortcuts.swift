import SwiftProseSyntax
import SwiftProseRendering
import SwiftProseView
import Foundation
import SwiftUI

extension Keymap {
    public func keyboardShortcut(for action: EditorAction) -> KeyboardShortcut? {
        guard let spec = bindings.first(where: { $0.value == action })?.key else { return nil }
        var parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.popLast(), key.count == 1, let character = key.first else { return nil }
        var modifiers: EventModifiers = []
        for part in parts {
            switch part {
            case "Mod": modifiers.insert(.command)
            case "Shift": modifiers.insert(.shift)
            case "Alt": modifiers.insert(.option)
            default: return nil
            }
        }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }

    public func action(for key: String, command: Bool, shift: Bool = false, option: Bool = false) -> EditorAction? {
        action(forKey: KeySpec.make(key: key, mod: command, shift: shift, alt: option))
    }
}
