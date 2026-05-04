import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public extension InputRuleRunner {
    /// The standard markdown shorthand set: ATX headings, blockquote,
    /// bullet/ordered/task lists, horizontal rule, and the inline marks
    /// (bold, italic, strikethrough, inline code).
    static func makeDefault() -> InputRuleRunner {
        let runner = InputRuleRunner()
        // Block rules — order matters within a class because the runner takes
        // first match. Headings are mutually exclusive by `#` count so any
        // order works; lists / blockquote / horizontal rule don't overlap.
        for level in (1...6).reversed() {
            runner.register(InputRule.heading(level: level))
        }
        runner.register(InputRule.blockquote)
        // Task-list rules: register both forms. The from-scratch pattern
        // (`- [ ] `) and the after-bullet pattern (typed `[ ] ` once the
        // line is already a bullet item — the bullet has been replaced
        // with an attachment glyph by then).
        runner.register(InputRule.taskList)
        runner.register(InputRule.taskListAfterBullet)
        runner.register(InputRule.unorderedList)
        runner.register(InputRule.orderedList)
        runner.register(InputRule.horizontalRule)
        // Inline rules — bold before italic so `**bold**` matches the longer
        // pattern first. Strikethrough and code span use distinct delimiters,
        // so ordering between them is irrelevant.
        runner.register(InputRule.bold)
        runner.register(InputRule.italic)
        runner.register(InputRule.strikethrough)
        runner.register(InputRule.codeSpan)
        return runner
    }
}

public extension InputRule {

    // MARK: - block rules

    /// `# `, `## `, … `###### ` at the start of a line. Two-step transaction:
    /// delete the matched prefix, then setSpec to apply the heading. The
    /// second step's range is shifted automatically by `StepMap`.
    static func heading(level: Int) -> InputRule {
        let prefix = String(repeating: "#", count: level)
        return InputRule(
            id: "inputRule.heading-\(level)",
            pattern: "^\(prefix) $"
        ) { match in
            Transaction(steps: [
                .replaceText(range: match.matchedRange, with: NSAttributedString()),
                .setSpec(lineRange: match.lineRange, BlockSpec(kind: .heading(level: level)))
            ], label: "Heading \(level)")
        }
    }

    /// `> ` at the start of a line. Increments the existing blockquote
    /// depth so `>> ` typed in an already-quoted paragraph nests one level
    /// deeper.
    static let blockquote = InputRule(
        id: "inputRule.blockquote",
        pattern: "^> $"
    ) { match in
        let current = currentSpec(at: match.lineRange.location, in: match.storage)
        let newSpec = BlockSpec(
            kind: current.kind.isParagraphLike ? .paragraph : current.kind,
            blockquoteDepth: max(0, current.blockquoteDepth) + 1,
            listLevel: current.listLevel
        )
        return Transaction(steps: [
            .replaceText(range: match.matchedRange, with: NSAttributedString()),
            .setSpec(lineRange: match.lineRange, newSpec)
        ], label: "Blockquote")
    }

    /// `- `, `* `, or `+ ` at the start of a line.
    static let unorderedList = InputRule(
        id: "inputRule.unorderedList",
        pattern: "^[-*+] $"
    ) { match in
        let current = currentSpec(at: match.lineRange.location, in: match.storage)
        return Transaction(steps: [
            .replaceText(range: match.matchedRange, with: NSAttributedString()),
            .setSpec(lineRange: match.lineRange, BlockSpec(
                kind: .unorderedListItem,
                blockquoteDepth: current.blockquoteDepth,
                listLevel: current.listLevel
            ))
        ], label: "Bullet list")
    }

    /// `1. `, `42. `, or `2) ` at the start of a line. The captured number
    /// becomes the list-item index.
    static let orderedList = InputRule(
        id: "inputRule.orderedList",
        pattern: "^(\\d+)[.)] $"
    ) { match in
        guard let raw = match.capture(1), let index = Int(raw) else { return nil }
        let current = currentSpec(at: match.lineRange.location, in: match.storage)
        return Transaction(steps: [
            .replaceText(range: match.matchedRange, with: NSAttributedString()),
            .setSpec(lineRange: match.lineRange, BlockSpec(
                kind: .orderedListItem(index: index),
                blockquoteDepth: current.blockquoteDepth,
                listLevel: current.listLevel
            ))
        ], label: "Ordered list")
    }

    /// `- [ ] ` or `- [x] ` at the start of a line.
    static let taskList = InputRule(
        id: "inputRule.taskList",
        pattern: "^[-*+] \\[([ xX])\\] $"
    ) { match in
        let mark = match.capture(1) ?? " "
        let isChecked = mark.lowercased() == "x"
        let current = currentSpec(at: match.lineRange.location, in: match.storage)
        return Transaction(steps: [
            .replaceText(range: match.matchedRange, with: NSAttributedString()),
            .setSpec(lineRange: match.lineRange, BlockSpec(
                kind: .taskListItem(checked: isChecked),
                blockquoteDepth: current.blockquoteDepth,
                listLevel: current.listLevel
            ))
        ], label: "Task list")
    }

    /// `[ ] ` or `[x] ` typed *after* a line has already been converted to
    /// a bullet list item (the leading `- ` was replaced with an attachment
    /// glyph by `unorderedList` firing). setSpec re-renders the line as a
    /// task item and the markdown round-trip strips the `[ ] ` body.
    static let taskListAfterBullet = InputRule(
        id: "inputRule.taskListAfterBullet",
        pattern: "^\u{FFFC} \\[([ xX])\\] $"
    ) { match in
        let mark = match.capture(1) ?? " "
        let isChecked = mark.lowercased() == "x"
        let current = currentSpec(at: match.lineRange.location, in: match.storage)
        return Transaction(steps: [
            .setSpec(lineRange: match.lineRange, BlockSpec(
                kind: .taskListItem(checked: isChecked),
                blockquoteDepth: current.blockquoteDepth,
                listLevel: current.listLevel
            ))
        ], label: "Task list")
    }

    /// `---` on its own line. Single-step setSpec — the compiler renders the
    /// `---` markup directly so a delete is unnecessary.
    static let horizontalRule = InputRule(
        id: "inputRule.horizontalRule",
        pattern: "^---$"
    ) { match in
        Transaction(steps: [
            .setSpec(lineRange: match.lineRange, BlockSpec(kind: .horizontalRule))
        ], label: "Horizontal rule")
    }

    // MARK: - inline rules
    //
    // Inline rules don't delete the markdown markup — they re-run the line
    // through the compiler via setSpec(currentSpec). The compiler picks up
    // the just-typed `**`, `~~`, `` ` `` markers and applies the inline
    // styling. The user keeps the visible markdown source.

    static let bold = InputRule(
        id: "inputRule.bold",
        pattern: "\\*\\*([^*\\n]+)\\*\\*$"
    ) { match in
        recompileLine(match: match, label: "Bold")
    }

    static let italic = InputRule(
        id: "inputRule.italic",
        pattern: "(?<![*])\\*([^*\\n]+)\\*$"
    ) { match in
        recompileLine(match: match, label: "Italic")
    }

    /// Strikethrough is a GFM extension that the CommonMark grammar in this
    /// codebase doesn't parse natively, so `setSpec` re-rendering won't
    /// apply the attribute. Apply `toggleInlineMark(.strikethrough)` to the
    /// inner capture group directly.
    static let strikethrough = InputRule(
        id: "inputRule.strikethrough",
        pattern: "~~([^~\\n]+)~~$"
    ) { match in
        let innerRange = match.captureRanges.indices.contains(1) ? match.captureRanges[1] : match.matchedRange
        guard innerRange.location != NSNotFound else { return nil }
        return Transaction(steps: [
            .toggleInlineMark(range: innerRange, .strikethrough)
        ], label: "Strikethrough")
    }

    static let codeSpan = InputRule(
        id: "inputRule.codeSpan",
        pattern: "`([^`\\n]+)`$"
    ) { match in
        recompileLine(match: match, label: "Inline code")
    }

    private static func recompileLine(match: InputRule.Match, label: String) -> Transaction {
        let current = currentSpec(at: match.lineRange.location, in: match.storage)
        return Transaction(steps: [
            .setSpec(lineRange: match.lineRange, current)
        ], label: label)
    }

    private static func currentSpec(at location: Int, in storage: NSTextStorage) -> BlockSpec {
        if location < storage.length, let spec = storage.blockSpec(at: location) {
            return spec
        }
        return BlockSpec(kind: .paragraph)
    }
}

private extension BlockSpec.Kind {
    /// Plain paragraphs and headings host inline content; other kinds carry
    /// structural markup we don't want to overwrite when adding a quote
    /// prefix.
    var isParagraphLike: Bool {
        switch self {
        case .paragraph, .heading:
            return true
        default:
            return false
        }
    }
}
