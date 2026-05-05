import Foundation

/// One node in the in-memory document tree. Structural nodes hold ordered
/// children, leaf nodes are terminal (hr, hard_break, image, etc.), and
/// inline runs hold text plus a `MarkSet`. Inline runs are the only nodes
/// that carry text content; everything else is a structural container or a
/// pointless-leaf marker.
public indirect enum TreeNode: Sendable, Equatable {
    case structural(ProseNode, [TreeNode])
    case leaf(ProseNode)
    case inline(text: String, marks: MarkSet)
}

public extension TreeNode {
    var node: ProseNode? {
        switch self {
        case .structural(let node, _): return node
        case .leaf(let node): return node
        case .inline: return nil
        }
    }

    var children: [TreeNode] {
        if case .structural(_, let kids) = self { return kids }
        return []
    }

    /// Number of UTF-16 code units this subtree contributes to a flattened
    /// `NSAttributedString` projection. Used by callers that want to map
    /// tree positions to storage offsets without doing a full projection.
    var contentLength: Int {
        switch self {
        case .inline(let text, _):
            return (text as NSString).length
        case .leaf:
            return 1
        case .structural(_, let kids):
            // Block-level children are joined by newline, mirroring how
            // `MarkdownAttributedCompiler.appendStyled` writes paragraphs.
            // Inline children concatenate without separators.
            var total = 0
            for (i, child) in kids.enumerated() {
                if i > 0, isBlockLike(child) {
                    total += 1 // newline separator
                }
                total += child.contentLength
            }
            return total
        }
    }

    private func isBlockLike(_ child: TreeNode) -> Bool {
        switch child {
        case .inline: return false
        case .leaf(let node):
            // Inline leaves (hard_break) don't insert paragraph separators.
            return node.type != "hard_break"
        case .structural: return true
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

        case .leaf(let node):
            // Placeholder character. Block-shaped leaves (horizontal_rule,
            // link_reference) emit "\n" so the paragraph carries the leaf
            // attributes. Inline leaves (hard_break) emit U+2028 (line
            // separator) so the surrounding paragraph stays one block.
            let placeholder: String
            switch node.type {
            case "hard_break": placeholder = "\u{2028}"
            default: placeholder = "\n"
            }
            let path = NodePath(ancestors + [node])
            let attrs: [NSAttributedString.Key: Any] = [
                .proseNodePath: NodePathBox(path),
                .proseMarks: MarkSetBox(MarkSet())
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
        case .leaf(let node): return node.type != "hard_break"
        case .structural: return true
        }
    }

    private func hasInlineChildrenOnly(_ kids: [TreeNode]) -> Bool {
        for kid in kids {
            switch kid {
            case .inline: continue
            case .leaf(let node) where node.type == "hard_break": continue
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
        schema: Schema = .defaultMarkdown
    ) -> ProseDocument {
        let total = storage.length
        guard total > 0 else { return .makeEmpty(schema: schema) }

        // The tree builder maintains a stack of (node, accumulated children)
        // matching the deepest open path. For each attribute run we close
        // down to the longest common prefix with the previous path, then
        // open the run's missing ancestors. The doc root is treated as
        // always shared so a freshly-minted target doc still aligns to the
        // existing root.
        let docNode = ProseNode(type: schema.topNodeName, attrs: schema.topNode.defaultAttrs())
        var stack: [(node: ProseNode, kids: [TreeNode])] = [(docNode, [])]
        var openPath: NodePath = NodePath([docNode])

        storage.enumerateNodePaths { blockRange, blockPath in
            // For each `proseNodePath` run, walk the inner `proseMarks`
            // run boundaries so inline children inherit the correct
            // per-character marks. Without this split, the whole block
            // would collapse to one inline run carrying the marks of the
            // first character (e.g. a paragraph starting with bold would
            // serialize as fully bold).
            if let leaf = blockPath.leaf, isLeafType(leaf.type, schema: schema) {
                if isPresentationMarker(in: storage, at: blockRange.location) { return }
                openTo(parent: blockPath.droppingLast(), stack: &stack, openPath: &openPath)
                stack[stack.count - 1].kids.append(.leaf(leaf))
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
                openTo(parent: blockPath, stack: &stack, openPath: &openPath)
            }
            storage.enumerateAttribute(.proseMarks, in: blockRange) { value, runRange, _ in
                guard runRange.length > 0 else { return }
                let marks = (value as? MarkSetBox)?.marks ?? MarkSet()
                let ns = storage.string as NSString
                var accumulated = ""
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
                    accumulated.append(ns.substring(with: NSRange(location: cursor, length: segEnd - cursor)))
                    cursor = segEnd
                }
                let text = stripTrailingNewlines(accumulated)
                if text.isEmpty { return }
                openTo(parent: blockPath, stack: &stack, openPath: &openPath)
                stack[stack.count - 1].kids.append(.inline(text: text, marks: marks))
            }
        }

        // Close any still-open structural nodes back to the doc root.
        while stack.count > 1 {
            popOne(stack: &stack, openPath: &openPath)
        }
        let root: TreeNode = .structural(stack[0].node, stack[0].kids)
        return ProseDocument(schema: schema, root: root)
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
        stack: inout [(node: ProseNode, kids: [TreeNode])],
        openPath: inout NodePath
    ) {
        let common = openCommonDepth(open: openPath, target: target)
        while openPath.depth > common {
            popOne(stack: &stack, openPath: &openPath)
        }
        var i = common
        while i < target.nodes.count {
            let ancestor = target.nodes[i]
            stack.append((ancestor, []))
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
        stack: inout [(node: ProseNode, kids: [TreeNode])],
        openPath: inout NodePath
    ) {
        guard stack.count > 1 else { return }
        let popped = stack.removeLast()
        let folded: TreeNode = .structural(popped.node, popped.kids)
        stack[stack.count - 1].kids.append(folded)
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
