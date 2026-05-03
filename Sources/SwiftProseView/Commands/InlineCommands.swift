import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct ToggleBoldCommand: Command {
    public let id = "bold"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        Transaction(steps: [.toggleInlineMark(range: selection, .bold)], label: "Bold")
    }
}

public struct ToggleItalicCommand: Command {
    public let id = "italic"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        Transaction(steps: [.toggleInlineMark(range: selection, .italic)], label: "Italic")
    }
}

public struct ToggleStrikethroughCommand: Command {
    public let id = "strikethrough"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        Transaction(steps: [.toggleInlineMark(range: selection, .strikethrough)], label: "Strikethrough")
    }
}

public struct ToggleCodeSpanCommand: Command {
    public let id = "codeSpan"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        Transaction(steps: [.toggleInlineMark(range: selection, .codeSpan)], label: "Code")
    }
}
