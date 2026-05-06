import Foundation

/// Schema definition mirroring ProseMirror's. Lists all node types (block
/// and inline), all mark types, and which node is the document root. Used
/// for tree validation, structural queries, and round-trip with the
/// ProseMirror codec.
public struct Schema: Sendable, Equatable {
    public let nodeTypesByName: [NodeType.Name: NodeType]
    public let markTypesByName: [MarkType.Name: MarkType]
    public let topNodeName: NodeType.Name
    /// Mark-type names in declaration order. ProseMirror uses this order
    /// to assign each mark type a rank, and `MarkSet.adding(_:in:)` keeps
    /// the set sorted by rank so the same set always serializes the same
    /// way (e.g. `[strong, em]` rather than `[em, strong]`).
    public let markTypeOrder: [MarkType.Name]

    public init(
        nodeTypes: [NodeType],
        markTypes: [MarkType],
        topNode: NodeType.Name
    ) {
        var nodes: [NodeType.Name: NodeType] = [:]
        for nt in nodeTypes { nodes[nt.name] = nt }
        var marks: [MarkType.Name: MarkType] = [:]
        for mt in markTypes { marks[mt.name] = mt }
        self.nodeTypesByName = nodes
        self.markTypesByName = marks
        self.markTypeOrder = markTypes.map(\.name)
        self.topNodeName = topNode
    }

    public var topNode: NodeType { nodeTypesByName[topNodeName]! }

    public func nodeType(_ name: NodeType.Name) -> NodeType? {
        nodeTypesByName[name]
    }

    public func markType(_ name: MarkType.Name) -> MarkType? {
        markTypesByName[name]
    }

    /// Rank for a mark type — its index in `markTypeOrder`. Returns
    /// `Int.max` for unknown marks so they sort to the end. Mirrors
    /// ProseMirror's `MarkType.rank`.
    public func rank(ofMark name: MarkType.Name) -> Int {
        markTypeOrder.firstIndex(of: name) ?? Int.max
    }
}

/// Declares a structural or inline node type — its name, group memberships,
/// content rules, attribute defaults, and whether it's a leaf (no children)
/// or text node (whose "content" is its `text` payload).
///
/// Mirrors ProseMirror's `NodeType`: the same fields plus our `NodeID`-bearing
/// instance representation and a few derived flags (`isBlock`, `isInline`,
/// `isTextblock`) that ProseMirror exposes the same way.
public struct NodeType: Sendable, Equatable, Hashable {
    public typealias Name = String

    public let name: Name
    /// Group memberships. ProseMirror permits a space-separated list
    /// (`"block list"`) so the same node can satisfy multiple content
    /// expressions; we store the parsed set for fast membership tests.
    public let groups: Set<String>
    public let content: ContentExpression?
    public let isLeaf: Bool
    public let isText: Bool
    public let attrs: [AttrSpec]
    /// Whether this node accepts inline marks on its text content. False for
    /// code-text contexts (the `code` mark on text inside `code_block` would
    /// be redundant; emit none).
    public let allowsMarks: Bool
    /// Marks the node as a self-managed subtree — a `NodeViewProvider`
    /// renders the storage anchor as a single attachment that owns its own
    /// editing surface (cell grid, image gallery, embedded editor). The
    /// reverse-projection lifts the attachment's structural subtree back
    /// into the document tree at this point.
    public let isolating: Bool

    public init(
        name: Name,
        groups: Set<String> = [],
        group: String? = nil,
        content: ContentExpression? = nil,
        isLeaf: Bool = false,
        isText: Bool = false,
        attrs: [AttrSpec] = [],
        allowsMarks: Bool = true,
        isolating: Bool = false
    ) {
        var resolved = groups
        if let group, !group.isEmpty {
            for token in group.split(separator: " ") where !token.isEmpty {
                resolved.insert(String(token))
            }
        }
        self.name = name
        self.groups = resolved
        self.content = content
        self.isLeaf = isLeaf
        self.isText = isText
        self.attrs = attrs
        self.allowsMarks = allowsMarks
        self.isolating = isolating
    }

    public var group: String? { groups.first }

    public func isInGroup(_ name: String) -> Bool { groups.contains(name) }

    /// True for inline-group node types (text, hard_break, etc.). Mirrors
    /// `ProseMirror.NodeType.isInline`.
    public var isInline: Bool { groups.contains("inline") }

    /// True for non-inline, non-text node types. Mirrors
    /// `ProseMirror.NodeType.isBlock`.
    public var isBlock: Bool { !isInline && !isText }

    /// True for block nodes whose content is inline (paragraph, heading).
    /// Mirrors `ProseMirror.NodeType.isTextblock`.
    public var isTextblock: Bool {
        guard isBlock, let allowed = content?.allowedNodes else { return false }
        return allowed.contains("text") || allowed.contains("hard_break")
    }

    /// Atomic node — leaf or non-text. Mirrors PM's `isAtom`. Used by
    /// position arithmetic to decide whether a node "counts as" a single
    /// step or contains addressable children.
    public var isAtom: Bool { isLeaf || isText }

    public func defaultAttrs() -> [String: ProseAttrValue] {
        var out: [String: ProseAttrValue] = [:]
        for spec in attrs where spec.defaultValue != nil {
            out[spec.name] = spec.defaultValue!
        }
        return out
    }
}

/// Inline mark declaration — type name, attrs (e.g. `href` for link), and
/// any types this mark excludes (ProseMirror semantics: `code` excludes
/// `em`/`strong`).
public struct MarkType: Sendable, Equatable, Hashable {
    public typealias Name = String

    public let name: Name
    public let attrs: [AttrSpec]
    public let excludes: Set<Name>
    /// Whether the mark "extends" at its boundaries. ProseMirror semantics:
    /// when typing immediately after an inclusive mark, the new text
    /// inherits the mark; when typing after a non-inclusive mark, it
    /// doesn't. Defaults to true; `link` is the canonical non-inclusive
    /// mark since URLs shouldn't grow on their own.
    public let inclusive: Bool

    public init(
        name: Name,
        attrs: [AttrSpec] = [],
        excludes: Set<Name> = [],
        inclusive: Bool = true
    ) {
        self.name = name
        self.attrs = attrs
        self.excludes = excludes
        self.inclusive = inclusive
    }
}

public struct AttrSpec: Sendable, Equatable, Hashable {
    public let name: String
    public let defaultValue: ProseAttrValue?

    public init(_ name: String, defaultValue: ProseAttrValue? = nil) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Content rule for a node type. Stores the raw ProseMirror expression
/// string plus a flat set of allowed direct children for fast membership
/// queries. The `matches(childTypes:)` matcher checks cardinality given
/// the expression's trailing quantifier (`+`, `*`, `?`, or none); the
/// schema only uses single-segment patterns so we don't need a full
/// regex engine.
public struct ContentExpression: Sendable, Equatable, Hashable {
    public let raw: String
    public let allowedNodes: Set<String>

    public init(_ raw: String, allowedNodes: Set<String>) {
        self.raw = raw
        self.allowedNodes = allowedNodes
    }

    public func allows(child name: NodeType.Name) -> Bool {
        allowedNodes.contains(name)
    }

    public enum Quantifier: Sendable, Hashable {
        case exactlyOne
        case oneOrMore   // +
        case zeroOrMore  // *
        case zeroOrOne   // ?
    }

    public var quantifier: Quantifier {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch trimmed.last {
        case "+": return .oneOrMore
        case "*": return .zeroOrMore
        case "?": return .zeroOrOne
        default: return .exactlyOne
        }
    }

    /// Whether `childTypes` satisfies this expression. Each child must be
    /// in `allowedNodes`, and the count must satisfy the quantifier.
    public func matches(childTypes: [NodeType.Name]) -> Bool {
        for type in childTypes where !allowedNodes.contains(type) {
            return false
        }
        switch quantifier {
        case .exactlyOne: return childTypes.count == 1
        case .oneOrMore: return childTypes.count >= 1
        case .zeroOrMore: return true
        case .zeroOrOne: return childTypes.count <= 1
        }
    }
}

// MARK: - Default markdown schema

public extension Schema {
    /// Default markdown schema mirroring the existing block kinds:
    /// paragraph, heading, blockquote, lists (bullet/ordered/task), code
    /// blocks (fenced + indented), horizontal rule, html block, link
    /// reference definitions, pipe tables. Marks: strong, em, code, link,
    /// strike. Inline children: text, hard_break.
    static let defaultMarkdown: Schema = makeDefaultMarkdownSchema()
}

private func makeDefaultMarkdownSchema() -> Schema {
    let blockChildren: Set<String> = [
        "paragraph",
        "heading",
        "blockquote",
        "bullet_list",
        "ordered_list",
        "task_list",
        "code_block",
        "horizontal_rule",
        "html_block",
        "link_reference",
        "table"
    ]
    let inlineChildren: Set<String> = ["text", "hard_break", "image"]
    let listItemChildren: Set<String> = [
        "paragraph",
        "bullet_list",
        "ordered_list",
        "task_list"
    ]
    let tableCellChildren: Set<String> = ["paragraph"]
    return Schema(
        nodeTypes: [
            NodeType(
                name: "doc",
                group: "doc",
                content: ContentExpression("block+", allowedNodes: blockChildren)
            ),
            NodeType(
                name: "paragraph",
                group: "block",
                content: ContentExpression("inline*", allowedNodes: inlineChildren)
            ),
            NodeType(
                name: "heading",
                group: "block",
                content: ContentExpression("inline*", allowedNodes: inlineChildren),
                attrs: [AttrSpec("level", defaultValue: .int(1))]
            ),
            NodeType(
                name: "blockquote",
                group: "block",
                content: ContentExpression("block+", allowedNodes: blockChildren)
            ),
            NodeType(
                name: "bullet_list",
                group: "block",
                content: ContentExpression("list_item+", allowedNodes: ["list_item"])
            ),
            NodeType(
                name: "ordered_list",
                group: "block",
                content: ContentExpression("list_item+", allowedNodes: ["list_item"]),
                attrs: [AttrSpec("order", defaultValue: .int(1))]
            ),
            NodeType(
                name: "task_list",
                group: "block",
                content: ContentExpression("list_item+", allowedNodes: ["list_item"])
            ),
            NodeType(
                name: "list_item",
                group: "list_item",
                content: ContentExpression("paragraph block*", allowedNodes: listItemChildren),
                attrs: [
                    AttrSpec("checked", defaultValue: .null),
                    AttrSpec("order", defaultValue: .null)
                ]
            ),
            NodeType(
                name: "code_block",
                group: "block",
                content: ContentExpression("text*", allowedNodes: ["text"]),
                attrs: [
                    AttrSpec("params", defaultValue: .string("")),
                    AttrSpec("fenced", defaultValue: .bool(true))
                ],
                allowsMarks: false
            ),
            NodeType(
                name: "horizontal_rule",
                group: "block",
                isLeaf: true
            ),
            NodeType(
                name: "html_block",
                group: "block",
                content: ContentExpression("text*", allowedNodes: ["text"]),
                allowsMarks: false
            ),
            NodeType(
                name: "link_reference",
                group: "block",
                isLeaf: true,
                attrs: [
                    AttrSpec("label", defaultValue: .string("")),
                    AttrSpec("href", defaultValue: .string("")),
                    AttrSpec("title", defaultValue: .null)
                ]
            ),
            NodeType(
                name: "table",
                group: "block",
                content: ContentExpression("table_row+", allowedNodes: ["table_row"]),
                isolating: true
            ),
            NodeType(
                name: "table_row",
                group: "table_block",
                content: ContentExpression(
                    "(table_cell | table_header)+",
                    allowedNodes: ["table_cell", "table_header"]
                ),
                attrs: [AttrSpec("header", defaultValue: .bool(false))]
            ),
            NodeType(
                name: "table_cell",
                group: "table_block",
                content: ContentExpression("paragraph+", allowedNodes: tableCellChildren),
                attrs: [
                    AttrSpec("align", defaultValue: .null),
                    AttrSpec("colspan", defaultValue: .int(1)),
                    AttrSpec("rowspan", defaultValue: .int(1)),
                    AttrSpec("colwidth", defaultValue: .null)
                ]
            ),
            NodeType(
                name: "table_header",
                group: "table_block",
                content: ContentExpression("paragraph+", allowedNodes: tableCellChildren),
                attrs: [
                    AttrSpec("align", defaultValue: .null),
                    AttrSpec("colspan", defaultValue: .int(1)),
                    AttrSpec("rowspan", defaultValue: .int(1)),
                    AttrSpec("colwidth", defaultValue: .null)
                ]
            ),
            NodeType(
                name: "text",
                group: "inline",
                isText: true
            ),
            NodeType(
                name: "hard_break",
                group: "inline",
                isLeaf: true
            ),
            NodeType(
                name: "image",
                group: "inline",
                isLeaf: true,
                attrs: [
                    AttrSpec("src", defaultValue: .string("")),
                    AttrSpec("alt", defaultValue: .string("")),
                    AttrSpec("title", defaultValue: .string(""))
                ]
            )
        ],
        markTypes: [
            MarkType(name: "strong"),
            MarkType(name: "em"),
            MarkType(
                name: "code",
                excludes: ["strong", "em", "link", "strike"]
            ),
            MarkType(
                name: "link",
                attrs: [
                    AttrSpec("href", defaultValue: .string("")),
                    AttrSpec("title", defaultValue: .string(""))
                ],
                inclusive: false
            ),
            MarkType(name: "strike")
        ],
        topNode: "doc"
    )
}
