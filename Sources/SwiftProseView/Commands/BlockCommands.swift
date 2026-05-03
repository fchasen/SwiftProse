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
}

public struct ToggleCodeBlockCommand: Command {
    public let id = "codeBlock"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        transformParagraphs(storage: storage, selection: selection, label: "Code Block") { current in
            if case .fencedCode = current.kind {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .fencedCode(language: nil), blockquoteDepth: current.blockquoteDepth)
        }
    }
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
