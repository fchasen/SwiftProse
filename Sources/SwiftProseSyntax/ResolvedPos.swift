import Foundation

/// A position resolved against a `ProseDocument` tree: the chain of
/// structural ancestors from the doc root down to the deepest container
/// holding the position, plus the index inside each parent and the offset
/// within the deepest parent. Mirrors ProseMirror's `ResolvedPos` API,
/// scoped to the surface SwiftProse needs.
///
/// Positions are **storage UTF-16 offsets** for any document produced by
/// `ProseDocument.from(storage:)` — `document.resolve(controller.currentSelection.location)`
/// is exact, with no correction. Three facts make that true:
///
/// - Structural nodes have no open/close tokens. Unlike ProseMirror, where
///   entering a node costs 1 and leaving costs 1, our nodes have openness 0:
///   a position is inside a node iff it falls in its storage span.
/// - Presentation markers — a list bullet glyph and its tab, `"12. "`, a
///   task checkbox — count toward offsets but not toward text. A position
///   inside one resolves to the owning paragraph with `textOffset` 0.
/// - Attachment-backed nodes (today: `table`) are opaque. Their footprint
///   is the attachment glyph; the cell content lives off-buffer and is
///   addressed by `(tableID, row, col)` through `Step.replaceCellInline`,
///   not by offset. `resolve` never descends into one.
///
/// For a hand-built tree (`ProseDocument.make`) positions are offsets into
/// the flattened `project()` output, as before: inline text plus one
/// newline between block-shaped siblings.
public struct ResolvedPos: Sendable, Equatable {

    /// One frame in the ancestor chain — the structural parent, the index
    /// in its `children` array of the child holding the resolved position
    /// (or `parent.childCount` when the position lands at the end), and
    /// the offset where this parent's first child starts in the document.
    public struct Frame: Sendable, Equatable {
        public let node: ProseNode
        public let children: [TreeNode]
        public let indexInParent: Int
        public let startInDoc: Int
    }

    public let pos: Int
    public let frames: [Frame]
    /// Offset relative to the deepest parent's start. For inline positions
    /// this reads as "characters before this point inside the parent".
    public let parentOffset: Int

    public var depth: Int { frames.count - 1 }

    public var parent: ProseNode { frames.last!.node }

    public func parent(at d: Int) -> ProseNode {
        frames[d].node
    }

    /// The node at depth `d` — i.e. the child of `parent(at: d-1)` indexed
    /// by `index(at: d-1)`. `node(at: depth)` returns the deepest parent
    /// itself; `node(at: 0)` returns the doc root.
    public func node(at d: Int) -> ProseNode? {
        guard d >= 0, d <= depth else { return nil }
        return frames[d].node
    }

    public func index(at d: Int) -> Int {
        frames[d].indexInParent
    }

    /// Offset where the d-th parent starts.
    public func start(at d: Int) -> Int {
        frames[d].startInDoc
    }

    /// Offset where the d-th parent ends. Structural nodes have openness 0
    /// in our model, so this is the parent's start plus its span.
    public func end(at d: Int) -> Int {
        let f = frames[d]
        if let span = f.node.layout.storageLength { return f.startInDoc + span }
        return f.startInDoc + contentLength(of: f.children)
    }

    /// Offset just before the node at depth `d+1` — i.e. just before the
    /// child that holds this position at one level shallower. Mirrors
    /// PM's `before(d)`.
    public func before(at d: Int) -> Int? {
        guard d >= 1, d <= depth else { return nil }
        let parentFrame = frames[d - 1]
        let idx = parentFrame.indexInParent
        return parentFrame.startInDoc + offsetOfChildStart(in: parentFrame, upTo: idx)
    }

    /// Offset just after the node at depth `d+1`. Mirrors PM's `after(d)`.
    public func after(at d: Int) -> Int? {
        guard d >= 1, d <= depth else { return nil }
        let parentFrame = frames[d - 1]
        let idx = parentFrame.indexInParent
        let childStart = parentFrame.startInDoc + offsetOfChildStart(in: parentFrame, upTo: idx)
        if idx < parentFrame.children.count {
            return childStart + parentFrame.children[idx].contentLength
        }
        return childStart
    }

    /// Offset within the inline text that contains this position, or 0
    /// when the position falls between block siblings. Mirrors PM's
    /// `textOffset`.
    ///
    /// Clamped into the addressed child: a position inside a presentation
    /// marker reads 0, and one in the trailing gap after a block's text
    /// (its newline, a blank separator line) reads the end of that text.
    public var textOffset: Int {
        let parentFrame = frames.last!
        let idx = parentFrame.indexInParent
        let upToChildren = offsetOfChildStart(in: parentFrame, upTo: idx)
        let raw = parentOffset - upToChildren
        let cap = idx < parentFrame.children.count
            ? parentFrame.children[idx].contentLength
            : contentLength(of: parentFrame.children)
        return Swift.max(0, Swift.min(raw, cap))
    }

    /// Marks active at this position — for inline-content parents, the
    /// marks of the inline run containing the position; otherwise empty.
    public func marks() -> MarkSet {
        let parentFrame = frames.last!
        guard parentFrame.indexInParent < parentFrame.children.count else {
            return MarkSet()
        }
        let child = parentFrame.children[parentFrame.indexInParent]
        return child.marks
    }

    /// Marks shared between this position and `end` if they cross
    /// inline-run boundaries. PM uses this when typing between two
    /// adjacent runs to pick which marks the new text inherits.
    public func marksAcross(_ end: ResolvedPos) -> MarkSet? {
        let here = marks()
        let there = end.marks()
        guard here == there else { return nil }
        return here
    }

    /// Smallest `NodeRange` enclosing `[self, other]` whose parent
    /// satisfies `pred`. Mirrors PM's `blockRange`.
    public func blockRange(
        _ other: ResolvedPos? = nil,
        pred: (ProseNode) -> Bool = { $0.type != "" }
    ) -> NodeRange? {
        let to = other ?? self
        // Walk from this depth upward; at each level check that both
        // positions still resolve into the same parent and that the
        // parent satisfies `pred`.
        var d = depth
        while d > 0 {
            if frames[d].node.id == to.frames[d].node.id, pred(frames[d].node) {
                return NodeRange(
                    parent: frames[d].node,
                    startIndex: frames[d].indexInParent,
                    endIndex: to.frames[d].indexInParent + (to.frames[d].indexInParent == frames[d].indexInParent ? 1 : 0)
                )
            }
            d -= 1
        }
        return nil
    }

    // MARK: helpers

    /// Offset of child `idx`'s start relative to its parent's start: the
    /// parent's presentation prefix, then each earlier child's length plus
    /// any synthesized newline separators.
    private func offsetOfChildStart(in frame: Frame, upTo idx: Int) -> Int {
        let kids = frame.children
        var total = frame.node.layout.presentationPrefix
        for i in 0..<min(idx, kids.count) {
            if i > 0, TreeNode.needsSeparator(before: kids[i]) {
                total += 1
            }
            total += kids[i].contentLength
        }
        if idx > 0, idx < kids.count, TreeNode.needsSeparator(before: kids[idx]) {
            // Count the separator that precedes this child too.
            total += 1
        }
        return total
    }

    private func contentLength(of kids: [TreeNode]) -> Int {
        var total = 0
        for (i, kid) in kids.enumerated() {
            if i > 0, TreeNode.needsSeparator(before: kid) { total += 1 }
            total += kid.contentLength
        }
        return total
    }
}

/// A range of children within a single structural parent. Mirrors
/// ProseMirror's `NodeRange` — used by transforms like `lift`, `wrap`,
/// and `setBlockType` to identify the contiguous block range to operate
/// on.
public struct NodeRange: Sendable, Equatable {
    public let parent: ProseNode
    public let startIndex: Int
    public let endIndex: Int

    public init(parent: ProseNode, startIndex: Int, endIndex: Int) {
        self.parent = parent
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

// MARK: - Resolution against a ProseDocument

public extension ProseDocument {
    /// Resolve `pos` (a content-length offset into this document) into a
    /// `ResolvedPos`. Returns nil for positions outside `[0,
    /// rootContentLength]`.
    func resolve(_ pos: Int) -> ResolvedPos? {
        guard case .structural(let rootNode, let kids) = root else { return nil }
        guard pos >= 0 else { return nil }
        var frames: [ResolvedPos.Frame] = []
        var currentNode = rootNode
        var currentKids = kids
        var currentStart = 0
        var remaining = pos
        while true {
            let (idx, consumed, fellInsideStructural) = locate(
                remaining,
                in: currentKids,
                startingAt: currentNode.layout.presentationPrefix
            )
            frames.append(ResolvedPos.Frame(
                node: currentNode,
                children: currentKids,
                indexInParent: idx,
                startInDoc: currentStart
            ))
            if fellInsideStructural,
               idx < currentKids.count,
               case .structural(let inner, let innerKids) = currentKids[idx] {
                currentNode = inner
                currentKids = innerKids
                currentStart += consumed
                remaining -= consumed
                continue
            }
            return ResolvedPos(pos: pos, frames: frames, parentOffset: pos - currentStart)
        }
    }

    /// Walk `kids` and locate the first child whose offset spans `target`.
    /// Returns the index plus the cumulative offset where that child
    /// starts, and a flag for whether the position lies *inside* a
    /// structural child (so the caller should descend) vs at a boundary
    /// or in an inline run (the caller stops here).
    private func locate(
        _ target: Int,
        in kids: [TreeNode],
        startingAt prefix: Int
    ) -> (index: Int, consumed: Int, fellInsideStructural: Bool) {
        // Presentation markers sit before the first child. A position
        // inside one belongs to this parent at child index 0.
        var consumed = prefix
        if consumed > target { return (0, 0, false) }
        for (i, kid) in kids.enumerated() {
            if i > 0, TreeNode.needsSeparator(before: kid) {
                if consumed + 1 > target { return (i, consumed, false) }
                consumed += 1
            }
            let len = kid.contentLength
            if consumed + len > target {
                let fellInsideStructural: Bool
                switch kid {
                case .structural(let node, _):
                    // Attachment-backed subtrees are opaque: their content
                    // isn't in the buffer, so there is nothing to descend into.
                    fellInsideStructural = !node.layout.isAttachmentBacked
                default:
                    fellInsideStructural = false
                }
                return (i, consumed, fellInsideStructural)
            }
            consumed += len
        }
        return (kids.count, consumed, false)
    }
}
