import Foundation

/// One node in the in-memory document tree. Structural nodes hold ordered
/// children, leaf nodes are terminal (hr, hard_break, image, etc.) and may
/// carry inline marks (an image inside a link span keeps its link mark),
/// and inline runs hold text plus a `MarkSet`. Inline runs are the only
/// nodes that carry text content; everything else is a structural
/// container or a pointless-leaf marker.
public indirect enum TreeNode: Sendable, Equatable {
    case structural(ProseNode, [TreeNode])
    case leaf(ProseNode, MarkSet)
    case inline(text: String, marks: MarkSet)

    /// Convenience for callers that don't carry marks on the leaf.
    public static func leaf(_ node: ProseNode) -> TreeNode {
        .leaf(node, MarkSet())
    }
}

public extension TreeNode {
    var node: ProseNode? {
        switch self {
        case .structural(let node, _): return node
        case .leaf(let node, _): return node
        case .inline: return nil
        }
    }

    /// Marks attached to this node, if any. Inline runs and leaves both
    /// can carry marks; structural nodes do not.
    var marks: MarkSet {
        switch self {
        case .leaf(_, let marks): return marks
        case .inline(_, let marks): return marks
        case .structural: return MarkSet()
        }
    }

    var children: [TreeNode] {
        if case .structural(_, let kids) = self { return kids }
        return []
    }

    /// UTF-16 span this subtree occupies.
    ///
    /// For a tree projected by `ProseDocument.from(storage:)` this is the
    /// **storage footprint** — exactly the number of characters the node
    /// covers in the `NSTextStorage`, including presentation markers, the
    /// block's terminating newline, and blank separator lines. That makes
    /// `document.contentLength == textStorage.length` and lets
    /// `document.resolve(_:)` take a raw storage offset.
    ///
    /// For a hand-built tree (no `StorageLayout`) it is the length of the
    /// flattened `project()` output: inline text plus one newline between
    /// block-shaped siblings.
    var contentLength: Int {
        switch self {
        case .inline(let text, _):
            return (text as NSString).length
        case .leaf(let node, _):
            return node.layout.storageLength ?? 1
        case .structural(let node, let kids):
            if let span = node.layout.storageLength { return span }
            var total = 0
            for (i, child) in kids.enumerated() {
                if i > 0, TreeNode.needsSeparator(before: child) {
                    total += 1 // newline separator
                }
                total += child.contentLength
            }
            return total
        }
    }

    /// Whether a synthetic newline separator precedes `child` when summing
    /// sibling lengths. A child that knows its own storage span already
    /// covers its terminator, so no separator is synthesized in front of
    /// it; hand-built block-shaped children still get one.
    static func needsSeparator(before child: TreeNode) -> Bool {
        switch child {
        case .inline: return false
        case .leaf(let node, _):
            // Inline leaves (hard_break) don't insert paragraph separators.
            return node.layout.storageLength == nil && node.type != "hard_break"
        case .structural(let node, _):
            return node.layout.storageLength == nil
        }
    }
}

/// Top-level document — the schema it conforms to plus the tree root.
/// `root` is always a structural node whose type matches `schema.topNodeName`.
public struct ProseDocument: Sendable, Equatable {
    public let schema: Schema
    public let root: TreeNode

    public init(schema: Schema, root: TreeNode) {
        self.schema = schema
        self.root = root
    }

    /// Convenience constructor — wrap children in the schema's top-level
    /// node with a fresh ID.
    public static func makeEmpty(schema: Schema) -> ProseDocument {
        ProseDocument(
            schema: schema,
            root: .structural(
                ProseNode(type: schema.topNodeName, attrs: schema.topNode.defaultAttrs()),
                []
            )
        )
    }

    /// Span of the whole document. For a tree projected from storage this
    /// equals `textStorage.length` exactly.
    public var contentLength: Int { root.contentLength }

    public static func make(
        schema: Schema,
        children: [TreeNode]
    ) -> ProseDocument {
        ProseDocument(
            schema: schema,
            root: .structural(
                ProseNode(type: schema.topNodeName, attrs: schema.topNode.defaultAttrs()),
                children
            )
        )
    }
}

// MARK: - Projection: tree → NSAttributedString

public extension ProseDocument {
    /// Project the tree into an `NSAttributedString`. Each inline run gets a
    /// `proseNodePath` attribute with the chain of structural ancestors and
    /// a `proseMarks` attribute carrying its `MarkSet`. Block-level nodes
    /// emit one paragraph per direct block child (separated by `\n`); leaf
    /// nodes emit a single placeholder character (`\n` for line-shaped
    /// leaves, U+FFFC for object-replacement leaves like images).
    /// Rendering attributes (font, foregroundColor) are not stamped here —
    /// the compiler applies them when projecting marks onto runs.
    func project() -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard case .structural(_, let topChildren) = root else { return result }
        var ctx = ProjectionContext()
        for (i, child) in topChildren.enumerated() {
            if i > 0 { ctx.appendBlockSeparator(into: result) }
            project(child, ancestors: [root.node!], into: result, ctx: &ctx)
        }
        return result
    }

    private struct ProjectionContext {
        mutating func appendBlockSeparator(into result: NSMutableAttributedString) {
            // Block separator is a single newline. The previous run's
            // attributes carry forward to the newline; this matches how the
            // existing compiler already writes "\n" at the end of every
            // block emission.
            if result.length > 0 {
                let attrs = result.attributes(at: result.length - 1, effectiveRange: nil)
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
    }

    private func project(
        _ tree: TreeNode,
        ancestors: [ProseNode],
        into result: NSMutableAttributedString,
        ctx: inout ProjectionContext
    ) {
        switch tree {
        case .inline(let text, let marks):
            guard !text.isEmpty else { return }
            let path = NodePath(ancestors)
            let attrs: [NSAttributedString.Key: Any] = [
                .proseNodePath: NodePathBox(path),
                .proseMarks: MarkSetBox(marks)
            ]
            result.append(NSAttributedString(string: text, attributes: attrs))

        case .leaf(let node, let marks):
            // Block-shaped leaves emit "\n" so the paragraph carries the
            // leaf attributes. Inline leaves whose NodeType opts in via
            // `linebreakReplacement` emit U+2028 so they sit inline.
            let placeholder: String
            if schema.nodeType(node.type)?.linebreakReplacement == true {
                placeholder = "\u{2028}"
            } else {
                placeholder = "\n"
            }
            let path = NodePath(ancestors + [node])
            let attrs: [NSAttributedString.Key: Any] = [
                .proseNodePath: NodePathBox(path),
                .proseMarks: MarkSetBox(marks)
            ]
            result.append(NSAttributedString(string: placeholder, attributes: attrs))

        case .structural(let node, let kids):
            let nextAncestors = ancestors + [node]
            // Block-level children are separated by newlines; inline
            // children are concatenated without separators.
            for (i, child) in kids.enumerated() {
                if i > 0, isBlockLike(child) {
                    ctx.appendBlockSeparator(into: result)
                }
                project(child, ancestors: nextAncestors, into: result, ctx: &ctx)
            }
            // Structural nodes that contain block-level children naturally
            // own a trailing newline by way of the last child's emission;
            // structural nodes that wrap inline content (e.g. paragraph)
            // also append a newline at the end so subsequent siblings start
            // on a fresh line.
            if !kids.isEmpty, hasInlineChildrenOnly(kids), needsTrailingNewlineWhenInlineWrapping(node) {
                let attrs: [NSAttributedString.Key: Any] = [
                    .proseNodePath: NodePathBox(NodePath(nextAncestors)),
                    .proseMarks: MarkSetBox(MarkSet())
                ]
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
    }

    private func isBlockLike(_ child: TreeNode) -> Bool {
        switch child {
        case .inline: return false
        case .leaf(let node, _): return node.type != "hard_break"
        case .structural: return true
        }
    }

    private func hasInlineChildrenOnly(_ kids: [TreeNode]) -> Bool {
        for kid in kids {
            switch kid {
            case .inline: continue
            case .leaf(let node, _) where node.type == "hard_break": continue
            default: return false
            }
        }
        return true
    }

    private func needsTrailingNewlineWhenInlineWrapping(_ node: ProseNode) -> Bool {
        // Inline-content blocks (paragraph, heading) always want a closing
        // newline so the next paragraph starts on a fresh line. Code blocks
        // also do; tables and similar are children-of-block and don't
        // wrap inline content directly.
        switch node.type {
        case "paragraph", "heading", "code_block", "html_block":
            return true
        default:
            return false
        }
    }
}

// MARK: - Reverse projection: NSAttributedString → tree

public extension ProseDocument {
    /// Reconstruct a `ProseDocument` from an `NSAttributedString` by walking
    /// `proseNodePath` runs. Each run's path identifies the chain of
    /// structural ancestors; consecutive runs sharing a prefix collapse
    /// into shared ancestors. Runs without `proseNodePath` are skipped.
    static func from(
        storage: NSAttributedString,
        range: NSRange? = nil,
        schema: Schema = .defaultMarkdown
    ) -> ProseDocument {
        let total = storage.length
        // PM has no empty document — `doc` is `block+`, and a fresh state
        // fills it with one empty paragraph. An empty buffer projects the
        // same way, so the schema validator sees a legal tree.
        guard total > 0 else {
            return ProseDocument(
                schema: schema,
                root: .structural(
                    schema.topNode.create(),
                    [.structural(ProseNode(type: "paragraph"), [])]
                )
            )
        }
        let scanRange: NSRange = {
            guard let r = range else { return NSRange(location: 0, length: total) }
            let lo = max(0, r.location)
            let hi = min(total, r.location + r.length)
            return NSRange(location: lo, length: max(0, hi - lo))
        }()
        guard scanRange.length > 0 else { return .makeEmpty(schema: schema) }

        // The tree builder maintains a stack of (node, accumulated children)
        // matching the deepest open path. For each attribute run we close
        // down to the longest common prefix with the previous path, then
        // open the run's missing ancestors. The doc root is treated as
        // always shared so a freshly-minted target doc still aligns to the
        // existing root.
        //
        // Alongside the tree, `starts` mirrors it with the storage offset
        // where each node begins. A second pass turns those into exact
        // spans (`StorageLayout.storageLength`) — a node ends where its
        // next sibling starts, which is what makes blank separator lines
        // and dropped runs land inside the block that precedes them.
        let docNode = ProseNode(type: schema.topNodeName, attrs: schema.topNode.defaultAttrs())
        let rootStarts = StartNode(start: scanRange.location)
        var stack: [(node: ProseNode, kids: [TreeNode], starts: StartNode)] = [(docNode, [], rootStarts)]
        var openPath: NodePath = NodePath([docNode])

        storage.enumerateNodePaths(in: scanRange) { blockRange, blockPath in
            // For each `proseNodePath` run, walk the inner `proseMarks`
            // run boundaries so inline children inherit the correct
            // per-character marks. Without this split, the whole block
            // would collapse to one inline run carrying the marks of the
            // first character (e.g. a paragraph starting with bold would
            // serialize as fully bold).
            if let leaf = blockPath.leaf, isLeafType(leaf.type, schema: schema) {
                // Don't gate this on `isPresentationMarker` — a true
                // content-bearing leaf (today: `horizontal_rule`) is
                // stored as an `\u{FFFC}` carrying its attachment, and
                // the attachment marker would cause the leaf to be
                // dropped from the tree. The list-marker / inline-chip
                // call sites below still consult `isPresentationMarker`
                // because they're skipping chars during text aggregation,
                // not skipping leaf appends.
                openTo(parent: blockPath.droppingLast(), at: blockRange.location, stack: &stack, openPath: &openPath)
                let marks = storage.markSet(at: blockRange.location) ?? MarkSet()
                append(.leaf(leaf, marks), startingAt: blockRange.location, to: &stack)
                return
            }
            // When the leaf is an `isolating`-flagged structural node
            // (today: `table`), look for a `ProseSubtreeAttachment` at
            // the run start and lift its subtree's children into the
            // tree at this position. Storage stops at the isolating
            // leaf — the attachment supplies the children.
            if let leaf = blockPath.leaf,
               schema.nodeType(leaf.type)?.isolating == true,
               let attachment = subtreeAttachment(in: storage, at: blockRange.location) {
                openTo(parent: blockPath.droppingLast(), at: blockRange.location, stack: &stack, openPath: &openPath)
                var lifted = leaf
                lifted.layout.isAttachmentBacked = true
                if case .structural(_, let kids) = attachment.subtree {
                    append(.structural(lifted, kids), startingAt: blockRange.location, to: &stack)
                } else {
                    append(.structural(lifted, []), startingAt: blockRange.location, to: &stack)
                }
                return
            }
            // Open the structural ancestors for this block even when it
            // has no inline content (e.g. an empty bullet line — `- \n`
            // — or a heading whose body got deleted). Skip pure-whitespace
            // top-level paragraphs so blank-line gaps between blocks don't
            // surface as empty paragraph nodes that round-trip back as
            // extra newlines.
            //
            // Paragraphs whose path crosses an `isolating`-flagged ancestor
            // (today: `table` cells) always open their ancestors — empty
            // cells would otherwise be lost on the round-trip.
            let leafType = blockPath.leaf?.type ?? ""
            let hasIsolatingAncestor = blockPath.nodes.dropLast().contains { node in
                schema.nodeType(node.type)?.isolating == true
            }
            let openEvenWhenEmpty = leafType != "paragraph"
                || hasIsolatingAncestor
                || rangeHasPresentationMarker(in: storage, range: blockRange)
            if openEvenWhenEmpty {
                openTo(parent: blockPath, at: blockRange.location, stack: &stack, openPath: &openPath)
            }
            storage.enumerateAttribute(.proseMarks, in: blockRange) { value, runRange, _ in
                guard runRange.length > 0 else { return }
                let marks = (value as? MarkSetBox)?.marks ?? MarkSet()
                let ns = storage.string as NSString
                var accumulated = ""
                var firstRetained: Int?
                var cursor = runRange.location
                let runEnd = runRange.location + runRange.length
                while cursor < runEnd {
                    if isPresentationMarker(in: storage, at: cursor) {
                        cursor += 1
                        continue
                    }
                    var segEnd = cursor + 1
                    while segEnd < runEnd,
                          !isPresentationMarker(in: storage, at: segEnd) {
                        segEnd += 1
                    }
                    if firstRetained == nil { firstRetained = cursor }
                    accumulated.append(ns.substring(with: NSRange(location: cursor, length: segEnd - cursor)))
                    cursor = segEnd
                }
                let text = stripTrailingNewlines(accumulated)
                if text.isEmpty { return }
                openTo(parent: blockPath, at: blockRange.location, stack: &stack, openPath: &openPath)
                append(
                    .inline(text: text, marks: marks),
                    startingAt: firstRetained ?? runRange.location,
                    to: &stack
                )
            }
        }

        // Close any still-open structural nodes back to the doc root.
        while stack.count > 1 {
            popOne(stack: &stack, openPath: &openPath)
        }
        let raw: TreeNode = .structural(stack[0].node, stack[0].kids)
        let scanEnd = scanRange.location + scanRange.length
        let root = stampLayout(raw, starts: rootStarts, end: scanEnd)
        return ProseDocument(schema: schema, root: root)
    }

    /// Mirror of the tree under construction, holding the storage offset
    /// where each node begins. A class so a frame can hand its node to its
    /// parent before the frame's own children are complete.
    private final class StartNode {
        let start: Int
        var kids: [StartNode] = []
        init(start: Int) { self.start = start }
    }

    private static func append(
        _ node: TreeNode,
        startingAt start: Int,
        to stack: inout [(node: ProseNode, kids: [TreeNode], starts: StartNode)]
    ) {
        let top = stack.count - 1
        stack[top].kids.append(node)
        stack[top].starts.kids.append(StartNode(start: start))
    }

    /// Second pass: turn recorded starts into exact spans. A node ends
    /// where its next sibling starts (or where its parent ends), so runs
    /// the first pass dropped — blank separator lines, empty paragraphs,
    /// the trailing paragraph after an atomic block — are absorbed by the
    /// block that precedes them instead of vanishing from the offset space.
    private static func stampLayout(_ node: TreeNode, starts: StartNode, end: Int) -> TreeNode {
        switch node {
        case .inline:
            return node
        case .leaf(let n, let marks):
            var stamped = n
            stamped.layout.storageLength = max(0, end - starts.start)
            return .leaf(stamped, marks)
        case .structural(let n, let kids):
            var stamped = n
            stamped.layout.storageLength = max(0, end - starts.start)
            if n.layout.isAttachmentBacked {
                // Cell content lives off-buffer; its children keep the
                // projection-length semantics.
                return .structural(stamped, kids)
            }
            stamped.layout.presentationPrefix = max(0, (starts.kids.first?.start ?? starts.start) - starts.start)
            var newKids: [TreeNode] = []
            newKids.reserveCapacity(kids.count)
            for (i, kid) in kids.enumerated() {
                guard i < starts.kids.count else {
                    newKids.append(kid)
                    continue
                }
                let kidEnd = (i + 1 < starts.kids.count) ? starts.kids[i + 1].start : end
                newKids.append(stampLayout(kid, starts: starts.kids[i], end: kidEnd))
            }
            return .structural(stamped, newKids)
        }
    }

    private static func isLeafType(_ name: NodeType.Name, schema: Schema) -> Bool {
        schema.nodeType(name)?.isLeaf ?? false
    }

    /// Reshape the open stack so it matches `target` exactly: pop nodes the
    /// target doesn't share, push the ones it does. After this call,
    /// `stack.count == target.nodes.count` and `openPath == target` modulo
    /// the doc-root id substitution (the persistent doc root keeps its
    /// original id, but downstream nodes match `target` by id).
    private static func openTo(
        parent target: NodePath,
        at start: Int,
        stack: inout [(node: ProseNode, kids: [TreeNode], starts: StartNode)],
        openPath: inout NodePath
    ) {
        let common = openCommonDepth(open: openPath, target: target)
        while openPath.depth > common {
            popOne(stack: &stack, openPath: &openPath)
        }
        var i = common
        while i < target.nodes.count {
            let ancestor = target.nodes[i]
            let starts = StartNode(start: start)
            stack[stack.count - 1].starts.kids.append(starts)
            stack.append((ancestor, [], starts))
            openPath = openPath.appending(ancestor)
            i += 1
        }
    }

    /// How many levels are shared between `open` and `target`. The doc
    /// root (depth 0) is always treated as shared so a freshly-minted
    /// target doc id doesn't reset the prefix to zero. Comparison from
    /// depth 1 upward is by `NodeID`.
    private static func openCommonDepth(open: NodePath, target: NodePath) -> Int {
        guard !open.nodes.isEmpty, !target.nodes.isEmpty else { return 0 }
        var i = 1
        let cap = Swift.min(open.nodes.count, target.nodes.count)
        while i < cap, open.nodes[i].id == target.nodes[i].id {
            i += 1
        }
        return i
    }

    private static func popOne(
        stack: inout [(node: ProseNode, kids: [TreeNode], starts: StartNode)],
        openPath: inout NodePath
    ) {
        guard stack.count > 1 else { return }
        let popped = stack.removeLast()
        // The frame's `starts` node was already attached to its parent when
        // the frame opened, so only the tree side needs folding here.
        stack[stack.count - 1].kids.append(.structural(popped.node, popped.kids))
        openPath = openPath.droppingLast()
    }

    private static func rangeHasPresentationMarker(
        in storage: NSAttributedString,
        range: NSRange
    ) -> Bool {
        let end = range.location + range.length
        var i = range.location
        while i < end {
            if isPresentationMarker(in: storage, at: i) { return true }
            i += 1
        }
        return false
    }

    private static func subtreeAttachment(
        in storage: NSAttributedString,
        at location: Int
    ) -> ProseSubtreeAttachment? {
        guard location >= 0, location < storage.length else { return nil }
        let raw = storage.attribute(
            NSAttributedString.Key("NSAttachment"),
            at: location,
            effectiveRange: nil
        )
        return raw as? ProseSubtreeAttachment
    }

    private static func isPresentationMarker(
        in storage: NSAttributedString,
        at location: Int
    ) -> Bool {
        guard location >= 0, location < storage.length else { return false }
        if let flag = storage.attribute(.proseListMarker, at: location, effectiveRange: nil) as? Bool, flag {
            return true
        }
        // `.attachment` is defined by AppKit/UIKit, not the base Foundation
        // module that owns `NSAttributedString.Key` — string-key probe
        // avoids the platform-conditional import here in SwiftProseSyntax.
        if storage.attribute(NSAttributedString.Key("NSAttachment"), at: location, effectiveRange: nil) != nil {
            return true
        }
        return false
    }

    private static func stripTrailingNewlines(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev] == "\n" { end = prev } else { break }
        }
        return String(s[..<end])
    }
}
