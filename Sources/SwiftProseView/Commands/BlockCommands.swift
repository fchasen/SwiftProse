import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

func transformParagraphs(
    storage: NSAttributedString,
    selection: NSRange,
    label: String,
    transform: (BlockSpec) -> BlockSpec
) -> Transaction {
    let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
    if lineRanges.isEmpty {
        return Transaction(
            steps: [.setSpec(lineRange: NSRange(location: 0, length: 0), transform(.paragraph))],
            label: label
        )
    }
    var steps: [Step] = []
    for lineRange in lineRanges {
        let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
        steps.append(.setSpec(lineRange: lineRange, transform(current)))
    }
    return Transaction(steps: steps, label: label)
}

/// Generic block-type setter — replaces SetHeadingCommand. Picks an
/// `id` and a target `BlockSpec.Kind` per call site; commands wrap this
/// when they want a stable ID for registration.
public struct SetBlockTypeCommand: Command {
    public let id: String
    public let label: String
    public let kind: BlockSpec.Kind

    public init(id: String, label: String, kind: BlockSpec.Kind) {
        self.id = id
        self.label = label
        self.kind = kind
    }

    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }

    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: label) { current in
            BlockSpec(kind: kind, blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel)
        }
    }

    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        allParagraphsMatch(storage: storage, selection: selection) { $0.kind == kind }
    }
}

/// True iff every paragraph touched by `selection` satisfies `predicate`.
/// Empty selection probes the cursor's line; empty document is considered
/// not-matching.
func allParagraphsMatch(
    storage: NSAttributedString,
    selection: NSRange,
    predicate: (BlockSpec) -> Bool
) -> Bool {
    let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
    if lineRanges.isEmpty {
        return predicate(.paragraph)
    }
    for lineRange in lineRanges {
        let probe = max(0, min(lineRange.location, storage.length - 1))
        let spec = storage.blockSpec(at: probe) ?? .paragraph
        if !predicate(spec) { return false }
    }
    return true
}

public struct SetHeadingCommand: Command {
    public let level: Int
    public var id: String { "heading:\(level)" }
    public init(level: Int) { self.level = level }

    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }

    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: level == 0 ? "Paragraph" : "Heading \(level)") { current in
            if level == 0 {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .heading(level: level), blockquoteDepth: current.blockquoteDepth)
        }
    }

    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        allParagraphsMatch(storage: storage, selection: selection) { spec in
            if level == 0 {
                if case .paragraph = spec.kind { return true }
                return false
            }
            if case .heading(let l) = spec.kind { return l == level }
            return false
        }
    }
}

public struct ToggleUnorderedListCommand: Command {
    public let id = "unorderedList"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: "Bullet List") { current in
            if case .unorderedListItem = current.kind {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .unorderedListItem, blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel)
        }
    }
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        allParagraphsMatch(storage: storage, selection: selection) { spec in
            if case .unorderedListItem = spec.kind { return true }
            return false
        }
    }
}

public struct ToggleOrderedListCommand: Command {
    public let id = "orderedList"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: "Ordered List") { current in
            if case .orderedListItem = current.kind {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .orderedListItem(index: 1), blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel)
        }
    }
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        allParagraphsMatch(storage: storage, selection: selection) { spec in
            if case .orderedListItem = spec.kind { return true }
            return false
        }
    }
}

public struct ToggleTaskListCommand: Command {
    public let id = "taskList"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: "Task List") { current in
            if case .taskListItem = current.kind {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .taskListItem(checked: false), blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel)
        }
    }
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        allParagraphsMatch(storage: storage, selection: selection) { spec in
            if case .taskListItem = spec.kind { return true }
            return false
        }
    }
}

/// Move the cursor out of a fenced code block. If the block is empty,
/// it's replaced by an empty paragraph; otherwise a fresh paragraph is
/// appended after the block.
public struct ExitCodeBlockCommand: Command {
    public let id = "exitCodeBlock"
    public init() {}

    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        let total = storage.length
        guard total > 0 else { return false }
        let probe = max(0, min(selection.location, total - 1))
        return storage.blockSpec(at: probe)?.isCodeBlock == true
    }

    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let total = storage.length
        guard total > 0 else { return nil }
        let probe = max(0, min(selection.location, total - 1))
        guard storage.blockSpec(at: probe)?.isCodeBlock == true else { return nil }
        var blockStart = probe
        while blockStart > 0, storage.blockSpec(at: blockStart - 1)?.isCodeBlock == true {
            blockStart -= 1
        }
        var blockEnd = probe
        while blockEnd < total, storage.blockSpec(at: blockEnd)?.isCodeBlock == true {
            blockEnd += 1
        }
        let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
        let bodyText = (storage.string as NSString).substring(with: blockRange)
        let isEmpty = bodyText
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
        let plainAttrs = env.theme.plainParagraphAttributes()
        let blank = NSAttributedString(string: "\n", attributes: plainAttrs)
        let mutationRange: NSRange
        let landing: Int
        if isEmpty {
            mutationRange = blockRange
            landing = blockStart
        } else {
            mutationRange = NSRange(location: blockEnd, length: 0)
            landing = blockEnd
        }
        var tx = Transaction(
            steps: [.replaceText(range: mutationRange, with: blank)],
            label: "Exit Code Block"
        )
        tx.selection = .cursor(at: landing)
        return tx
    }
}

public struct ToggleBlockquoteCommand: Command {
    public let id = "blockquote"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: "Blockquote") { current in
            let nextDepth = current.blockquoteDepth > 0 ? current.blockquoteDepth - 1 : current.blockquoteDepth + 1
            return BlockSpec(kind: current.kind, blockquoteDepth: nextDepth, listLevel: current.listLevel)
        }
    }
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        allParagraphsMatch(storage: storage, selection: selection) { $0.blockquoteDepth > 0 }
    }
}

public struct ToggleCodeBlockCommand: Command {
    public let id = "codeBlock"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func isActive(storage: NSAttributedString, selection: NSRange, controller: EditorController) -> Bool {
        guard storage.length > 0 else { return false }
        let probe = max(0, min(selection.location, storage.length - 1))
        return storage.blockSpec(at: probe)?.isCodeBlock == true
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        // When the cursor sits inside an existing code block, toggle the
        // whole block off in one step — toggling line-by-line would split
        // the block into fenced halves around the cursor's line.
        if storage.length > 0 {
            let probe = max(0, min(selection.location, storage.length - 1))
            if let spec = storage.blockSpec(at: probe), spec.isCodeBlock {
                let blockRange = codeBlockRange(in: storage, around: probe)
                let newSpec = BlockSpec(kind: .paragraph, blockquoteDepth: spec.blockquoteDepth)
                return Transaction(steps: [.setSpec(lineRange: blockRange, newSpec)], label: "Code Block")
            }
        }
        // Empty document: drop a fresh empty code block at the start.
        if storage.length == 0 {
            let block = env.compiler.compile("```\n\n```\n", theme: env.theme)
            return Transaction(steps: [
                .replaceText(range: NSRange(location: 0, length: 0), with: block)
            ], label: "Code Block")
        }
        let ns = storage.string as NSString
        let probe = NSRange(location: max(0, min(selection.location, storage.length - 1)), length: 0)
        let lineRange = ns.paragraphRange(for: probe)
        let endsWithNewline = lineRange.length > 0 &&
            ns.character(at: lineRange.location + lineRange.length - 1) == 0x0A
        let lineContentLength = endsWithNewline ? lineRange.length - 1 : lineRange.length
        // Empty line under cursor: convert it. With no text to "convert",
        // the user's intent is unambiguous.
        if lineContentLength == 0 {
            return transformParagraphs(storage: storage, selection: selection, label: "Code Block") { current in
                BlockSpec(kind: .fencedCode(language: nil), blockquoteDepth: current.blockquoteDepth)
            }
        }
        // Non-empty line: insert a fresh empty code block AFTER the line.
        // The existing prose stays untouched; we land the block flush with
        // the paragraph break so the user sees one new line below the
        // existing text (the empty block body) rather than an extra blank
        // separator before it. Round-tripped markdown keeps a canonical
        // blank line via the serializer.
        let prefix = endsWithNewline ? "" : "\n"
        let block = env.compiler.compile("\(prefix)```\n\n```\n", theme: env.theme)
        let insertAt = NSRange(location: lineRange.location + lineRange.length, length: 0)
        return Transaction(steps: [
            .replaceText(range: insertAt, with: block)
        ], label: "Code Block")
    }
}

/// Expand `index` outward to the contiguous run of code-block characters,
/// snapping to paragraph boundaries on each end so the line range is whole.
private func codeBlockRange(in storage: NSAttributedString, around index: Int) -> NSRange {
    var start = index
    while start > 0, storage.blockSpec(at: start - 1)?.isCodeBlock == true {
        start -= 1
    }
    var end = index
    while end < storage.length, storage.blockSpec(at: end)?.isCodeBlock == true {
        end += 1
    }
    let ns = storage.string as NSString
    let head = ns.paragraphRange(for: NSRange(location: start, length: 0))
    let tailProbe = max(start, end - 1)
    let tail = ns.paragraphRange(for: NSRange(location: tailProbe, length: 0))
    let lo = min(start, head.location)
    let hi = max(end, tail.location + tail.length)
    return NSRange(location: lo, length: hi - lo)
}

public struct InsertHorizontalRuleCommand: Command {
    public let id = "horizontalRule"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        let lineRange = lineRanges.first ?? NSRange(location: 0, length: 0)
        return Transaction(steps: [.setSpec(lineRange: lineRange, BlockSpec(kind: .horizontalRule))], label: "Horizontal Rule")
    }
}

public struct IndentCommand: Command {
    public let id = "indent"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: "Indent") { current in
            BlockSpec(kind: current.kind, blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel + 1)
        }
    }
}

public struct OutdentCommand: Command {
    public let id = "outdent"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        guard storage.length > 0 else { return false }
        let probe = max(0, min(selection.location, storage.length - 1))
        let spec = storage.blockSpec(at: probe) ?? .paragraph
        return spec.listLevel > 0 || spec.blockquoteDepth > 0
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: "Outdent") { current in
            BlockSpec(kind: current.kind, blockquoteDepth: current.blockquoteDepth, listLevel: max(0, current.listLevel - 1))
        }
    }
}
