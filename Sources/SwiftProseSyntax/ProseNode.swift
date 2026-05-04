import Foundation

/// Stable per-instance identifier for a `ProseNode`. Two structural nodes
/// with identical type/attrs but different IDs are distinct entities.
///
/// **Divergence from ProseMirror**: PM nodes have no instance identity —
/// they're value-equal whenever their type, attrs, marks, and content
/// match. We add `NodeID` for two reasons that matter in our embedding:
///
/// 1. `NSAttributedString` attribute-run grouping uses `isEqual:`. Without
///    a per-instance identity, two adjacent paragraphs with identical
///    classification would collapse into one attribute run; the storage
///    layer wouldn't be able to tell them apart.
/// 2. A future collaborative-editing path needs stable references to nodes
///    across edits so OT/CRDT operations target the right node. Using a
///    UUID gives us a transport-friendly identifier without going through
///    structural addressing.
///
/// IDs are not part of the structural identity for tests and codec output:
/// helpers like `equalsIgnoringID` and `equalsIgnoringIDs` exist for
/// shape-based comparisons.
public struct NodeID: Sendable, Equatable, Hashable, Codable {
    public let raw: UUID

    public init() { self.raw = UUID() }
    public init(raw: UUID) { self.raw = raw }
}

/// JSON-roundtrippable scalar for node and mark attributes. Mirrors the
/// subset of ProseMirror attribute values we actually use (heading level,
/// list start index, table-cell alignment, etc.). Nested objects and arrays
/// aren't needed; expand the case set if a future schema requires them.
public enum ProseAttrValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

/// One structural node along a `NodePath`. Value-typed and immutable; carries
/// type, per-instance ID, and a small attribute bag. The attribute bag is
/// type-specific (e.g. heading carries `level`, table_cell carries `align`).
public struct ProseNode: Sendable, Equatable, Hashable {
    public let id: NodeID
    public let type: NodeType.Name
    public let attrs: [String: ProseAttrValue]

    public init(
        id: NodeID = NodeID(),
        type: NodeType.Name,
        attrs: [String: ProseAttrValue] = [:]
    ) {
        self.id = id
        self.type = type
        self.attrs = attrs
    }

    /// Equality ignoring the per-instance ID — useful for fixture assertions
    /// where two nodes carry "the same kind+attrs" but with freshly-minted
    /// IDs. Don't use for dedup or run-grouping.
    public func equalsIgnoringID(_ other: ProseNode) -> Bool {
        type == other.type && attrs == other.attrs
    }
}

/// Hierarchical structural attribute — the chain of structural ancestors
/// from the document root down to the inline leaf containing this run of
/// text. Replaces the flat `BlockSpec` attribute as the canonical
/// structural classification.
///
/// Two runs share an ancestor iff their NodePaths agree on that ancestor's
/// `NodeID`. This is how the document-tree builder knows that two adjacent
/// paragraphs in storage are siblings (different paragraph IDs but the
/// same parent IDs).
public struct NodePath: Sendable, Equatable, Hashable {
    public let nodes: [ProseNode]

    public init(_ nodes: [ProseNode]) {
        self.nodes = nodes
    }

    public var depth: Int { nodes.count }
    public var leaf: ProseNode? { nodes.last }
    public var root: ProseNode? { nodes.first }

    public func node(at depth: Int) -> ProseNode? {
        nodes.indices.contains(depth) ? nodes[depth] : nil
    }

    public func appending(_ node: ProseNode) -> NodePath {
        NodePath(nodes + [node])
    }

    public func droppingLast() -> NodePath {
        NodePath(Array(nodes.dropLast()))
    }

    /// Length of the longest common prefix shared with `other`, comparing by
    /// `NodeID`. Used by the storage→tree builder to decide how many levels
    /// to close when transitioning from one run's path to the next.
    public func commonPrefixDepth(with other: NodePath) -> Int {
        var i = 0
        let cap = Swift.min(nodes.count, other.nodes.count)
        while i < cap, nodes[i].id == other.nodes[i].id {
            i += 1
        }
        return i
    }

    /// Equality ignoring per-instance NodeIDs. Useful in tests where the
    /// caller wants to assert tree shape without committing to specific UUIDs.
    public func equalsIgnoringIDs(_ other: NodePath) -> Bool {
        guard nodes.count == other.nodes.count else { return false }
        for (a, b) in zip(nodes, other.nodes) where !a.equalsIgnoringID(b) {
            return false
        }
        return true
    }
}

/// Reference-typed wrapper for storing `NodePath` in `NSAttributedString`.
/// Mirrors `BlockSpecBox`'s contract: NSObject reference equality keeps
/// adjacent attribute runs distinct even when the underlying values are
/// equal, which is what `enumerateAttribute` consumers rely on.
public final class NodePathBox: NSObject, @unchecked Sendable {
    public let path: NodePath

    public init(_ path: NodePath) {
        self.path = path
        super.init()
    }
}

public extension NSAttributedString {
    func nodePath(at index: Int) -> NodePath? {
        guard index >= 0, index < length else { return nil }
        let raw = attribute(.proseNodePath, at: index, effectiveRange: nil)
        return (raw as? NodePathBox)?.path
    }

    /// Walk every `proseNodePath` run in `range` (or the whole string when
    /// `range` is nil). Each invocation receives the run range and the
    /// associated path. Runs without the attribute are skipped silently.
    func enumerateNodePaths(
        in range: NSRange? = nil,
        _ body: (NSRange, NodePath) -> Void
    ) {
        let scan = range ?? NSRange(location: 0, length: length)
        guard scan.length > 0 else { return }
        enumerateAttribute(.proseNodePath, in: scan) { value, subRange, _ in
            if let box = value as? NodePathBox {
                body(subRange, box.path)
            }
        }
    }
}

public extension NSMutableAttributedString {
    func setNodePath(_ path: NodePath, in range: NSRange) {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= length else { return }
        addAttribute(.proseNodePath, value: NodePathBox(path), range: range)
    }
}
