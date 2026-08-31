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
        // Add-vs-remove is decided on the untrimmed range, then only an add
        // is trimmed: `**loud **and clear` can't close an emphasis run, so a
        // mark that swallows its trailing space is lost on the next read.
        // Removal keeps the full range so the space can be un-marked.
        let isRemoval = storage.marksIntersected(in: selection)?.contains(name: mark.markName) == true
        let applied = isRemoval ? selection : Self.trimmingWhitespace(selection, in: storage)
        return Transaction(
            steps: [.toggleInlineMark(range: applied, mark)],
            label: label,
            // The user's selection survives, so a second mark can be chained.
            selection: selection.length > 0 ? .textRange(selection) : nil
        )
    }

    /// Pull the range in past leading and trailing whitespace. Returns the
    /// original when nothing is left, matching PM's `from + spaceStart < to`
    /// guard.
    static func trimmingWhitespace(_ range: NSRange, in storage: NSAttributedString) -> NSRange {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= storage.length
        else { return range }
        let text = storage.string as NSString
        let ws = CharacterSet.whitespacesAndNewlines
        var start = range.location
        var end = range.location + range.length
        while start < end,
              let scalar = text.substring(with: NSRange(location: start, length: 1)).unicodeScalars.first,
              ws.contains(scalar) {
            start += 1
        }
        while end > start,
              let scalar = text.substring(with: NSRange(location: end - 1, length: 1)).unicodeScalars.first,
              ws.contains(scalar) {
            end -= 1
        }
        return start < end ? NSRange(location: start, length: end - start) : range
    }

    public func isActive(
        storage: NSAttributedString,
        selection: NSRange,
        controller: EditorController
    ) -> Bool {
        controller.inlineMarkIsActive(mark, selection: selection)
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
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        controller.inlineMarkIsActive(.bold, selection: selection)
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
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        controller.inlineMarkIsActive(.italic, selection: selection)
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
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        controller.inlineMarkIsActive(.strikethrough, selection: selection)
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
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        controller.inlineMarkIsActive(.codeSpan, selection: selection)
    }
}
