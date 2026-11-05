import Foundation
import Synchronization

public struct GroupToken: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func mint() -> GroupToken {
        GroupToken(rawValue: groupTokenCounter.wrappingAdd(1, ordering: .relaxed).newValue)
    }

    public var description: String { "g\(rawValue)" }
}

private let groupTokenCounter = Atomic<UInt64>(0)

public enum TaskState: Hashable, Sendable {
    case unchecked
    case checked

    public var isChecked: Bool { self == .checked }

    public init(checked: Bool) {
        self = checked ? .checked : .unchecked
    }
}

public final class MarkdownBlock: NSObject, Sendable {
    public enum Leaf: Hashable, Sendable {
        case paragraph
        case heading(level: Int)
        case code(language: String?, group: GroupToken)
        case thematicBreak
        case tableRow(group: GroupToken, alignments: [TableColumnAlignment], isHeader: Bool)
        case html
    }

    public enum Container: Hashable, Sendable {
        case quote(GroupToken)
        case listItem
    }

    public let leaf: Leaf
    public let containers: [Container]
    public let isContinuation: Bool
    public let task: TaskState?

    public init(
        leaf: Leaf = .paragraph,
        containers: [Container] = [],
        isContinuation: Bool = false,
        task: TaskState? = nil
    ) {
        if case .heading(let level) = leaf {
            self.leaf = .heading(level: max(1, min(6, level)))
        } else {
            self.leaf = leaf
        }
        self.containers = containers
        self.isContinuation = isContinuation
        self.task = task
        super.init()
    }

    public static let paragraph = MarkdownBlock()

    public func with(leaf: Leaf) -> MarkdownBlock {
        MarkdownBlock(leaf: leaf, containers: containers, isContinuation: isContinuation, task: task)
    }

    public func with(containers: [Container]) -> MarkdownBlock {
        MarkdownBlock(leaf: leaf, containers: containers, isContinuation: isContinuation, task: task)
    }

    public func with(isContinuation: Bool) -> MarkdownBlock {
        MarkdownBlock(leaf: leaf, containers: containers, isContinuation: isContinuation, task: task)
    }

    public func with(task: TaskState?) -> MarkdownBlock {
        MarkdownBlock(leaf: leaf, containers: containers, isContinuation: isContinuation, task: task)
    }

    public var isCode: Bool {
        if case .code = leaf { return true }
        return false
    }

    public var codeGroup: GroupToken? {
        if case .code(_, let group) = leaf { return group }
        return nil
    }

    public var codeLanguage: String? {
        if case .code(let language, _) = leaf { return language }
        return nil
    }

    public var headingLevel: Int? {
        if case .heading(let level) = leaf { return level }
        return nil
    }

    public var isAtom: Bool {
        switch leaf {
        case .thematicBreak, .html: return true
        case .paragraph, .heading, .code, .tableRow: return false
        }
    }

    public var isTableRow: Bool {
        if case .tableRow = leaf { return true }
        return false
    }

    public var tableGroup: GroupToken? {
        if case .tableRow(let group, _, _) = leaf { return group }
        return nil
    }

    public var tableAlignments: [TableColumnAlignment] {
        if case .tableRow(_, let alignments, _) = leaf { return alignments }
        return []
    }

    public var isTableHeader: Bool {
        if case .tableRow(_, _, let isHeader) = leaf { return isHeader }
        return false
    }

    package var excludesBlockFormatting: Bool { isAtom || isTableRow }

    public var listDepth: Int {
        containers.reduce(0) { $1 == .listItem ? $0 + 1 : $0 }
    }

    public var isListItem: Bool { listDepth > 0 }

    public var isListItemStart: Bool { isListItem && !isContinuation }

    public var quoteTokens: [GroupToken] {
        containers.compactMap {
            if case .quote(let token) = $0 { return token }
            return nil
        }
    }

    public var isInQuote: Bool { !quoteTokens.isEmpty }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownBlock else { return false }
        if other === self { return true }
        return leaf == other.leaf
            && containers == other.containers
            && isContinuation == other.isContinuation
            && task == other.task
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(leaf)
        hasher.combine(containers)
        hasher.combine(isContinuation)
        hasher.combine(task)
        return hasher.finalize()
    }

    public override var description: String {
        var parts = ["\(leaf)"]
        if !containers.isEmpty { parts.append("containers: \(containers)") }
        if isContinuation { parts.append("continuation") }
        if let task { parts.append("task: \(task)") }
        return "MarkdownBlock(\(parts.joined(separator: ", ")))"
    }
}
