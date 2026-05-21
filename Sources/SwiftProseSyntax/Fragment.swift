import Foundation

/// Ordered list of sibling `TreeNode`s. Mirrors ProseMirror's `Fragment`
/// — a value-typed view over a node's children that supports cuts,
/// replacements, and concatenation without rebuilding the parent.
///
/// `Fragment` and `[TreeNode]` are kept distinct so APIs that hand around a
/// "subset of children" don't blur into "a full structural node's content."
public struct Fragment: Sendable, Equatable {

    public let children: [TreeNode]

    public init(_ children: [TreeNode] = []) {
        self.children = children
    }

    public static let empty = Fragment([])

    public var isEmpty: Bool { children.isEmpty }
    public var childCount: Int { children.count }
    public var firstChild: TreeNode? { children.first }
    public var lastChild: TreeNode? { children.last }

    public func child(at index: Int) -> TreeNode? {
        guard index >= 0, index < children.count else { return nil }
        return children[index]
    }

    /// Total content-length of this fragment, mirroring `TreeNode.contentLength`
    /// — `\n` separators between block-shaped siblings, inline runs concatenated.
    public var size: Int {
        var total = 0
        for (i, kid) in children.enumerated() {
            if i > 0, isBlockLike(kid) { total += 1 }
            total += kid.contentLength
        }
        return total
    }

    /// Append a node at the end.
    public func appending(_ node: TreeNode) -> Fragment {
        Fragment(children + [node])
    }

    /// Append another fragment's children to this one.
    public func appending(contentsOf other: Fragment) -> Fragment {
        Fragment(children + other.children)
    }

    /// Replace the child at `index`. Out-of-range returns the receiver
    /// unchanged.
    public func replacingChild(at index: Int, with replacement: TreeNode) -> Fragment {
        guard index >= 0, index < children.count else { return self }
        var copy = children
        copy[index] = replacement
        return Fragment(copy)
    }

    /// Drop children outside `[from, to]` (child indices, not content
    /// offsets). Clamped to the valid range.
    public func cut(from: Int, to: Int? = nil) -> Fragment {
        let upper = to ?? children.count
        let lo = max(0, min(from, children.count))
        let hi = max(lo, min(upper, children.count))
        return Fragment(Array(children[lo..<hi]))
    }

    private func isBlockLike(_ child: TreeNode) -> Bool {
        switch child {
        case .inline: return false
        case .leaf(let node, _): return node.type != "hard_break"
        case .structural: return true
        }
    }
}
