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
        runner.register(InputRule.fencedCodeBlock)
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

    /// Triple backticks plus an optional language tag, terminated by Enter.
    /// `^```([\w+#.-]*)\n$` captures the language (empty for bare ```). The
    /// line is replaced with an empty fenced code block whose leaf attrs
    /// carry the language; storage holds only the body.
    static let fencedCodeBlock = InputRule(
        id: "inputRule.fencedCodeBlock",
        pattern: "^```([\\w+#.-]*)\\n$"
    ) { match in
        if let existing = match.storage.blockSpec(at: match.lineRange.location),
           case .fencedCode = existing.kind {
            return nil
        }
        let env = match.env
        let language = match.capture(1) ?? ""
        let block = env.compiler.compile("```\(language)\n\n```\n", theme: env.theme)
        return Transaction(steps: [
            .replaceText(range: match.lineRange, with: block)
        ], label: "Code block")
    }

    // MARK: - inline rules
    //
    // Inline rules delete the two delimiter runs and add the mark over the
    // capture. Nothing else on the line is re-rendered, so the text ahead of
    // the match keeps its characters and the line keeps its node.

    static let bold = InputRule(
        id: "inputRule.bold",
        pattern: "\\*\\*([^*\\n]+)\\*\\*$",
        inCode: .skip
    ) { match in
        markInputRule(match: match, markType: "strong", label: "Bold")
    }

    static let italic = InputRule(
        id: "inputRule.italic",
        pattern: "(?<![*])\\*([^*\\n]+)\\*$",
        inCode: .skip
    ) { match in
        markInputRule(match: match, markType: "em", label: "Italic")
    }

    static let strikethrough = InputRule(
        id: "inputRule.strikethrough",
        pattern: "~~([^~\\n]+)~~$",
        inCode: .skip
    ) { match in
        markInputRule(match: match, markType: "strike", label: "Strikethrough")
    }

    static let codeSpan = InputRule(
        id: "inputRule.codeSpan",
        pattern: "`([^`\\n]+)`$",
        inCode: .skip
    ) { match in
        markInputRule(match: match, markType: "code", label: "Inline code", tightFlanks: false)
    }

    /// Step ranges are pre-edit coordinates; `Transaction.apply` maps each
    /// through the ones before it. The closing delimiter goes first so the
    /// opening one needs no mapping. The caret is where the content ends
    /// once the opening delimiter is gone.
    ///
    /// `tightFlanks` rejects a capture that opens or closes on whitespace,
    /// which the compiler leaves literal — firing there would delete
    /// characters a reload cannot bring back. A code span keeps its padding
    /// verbatim and passes `false`.
    private static func markInputRule(
        match: InputRule.Match,
        markType: MarkType.Name,
        label: String,
        tightFlanks: Bool = true
    ) -> Transaction? {
        guard match.captureRanges.count > 1 else { return nil }
        let content = match.captureRanges[1]
        guard content.location != NSNotFound else { return nil }
        let matched = match.matchedRange
        let openLength = content.location - matched.location
        let closeStart = content.location + content.length
        let closeLength = matched.location + matched.length - closeStart
        guard content.length > 0, openLength > 0, closeLength > 0 else { return nil }
        let text = match.capture(1) ?? ""
        if tightFlanks {
            guard let first = text.first, let last = text.last,
                  !first.isWhitespace, !last.isWhitespace else { return nil }
        }
        let mark = ProseMark(type: markType)
        guard let removals = excludedMarkRemovals(
            for: mark,
            over: content,
            in: match.storage,
            schema: match.env.compiler.schema
        ) else { return nil }
        return Transaction(
            steps: [
                .replaceText(
                    range: NSRange(location: closeStart, length: closeLength),
                    with: NSAttributedString()
                ),
                .replaceText(
                    range: NSRange(location: matched.location, length: openLength),
                    with: NSAttributedString()
                )
            ] + removals + [
                .addMark(range: content, mark: mark)
            ],
            label: label,
            selection: .cursor(at: matched.location + content.length)
        )
    }

    /// One `removeMark` per run per type `mark` excludes. `addMark`'s typed
    /// inverse only puts its own type back, so a mark `MarkSet.adding` drops
    /// needs a step of its own whose inverse restores it with its attrs.
    ///
    /// Nil when an existing mark excludes `mark`: it cannot land, so the
    /// rule must not eat the delimiters for it.
    private static func excludedMarkRemovals(
        for mark: ProseMark,
        over range: NSRange,
        in storage: NSTextStorage,
        schema: Schema
    ) -> [Step]? {
        var steps: [Step] = []
        var blocked = false
        storage.enumerateAttribute(.proseMarks, in: range, options: []) { value, runRange, _ in
            guard let current = (value as? MarkSetBox)?.marks, !current.isEmpty else { return }
            let updated = current.adding(mark, in: schema)
            guard updated.contains(type: mark.type) else {
                blocked = true
                return
            }
            for existing in current.marks where !updated.contains(type: existing.type) {
                steps.append(.removeMark(range: runRange, markType: existing.type))
            }
        }
        return blocked ? nil : steps
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
