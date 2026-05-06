import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Generic toggle for an inline mark. Registered four times with the
/// stable IDs `bold` / `italic` / `strikethrough` / `codeSpan` to match
/// the existing EditorAction surface.
public struct ToggleMarkCommand: Command {
    public let id: String
    public let mark: InlineMark
    public let label: String

    public init(id: String, mark: InlineMark, label: String) {
        self.id = id
        self.mark = mark
        self.label = label
    }

    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }

    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        Transaction(
            steps: [.toggleInlineMark(range: selection, mark)],
            label: label,
            selection: selection.length > 0 ? .textRange(selection) : nil
        )
    }
}

// Per-mark wrappers preserved for typed call sites.
public struct ToggleBoldCommand: Command {
    public let id = "bold"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        ToggleMarkCommand(id: id, mark: .bold, label: "Bold")
            .transaction(storage: storage, selection: selection, env: env)
    }
}

public struct ToggleItalicCommand: Command {
    public let id = "italic"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        ToggleMarkCommand(id: id, mark: .italic, label: "Italic")
            .transaction(storage: storage, selection: selection, env: env)
    }
}

public struct ToggleStrikethroughCommand: Command {
    public let id = "strikethrough"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        ToggleMarkCommand(id: id, mark: .strikethrough, label: "Strikethrough")
            .transaction(storage: storage, selection: selection, env: env)
    }
}

public struct ToggleCodeSpanCommand: Command {
    public let id = "codeSpan"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        ToggleMarkCommand(id: id, mark: .codeSpan, label: "Code")
            .transaction(storage: storage, selection: selection, env: env)
    }
}
