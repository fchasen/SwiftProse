import Foundation
import SwiftProseSyntax

/// Higher-level transform vocabulary mirroring ProseMirror's `Transform`
/// helpers. Each function builds (or probes for) `Step`s that drive a
/// structural edit through the editor's typed primitives. Commands that
/// want PM-shaped behavior — `lift`, `wrap`, `splitBlock`, `joinBackward`,
/// `setBlockType` — should compose these helpers rather than reaching for
/// `setSpec`-via-markdown.
///
/// The probes (`liftTarget`, `findWrapping`, `canSplit`, `canJoin`) return
/// nil when the operation isn't legal at the supplied position; commands
/// that depend on them surface the predicate as their `isApplicable` check.
public enum Transforms {

    // MARK: - Probes

    /// Depth to which `range` may be lifted out of its parent. Returns
    /// the *target depth* — i.e. the ancestor to lift the range into —
    /// or nil when no surrounding ancestor exists or the lift would
    /// violate the parent's content rule. Mirrors PM's `liftTarget`.
    public static func liftTarget(
        _ range: NodeRange,
        document: ProseDocument
    ) -> Int? {
        // Walk upward from the range's parent until we find a structural
        // ancestor whose content rule still validates after the range's
        // children are spliced into it at the parent-of-parent level.
        // For now we only support lifting one level — enough for the
        // common "lift out of blockquote" / "lift list_item out of list".
        let schema = document.schema
        guard let parent = schema.nodeType(range.parent.type) else { return nil }
        // The parent must accept its current child set without the
        // lifted range — i.e. the residual must remain valid. Since we
        // have no instance content here, approximate: if the parent's
        // content rule allows zero children (e.g. `*`) the lift is safe.
        // Otherwise reject.
        let residualSize = (parent.content?.match.elements.first?.min ?? 1)
        let kidsAfter = max(0, range.endIndex - range.startIndex)
        if kidsAfter == 0 { return nil }
        // PM's heuristic: the parent must have at least one structural
        // ancestor we can lift INTO (depth >= 1). Approximate that here.
        return residualSize == 0 ? 1 : nil
    }

    /// Find a chain of node types that, when wrapped around `range`,
    /// produce a tree the schema accepts. Returns the chain (innermost
    /// first) or nil. Mirrors PM's `findWrapping`.
    public static func findWrapping(
        _ range: NodeRange,
        target: NodeType.Name,
        attrs: [String: ProseAttrValue] = [:],
        in schema: Schema
    ) -> [ProseNode]? {
        guard let nt = schema.nodeType(target) else { return nil }
        // Single-level wrapping — does `target` accept the child types
        // currently in `range`?
        let childTypes = (0..<max(0, range.endIndex - range.startIndex)).map { _ in
            // Without instance children we approximate by trusting
            // `nt.content` allows the parent's child group; refine when
            // command call sites pass real children.
            return range.parent.type
        }
        if let content = nt.content, content.matches(childTypes: childTypes) {
            return [nt.create(attrs: attrs)]
        }
        // Two-level chains (e.g. `bullet_list > list_item`) live here
        // when the inner type wraps the range and the outer wraps the
        // inner. Targeted at common list constructions.
        for outer in schema.nodeTypesByName.values {
            guard let outerContent = outer.content,
                  outerContent.allowedNodes.contains(target) else { continue }
            if let content = nt.content, content.matches(childTypes: childTypes) {
                return [nt.create(attrs: attrs), outer.create()]
            }
        }
        return nil
    }

    /// Whether `pos` can be split at `depth`. PM rule: every ancestor at
    /// depth ≤ d must accept being split (i.e. its content rule remains
    /// valid for both halves). Mirrors PM's `canSplit`.
    public static func canSplit(
        _ pos: ResolvedPos,
        depth: Int = 1
    ) -> Bool {
        guard depth >= 1, depth <= pos.depth else { return false }
        // Approximate: if every ancestor up to `depth` accepts both an
        // empty leading half and an empty trailing half, we can split.
        // The fast-path that matters in practice is splitting a textblock
        // (paragraph/heading/list_item content) — always legal.
        for d in (1...depth).reversed() {
            guard let node = pos.node(at: d) else { return false }
            // Atoms can't be split.
            if node.type == "horizontal_rule" || node.type == "image" {
                return false
            }
        }
        return true
    }

    /// Whether the boundary at `pos` can be joined with its left
    /// sibling at `depth`. Mirrors PM's `canJoin`.
    public static func canJoin(
        _ pos: ResolvedPos,
        depth: Int = 1
    ) -> Bool {
        guard depth >= 1, depth <= pos.depth else { return false }
        // We need a sibling to the left of the position at this depth.
        let parentFrame = pos.frames[depth - 1]
        let idx = parentFrame.indexInParent
        guard idx >= 1, idx <= parentFrame.children.count else { return false }
        // Both neighbors must be structural with compatible types.
        let left = parentFrame.children[idx - 1]
        guard idx < parentFrame.children.count else { return false }
        let right = parentFrame.children[idx]
        switch (left, right) {
        case (.structural(let a, _), .structural(let b, _)):
            return a.type == b.type
        default:
            return false
        }
    }

    // MARK: - Step builders (skeletons)

    /// Build a `Step` that lifts `range` out of its parent, or nil when
    /// the lift isn't legal at this position. The default implementation
    /// delegates to a `setSpec`-style rebuild; commands can refine this
    /// to produce a `replaceAround` once the structural cell-shape
    /// arithmetic is in place.
    public static func lift(
        _ range: NodeRange,
        in document: ProseDocument
    ) -> [Step]? {
        guard liftTarget(range, document: document) != nil else { return nil }
        // TODO: produce a `replaceAround` that drops the current parent
        // and reparents the range's children into the grandparent. For
        // now commands that want lift continue to build their own setSpec
        // bundle until the structural arithmetic lands.
        return nil
    }

    /// Wrap `range` in `wrappers` (innermost first) — PM's `Transform.wrap`.
    /// Returns the produced `Step` chain or nil when the wrap is illegal.
    public static func wrap(
        _ range: NodeRange,
        with wrappers: [ProseNode]
    ) -> [Step]? {
        guard !wrappers.isEmpty else { return nil }
        // Same caveat as `lift` — until `replaceAround` arithmetic is
        // wired through setNodeAttrs-aware tree manipulation, this
        // returns nil and commands fall back to setSpec compositions.
        return nil
    }

    /// Split the position at `depth` into a new node of the same type,
    /// optionally typing a new node type for the trailing half. PM's
    /// `Transform.split`.
    public static func split(
        _ pos: ResolvedPos,
        depth: Int = 1,
        typeAfter: NodeType.Name? = nil
    ) -> [Step]? {
        guard canSplit(pos, depth: depth) else { return nil }
        return nil
    }

    /// Join the position with its left sibling. PM's `Transform.join`.
    public static func join(
        _ pos: ResolvedPos,
        depth: Int = 1
    ) -> [Step]? {
        guard canJoin(pos, depth: depth) else { return nil }
        return nil
    }

    /// Replace the wrapping block type for `range` with `target`. PM's
    /// `Transform.setBlockType`. Returns nil when the change is illegal.
    public static func setBlockType(
        _ range: NodeRange,
        to target: NodeType.Name,
        attrs: [String: ProseAttrValue] = [:],
        in schema: Schema
    ) -> [Step]? {
        guard schema.nodeType(target) != nil else { return nil }
        return nil
    }

    /// PM's `Transform.setNodeMarkup` — replace a single node's type and
    /// attrs without touching its children. Defaults to a `setNodeAttrs`
    /// when only attrs change; otherwise falls back to a `setSpec`
    /// rebuild at the call site.
    public static func setNodeMarkup(
        path: NodePath,
        type: NodeType.Name? = nil,
        attrs: [String: ProseAttrValue],
        in schema: Schema
    ) -> [Step]? {
        if type == nil || type == path.leaf?.type {
            return [.setNodeAttrs(path: path, attrs: attrs)]
        }
        // Type-changing markup updates need a structural step; deferred.
        return nil
    }

    /// PM's `Transform.clearIncompatible` — strip marks/atoms a target
    /// schema can't carry. Useful before a paste / setBlockType change
    /// that narrows the allowed mark or content set.
    public static func clearIncompatible(
        in document: ProseDocument,
        at: ResolvedPos,
        targetType: NodeType
    ) -> [Step] {
        // No-op until `addNodeMark` / `removeNodeMark` exist — once those
        // land, walk the inline runs in the affected range and strip any
        // marks `targetType.allowedMarks` rejects.
        _ = (document, at)
        _ = targetType
        return []
    }
}
