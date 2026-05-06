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

/// JSON-roundtrippable value for node and mark attributes. Mirrors PM's
/// attribute shape — scalars (null / bool / int / double / string) plus
/// arrays and dictionary objects so cell colwidths, schema attribute
/// arrays, and nested attribute bags survive the codec.
public indirect enum ProseAttrValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ProseAttrValue])
    case object([String: ProseAttrValue])

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
    public var arrayValue: [ProseAttrValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    public var objectValue: [String: ProseAttrValue]? {
        if case .object(let v) = self { return v }
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
/// NSObject reference equality keeps adjacent attribute runs distinct
/// even when the underlying values are equal, which is what
/// `enumerateAttribute` consumers rely on.
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

// MARK: - BlockSpec → NodePath construction

public extension NodePath {
    /// Build a single-line `NodePath` from a `BlockSpec`. When a
    /// `predecessor` path is supplied, list and blockquote ancestors at
    /// matching depths/kinds are reused so consecutive list items at the
    /// same level share their wrapping `bullet_list` / `ordered_list` /
    /// `task_list` node — preserving tree grouping for the markdown and
    /// ProseMirror round-trips.
    ///
    /// The leaf node and the deepest list-item are always minted fresh:
    /// each block line is its own paragraph/heading/etc., and each
    /// list-item line is its own item even when its parent list is shared.
    static func fromBlockSpec(
        _ spec: BlockSpec,
        predecessor: NodePath? = nil,
        schema: Schema = .defaultMarkdown
    ) -> NodePath {
        let docNode = predecessor?.root ?? ProseNode(
            type: schema.topNodeName,
            attrs: schema.topNode.defaultAttrs()
        )
        var nodes: [ProseNode] = [docNode]
        let prevBlockquotes = predecessor.map(blockquoteAncestors) ?? []
        for i in 0..<spec.blockquoteDepth {
            if i < prevBlockquotes.count {
                nodes.append(prevBlockquotes[i])
            } else {
                nodes.append(ProseNode(type: "blockquote"))
            }
        }
        if spec.isListItem, let kind = listKind(for: spec.kind) {
            let depth = spec.listLevel
            let prevLists = predecessor.map(listAncestors) ?? []
            for level in 0...depth {
                let listNode: ProseNode
                let itemNode: ProseNode
                let isLeafLevel = (level == depth)
                // At inner levels (level < depth), an outer list_item from
                // the predecessor is reused regardless of list kind so that
                // a nested list of a different kind (e.g. bullet inside
                // ordered) lives inside the same list_item as its sibling
                // paragraph. At the leaf level only kind-matching ancestors
                // are reused — that's how `- a\n- b` shares its list while
                // `- a\n1. b` doesn't.
                let canReuse: Bool
                if level < prevLists.count {
                    canReuse = isLeafLevel ? (prevLists[level].kind == kind) : true
                } else {
                    canReuse = false
                }
                if canReuse {
                    listNode = prevLists[level].listNode
                    if level < depth {
                        itemNode = prevLists[level].itemNode
                    } else {
                        itemNode = ProseNode(
                            type: "list_item",
                            attrs: itemAttrs(for: spec.kind)
                        )
                    }
                } else {
                    listNode = ProseNode(type: listNodeName(for: kind))
                    if level < depth {
                        itemNode = ProseNode(type: "list_item")
                    } else {
                        itemNode = ProseNode(
                            type: "list_item",
                            attrs: itemAttrs(for: spec.kind)
                        )
                    }
                }
                nodes.append(listNode)
                nodes.append(itemNode)
            }
        }
        nodes.append(leafNode(for: spec.kind))
        return NodePath(nodes)
    }
}

private enum ListAncestorKind: Equatable {
    case bullet
    case ordered
    case task
}

private struct ListAncestor {
    let kind: ListAncestorKind
    let listNode: ProseNode
    let itemNode: ProseNode
}

private func blockquoteAncestors(_ path: NodePath) -> [ProseNode] {
    path.nodes.filter { $0.type == "blockquote" }
}

private func listAncestors(_ path: NodePath) -> [ListAncestor] {
    var out: [ListAncestor] = []
    var i = 0
    while i + 1 < path.nodes.count {
        let listLike = path.nodes[i]
        guard let kind = ancestorKind(forListNodeName: listLike.type) else {
            i += 1
            continue
        }
        let item = path.nodes[i + 1]
        guard item.type == "list_item" else { i += 1; continue }
        out.append(ListAncestor(kind: kind, listNode: listLike, itemNode: item))
        i += 2
    }
    return out
}

private func ancestorKind(forListNodeName name: String) -> ListAncestorKind? {
    switch name {
    case "bullet_list": return .bullet
    case "ordered_list": return .ordered
    case "task_list": return .task
    default: return nil
    }
}

private func listKind(for kind: BlockSpec.Kind) -> ListAncestorKind? {
    switch kind {
    case .unorderedListItem: return .bullet
    case .orderedListItem: return .ordered
    case .taskListItem: return .task
    default: return nil
    }
}

private func listNodeName(for kind: ListAncestorKind) -> String {
    switch kind {
    case .bullet: return "bullet_list"
    case .ordered: return "ordered_list"
    case .task: return "task_list"
    }
}

private func itemAttrs(for kind: BlockSpec.Kind) -> [String: ProseAttrValue] {
    switch kind {
    case .taskListItem(let checked): return ["checked": .bool(checked)]
    case .orderedListItem(let index): return ["order": .int(index)]
    default: return [:]
    }
}

private func leafNode(for kind: BlockSpec.Kind) -> ProseNode {
    switch kind {
    case .paragraph:
        return ProseNode(type: "paragraph")
    case .heading(let level):
        return ProseNode(type: "heading", attrs: ["level": .int(level)])
    case .unorderedListItem, .orderedListItem, .taskListItem:
        return ProseNode(type: "paragraph")
    case .fencedCode(let language):
        return ProseNode(
            type: "code_block",
            attrs: [
                "params": .string(language ?? ""),
                "fenced": .bool(true)
            ]
        )
    case .indentedCode:
        return ProseNode(
            type: "code_block",
            attrs: [
                "params": .string(""),
                "fenced": .bool(false)
            ]
        )
    case .horizontalRule:
        return ProseNode(type: "horizontal_rule")
    case .htmlBlock:
        return ProseNode(type: "html_block")
    case .linkReferenceDefinition:
        return ProseNode(type: "link_reference")
    }
}

// MARK: - NodePath → BlockSpec derivation

public extension BlockSpec {
    /// Derive a `BlockSpec` view from a `NodePath`. The leaf node type
    /// determines `kind` (and any leaf attrs map back to the spec's
    /// per-kind associated values); blockquote ancestors count toward
    /// `blockquoteDepth`; list/list_item pair count toward `listLevel`.
    /// Returns `nil` for paths whose leaf isn't a known block type.
    static func fromNodePath(_ path: NodePath) -> BlockSpec? {
        guard let leaf = path.leaf else { return nil }
        let depth = path.nodes.reduce(0) { $0 + ($1.type == "blockquote" ? 1 : 0) }
        let listPairs = path.nodes.reduce(0) { acc, node in
            switch node.type {
            case "bullet_list", "ordered_list", "task_list": return acc + 1
            default: return acc
            }
        }
        let level = max(0, listPairs - 1)
        switch leaf.type {
        case "paragraph":
            // List-item kind comes from the wrapping list_item's attrs (the
            // typed model carries `checked` / `order` on the item itself).
            if let parent = path.nodes.dropLast().last, parent.type == "list_item" {
                if let listType = path.nodes.dropLast(2).last?.type {
                    switch listType {
                    case "bullet_list":
                        return BlockSpec(kind: .unorderedListItem, blockquoteDepth: depth, listLevel: level)
                    case "ordered_list":
                        let index = parent.attrs["order"]?.intValue ?? 1
                        return BlockSpec(kind: .orderedListItem(index: index), blockquoteDepth: depth, listLevel: level)
                    case "task_list":
                        let checked = parent.attrs["checked"]?.boolValue ?? false
                        return BlockSpec(kind: .taskListItem(checked: checked), blockquoteDepth: depth, listLevel: level)
                    default: break
                    }
                }
            }
            return BlockSpec(kind: .paragraph, blockquoteDepth: depth)
        case "heading":
            let level = leaf.attrs["level"]?.intValue ?? 1
            return BlockSpec(kind: .heading(level: level), blockquoteDepth: depth)
        case "code_block":
            let isFenced = leaf.attrs["fenced"]?.boolValue ?? true
            let params = leaf.attrs["params"]?.stringValue
            let language = (params?.isEmpty == false) ? params : nil
            if isFenced {
                return BlockSpec(kind: .fencedCode(language: language), blockquoteDepth: depth)
            } else {
                return BlockSpec(kind: .indentedCode, blockquoteDepth: depth)
            }
        case "horizontal_rule":
            return BlockSpec(kind: .horizontalRule)
        case "html_block":
            return BlockSpec(kind: .htmlBlock, blockquoteDepth: depth)
        case "link_reference":
            return BlockSpec(kind: .linkReferenceDefinition, blockquoteDepth: depth)
        default:
            return nil
        }
    }
}
