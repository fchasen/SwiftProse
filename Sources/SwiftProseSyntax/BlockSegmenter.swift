import Foundation
import SwiftTreeSitter

public struct BlockSegment: Equatable, Sendable {
    public let range: NSRange
    public let tag: BlockTag
    public let level: Int
    public let blockquoteDepth: Int
    public let language: String?
    public let listLevel: Int
    public let orderedIndex: Int?
    public let isChecked: Bool?
    public let firstInListItem: Bool

    public init(
        range: NSRange,
        tag: BlockTag,
        level: Int = 0,
        blockquoteDepth: Int = 0,
        language: String? = nil,
        listLevel: Int = 0,
        orderedIndex: Int? = nil,
        isChecked: Bool? = nil,
        firstInListItem: Bool = false
    ) {
        self.range = range
        self.tag = tag
        self.level = level
        self.blockquoteDepth = blockquoteDepth
        self.language = language
        self.listLevel = listLevel
        self.orderedIndex = orderedIndex
        self.isChecked = isChecked
        self.firstInListItem = firstInListItem
    }
}

public enum BlockSegmenter {
    public static func segment(rootNode: Node, mapping: TreeSitterMapping) -> [BlockSegment] {
        var ctx = Context(mapping: mapping)
        walk(rootNode, ctx: &ctx)
        return ctx.out
    }

    private struct Context {
        var out: [BlockSegment] = []
        let mapping: TreeSitterMapping
        var blockquoteDepth: Int = 0
        var listLevel: Int = 0
        var pendingOrderedIndex: Int?
        var pendingTaskChecked: Bool?
        var pendingFirstInListItem: Bool = false
        var pendingListItemKind: ListItemKind?
    }

    private static func walk(_ node: Node, ctx: inout Context) {
        let type = node.nodeType ?? ""

        switch type {
        case "atx_heading":
            emit(node, tag: .heading, level: atxLevel(of: node), ctx: &ctx)
        case "setext_heading":
            emit(node, tag: .heading, level: setextLevel(of: node), ctx: &ctx)
        case "paragraph":
            // A paragraph inside a list_item produces a list-item segment;
            // outside, an ordinary paragraph.
            if let kind = ctx.pendingListItemKind {
                emit(
                    node,
                    tag: tag(forListKind: kind),
                    listLevel: ctx.listLevel - 1,
                    orderedIndex: ctx.pendingOrderedIndex,
                    isChecked: ctx.pendingTaskChecked,
                    firstInListItem: ctx.pendingFirstInListItem,
                    ctx: &ctx
                )
                ctx.pendingFirstInListItem = false
                // After the first content block, subsequent paragraphs in the
                // same item are continuations; clear the "first" flag.
            } else {
                emit(node, tag: .paragraph, ctx: &ctx)
            }
        case "fenced_code_block":
            let lang = fencedLanguage(of: node, mapping: ctx.mapping)
            emit(node, tag: .fencedCode, language: lang, ctx: &ctx)
        case "indented_code_block":
            emit(node, tag: .indentedCode, ctx: &ctx)
        case "thematic_break":
            emit(node, tag: .horizontalRule, ctx: &ctx)
        case "html_block":
            emit(node, tag: .htmlBlock, ctx: &ctx)
        case "link_reference_definition":
            emit(node, tag: .linkReferenceDefinition, ctx: &ctx)
        case "pipe_table":
            emit(node, tag: .pipeTable, ctx: &ctx)
        case "block_quote":
            ctx.blockquoteDepth += 1
            for i in 0..<node.childCount {
                if let c = node.child(at: i) { walk(c, ctx: &ctx) }
            }
            ctx.blockquoteDepth -= 1
        case "list":
            walkList(node, ctx: &ctx)
        case "list_item":
            walkListItem(node, ctx: &ctx)
        default:
            for i in 0..<node.childCount {
                if let c = node.child(at: i) { walk(c, ctx: &ctx) }
            }
        }
    }

    private static func walkList(_ node: Node, ctx: inout Context) {
        let kind = listKind(of: node)
        ctx.listLevel += 1
        var orderedCounter = 1
        for i in 0..<node.childCount {
            guard let item = node.child(at: i), item.nodeType == "list_item" else { continue }
            let prevIndex = ctx.pendingOrderedIndex
            let prevKind = ctx.pendingListItemKind
            let prevChecked = ctx.pendingTaskChecked
            let prevFirst = ctx.pendingFirstInListItem
            ctx.pendingListItemKind = kind
            ctx.pendingOrderedIndex = (kind == .ordered) ? orderedCounter : nil
            ctx.pendingTaskChecked = (kind == .task) ? taskChecked(of: item) : nil
            ctx.pendingFirstInListItem = true
            walkListItem(item, ctx: &ctx)
            ctx.pendingOrderedIndex = prevIndex
            ctx.pendingListItemKind = prevKind
            ctx.pendingTaskChecked = prevChecked
            ctx.pendingFirstInListItem = prevFirst
            orderedCounter += 1
        }
        ctx.listLevel -= 1
    }

    private static func walkListItem(_ node: Node, ctx: inout Context) {
        // Recurse into children — paragraphs become list-item segments via
        // the .pendingListItemKind context; nested lists, code blocks, etc.
        // are emitted normally.
        for i in 0..<node.childCount {
            guard let c = node.child(at: i), let t = c.nodeType else { continue }
            if t == "list_marker_minus" || t == "list_marker_plus"
                || t == "list_marker_star" || t == "list_marker_dot"
                || t == "list_marker_parenthesis" {
                continue
            }
            if t.hasPrefix("task_list_marker_") { continue }
            walk(c, ctx: &ctx)
        }
    }

    private static func emit(
        _ node: Node,
        tag: BlockTag,
        level: Int = 0,
        language: String? = nil,
        listLevel: Int = 0,
        orderedIndex: Int? = nil,
        isChecked: Bool? = nil,
        firstInListItem: Bool = false,
        ctx: inout Context
    ) {
        let nodeRange = nsRange(of: node, mapping: ctx.mapping)
        // Expand to the source line(s) the node covers, so leading markers
        // (`>`, `-`, `1.`, indentation) fall inside the segment and the
        // compiler can strip them via the highlight applier output rather
        // than dumping them between segments as untagged characters.
        let r = lineExpanded(nodeRange, in: ctx.mapping.text)
        ctx.out.append(BlockSegment(
            range: r,
            tag: tag,
            level: level,
            blockquoteDepth: ctx.blockquoteDepth,
            language: language,
            listLevel: listLevel,
            orderedIndex: orderedIndex,
            isChecked: isChecked,
            firstInListItem: firstInListItem
        ))
    }

    private static func nsRange(of node: Node, mapping: TreeSitterMapping) -> NSRange {
        let bytes = node.byteRange
        let lo = mapping.utf16Offset(forByte: bytes.lowerBound)
        let hi = mapping.utf16Offset(forByte: bytes.upperBound)
        return NSRange(location: lo, length: hi - lo)
    }

    private static func lineExpanded(_ range: NSRange, in source: String) -> NSRange {
        let ns = source as NSString
        let safe = NSRange(
            location: max(0, min(range.location, ns.length)),
            length: max(0, min(range.length, ns.length - max(0, min(range.location, ns.length))))
        )
        return ns.lineRange(for: safe)
    }

    // MARK: - sniffing helpers (mirror BlockClassifier private helpers)

    private static func atxLevel(of node: Node) -> Int {
        for i in 0..<node.childCount {
            guard let c = node.child(at: i), let t = c.nodeType else { continue }
            if t.hasPrefix("atx_h"), t.hasSuffix("_marker") {
                let mid = t.dropFirst("atx_h".count).dropLast("_marker".count)
                if let level = Int(mid) { return level }
            }
        }
        return 1
    }

    private static func setextLevel(of node: Node) -> Int {
        for i in 0..<node.childCount {
            guard let c = node.child(at: i), let t = c.nodeType else { continue }
            if t == "setext_h1_underline" { return 1 }
            if t == "setext_h2_underline" { return 2 }
        }
        return 1
    }

    private static func fencedLanguage(of node: Node, mapping: TreeSitterMapping) -> String? {
        for i in 0..<node.childCount {
            guard let c = node.child(at: i), c.nodeType == "info_string" else { continue }
            for j in 0..<c.childCount {
                guard let lang = c.child(at: j), lang.nodeType == "language" else { continue }
                let bytes = lang.byteRange
                let lo = mapping.utf16Offset(forByte: bytes.lowerBound)
                let hi = mapping.utf16Offset(forByte: bytes.upperBound)
                let ns = mapping.text as NSString
                let s = ns.substring(with: NSRange(location: lo, length: hi - lo))
                return s.isEmpty ? nil : s
            }
        }
        return nil
    }

    private static func listKind(of node: Node) -> ListItemKind {
        var sawTask = false
        var sawOrdered = false
        for i in 0..<node.childCount {
            guard let item = node.child(at: i), item.nodeType == "list_item" else { continue }
            for j in 0..<item.childCount {
                guard let inner = item.child(at: j), let t = inner.nodeType else { continue }
                if t.hasPrefix("task_list_marker_") { sawTask = true }
                if t == "list_marker_dot" || t == "list_marker_parenthesis" { sawOrdered = true }
            }
        }
        if sawTask { return .task }
        if sawOrdered { return .ordered }
        return .bullet
    }

    private static func taskChecked(of item: Node) -> Bool {
        for j in 0..<item.childCount {
            guard let inner = item.child(at: j), let t = inner.nodeType else { continue }
            if t == "task_list_marker_checked" { return true }
            if t == "task_list_marker_unchecked" { return false }
        }
        return false
    }

    private static func tag(forListKind kind: ListItemKind) -> BlockTag {
        switch kind {
        case .bullet: return .unorderedListItem
        case .ordered: return .orderedListItem
        case .task: return .taskListItem
        }
    }
}
