import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Build a transaction that toggles `mark` and preserves the selection
/// across the toggle (mark commands are chainable — bold then italic).
private func toggleMarkTx(_ mark: InlineMark, range: NSRange, label: String) -> Transaction {
    Transaction(
        steps: [.toggleInlineMark(range: range, mark)],
        label: label,
        selection: range.length > 0 ? .textRange(range) : nil
    )
}

public struct ToggleBoldCommand: Command {
    public let id = "bold"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        toggleMarkTx(.bold, range: selection, label: "Bold")
    }
}

public struct ToggleItalicCommand: Command {
    public let id = "italic"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        toggleMarkTx(.italic, range: selection, label: "Italic")
    }
}

public struct ToggleStrikethroughCommand: Command {
    public let id = "strikethrough"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        toggleMarkTx(.strikethrough, range: selection, label: "Strikethrough")
    }
}

public struct ToggleCodeSpanCommand: Command {
    public let id = "codeSpan"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        toggleMarkTx(.codeSpan, range: selection, label: "Code")
    }
}
