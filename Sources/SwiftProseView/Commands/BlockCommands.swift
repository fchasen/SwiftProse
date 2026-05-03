import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct SetHeadingCommand: Command {
    public let level: Int
    public var id: String { "heading:\(level)" }
    public init(level: Int) { self.level = level }

    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }

    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        var steps: [Step] = []
        for lineRange in lineRanges {
            let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let newSpec: BlockSpec
            if level == 0 {
                newSpec = BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            } else {
                newSpec = BlockSpec(kind: .heading(level: level), blockquoteDepth: current.blockquoteDepth)
            }
            steps.append(.setSpec(lineRange: lineRange, newSpec))
        }
        return Transaction(steps: steps, label: level == 0 ? "Paragraph" : "Heading \(level)")
    }
}

public struct ToggleUnorderedListCommand: Command {
    public let id = "unorderedList"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        var steps: [Step] = []
        for lineRange in lineRanges {
            let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let newSpec: BlockSpec
            if case .unorderedListItem = current.kind {
                newSpec = BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            } else {
                newSpec = BlockSpec(kind: .unorderedListItem, blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel)
            }
            steps.append(.setSpec(lineRange: lineRange, newSpec))
        }
        return Transaction(steps: steps, label: "Bullet List")
    }
}

public struct ToggleOrderedListCommand: Command {
    public let id = "orderedList"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        var steps: [Step] = []
        for lineRange in lineRanges {
            let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let newSpec: BlockSpec
            if case .orderedListItem = current.kind {
                newSpec = BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            } else {
                newSpec = BlockSpec(kind: .orderedListItem(index: 1), blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel)
            }
            steps.append(.setSpec(lineRange: lineRange, newSpec))
        }
        return Transaction(steps: steps, label: "Ordered List")
    }
}

public struct ToggleTaskListCommand: Command {
    public let id = "taskList"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        var steps: [Step] = []
        for lineRange in lineRanges {
            let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let newSpec: BlockSpec
            if case .taskListItem = current.kind {
                newSpec = BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            } else {
                newSpec = BlockSpec(kind: .taskListItem(checked: false), blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel)
            }
            steps.append(.setSpec(lineRange: lineRange, newSpec))
        }
        return Transaction(steps: steps, label: "Task List")
    }
}

public struct ToggleBlockquoteCommand: Command {
    public let id = "blockquote"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        var steps: [Step] = []
        for lineRange in lineRanges {
            let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let nextDepth = current.blockquoteDepth > 0 ? current.blockquoteDepth - 1 : current.blockquoteDepth + 1
            let newSpec = BlockSpec(kind: current.kind, blockquoteDepth: nextDepth, listLevel: current.listLevel)
            steps.append(.setSpec(lineRange: lineRange, newSpec))
        }
        return Transaction(steps: steps, label: "Blockquote")
    }
}

public struct ToggleCodeBlockCommand: Command {
    public let id = "codeBlock"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        var steps: [Step] = []
        for lineRange in lineRanges {
            let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let newSpec: BlockSpec
            if case .fencedCode = current.kind {
                newSpec = BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            } else {
                newSpec = BlockSpec(kind: .fencedCode(language: nil), blockquoteDepth: current.blockquoteDepth)
            }
            steps.append(.setSpec(lineRange: lineRange, newSpec))
        }
        return Transaction(steps: steps, label: "Code Block")
    }
}

public struct InsertHorizontalRuleCommand: Command {
    public let id = "horizontalRule"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        guard let lineRange = lineRanges.first else { return nil }
        return Transaction(steps: [.setSpec(lineRange: lineRange, BlockSpec(kind: .horizontalRule))], label: "Horizontal Rule")
    }
}

public struct IndentCommand: Command {
    public let id = "indent"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        var steps: [Step] = []
        for lineRange in lineRanges {
            let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let newSpec = BlockSpec(kind: current.kind, blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel + 1)
            steps.append(.setSpec(lineRange: lineRange, newSpec))
        }
        return Transaction(steps: steps, label: "Indent")
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
        let lineRanges = Operations.paragraphRanges(in: storage, covering: selection)
        var steps: [Step] = []
        for lineRange in lineRanges {
            let current = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let newSpec = BlockSpec(kind: current.kind, blockquoteDepth: current.blockquoteDepth, listLevel: max(0, current.listLevel - 1))
            steps.append(.setSpec(lineRange: lineRange, newSpec))
        }
        return Transaction(steps: steps, label: "Outdent")
    }
}
