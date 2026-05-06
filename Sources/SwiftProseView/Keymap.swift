import Foundation

/// Stringly-keyed binding from a normalized key spec (e.g. `"Mod-b"`) to
/// an `EditorAction`. PM convention: `Mod` is Cmd on Mac, Ctrl on PC.
/// Hosts customize bindings via `EditorController.keymap`; the platform
/// text views consult `action(forKey:)` before falling back to default
/// AppKit / UIKit behavior.
public struct Keymap: Sendable, Equatable {
    public var bindings: [String: EditorAction]

    public init(_ bindings: [String: EditorAction] = [:]) {
        self.bindings = bindings
    }

    public func action(forKey key: String) -> EditorAction? {
        bindings[key]
    }

    public mutating func bind(_ key: String, to action: EditorAction) {
        bindings[key] = action
    }

    public mutating func unbind(_ key: String) {
        bindings.removeValue(forKey: key)
    }

    /// Default Mac bindings — PM-style names where `Mod` resolves to Cmd.
    public static let mac: Keymap = {
        var k = Keymap()
        k.bind("Mod-b", to: .bold)
        k.bind("Mod-i", to: .italic)
        k.bind("Mod-e", to: .codeSpan)
        k.bind("Mod-]", to: .indent)
        k.bind("Mod-[", to: .outdent)
        return k
    }()

    /// Default PC / Linux bindings — PM-style names where `Mod` resolves
    /// to Ctrl. Same actions as `mac`; the platform text view picks the
    /// modifier when looking up the spec.
    public static let pc: Keymap = mac
}

public enum KeySpec {
    /// Build a normalized key spec from a key character and modifier
    /// flags. The character is lowercased; modifier order is fixed
    /// (`Mod`, `Shift`, `Alt`) so two equivalent specs always match.
    public static func make(key: String, mod: Bool = false, shift: Bool = false, alt: Bool = false) -> String {
        var parts: [String] = []
        if mod { parts.append("Mod") }
        if shift { parts.append("Shift") }
        if alt { parts.append("Alt") }
        parts.append(key.lowercased())
        return parts.joined(separator: "-")
    }
}
