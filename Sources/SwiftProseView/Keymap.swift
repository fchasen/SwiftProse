import SwiftProseSyntax
import SwiftProseRendering
import Foundation

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

    public static let mac: Keymap = {
        var k = Keymap()
        k.bind("Mod-b", to: .bold)
        k.bind("Mod-i", to: .italic)
        k.bind("Mod-e", to: .codeSpan)
        k.bind("Mod-]", to: .indent)
        k.bind("Mod-[", to: .outdent)
        return k
    }()

    public static let pc: Keymap = mac
}

public enum KeySpec {
    public static func make(key: String, mod: Bool = false, shift: Bool = false, alt: Bool = false) -> String {
        var parts: [String] = []
        if mod { parts.append("Mod") }
        if shift { parts.append("Shift") }
        if alt { parts.append("Alt") }
        parts.append(key.lowercased())
        return parts.joined(separator: "-")
    }
}
