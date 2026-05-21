import Foundation

/// A view into a document — a `Fragment` plus the open depths at its
/// start and end. Mirrors ProseMirror's `Slice`.
///
/// `openStart` / `openEnd` count how many levels of the start / end
/// boundary are "open" — i.e. would merge with the surrounding document
/// rather than acting as their own block boundary. A paste from inside
/// one paragraph into another has `openStart == openEnd == 1`; a paste
/// that spans whole blocks has `openStart == openEnd == 0`.
public struct Slice: Sendable, Equatable {

    public let content: Fragment
    public let openStart: Int
    public let openEnd: Int

    public init(content: Fragment, openStart: Int, openEnd: Int) {
        self.content = content
        self.openStart = max(0, openStart)
        self.openEnd = max(0, openEnd)
    }

    public static let empty = Slice(content: .empty, openStart: 0, openEnd: 0)

    public var isEmpty: Bool { content.isEmpty }
    public var size: Int { content.size - openStart - openEnd }

    /// Sliding the start-/end-side open depths so the slice grows toward
    /// covering more of its outermost containers. Used by paste when the
    /// target context wants tighter or looser open depths than the source.
    public func with(openStart: Int? = nil, openEnd: Int? = nil) -> Slice {
        Slice(
            content: content,
            openStart: openStart ?? self.openStart,
            openEnd: openEnd ?? self.openEnd
        )
    }

    /// Build a slice that opens as deep as possible into the outermost
    /// container, optionally stopping at the first `isolating` node.
    public static func maxOpen(_ content: Fragment, openIsolating: Bool = true) -> Slice {
        let start = depthOnSide(content, end: false, openIsolating: openIsolating)
        let end = depthOnSide(content, end: true, openIsolating: openIsolating)
        return Slice(content: content, openStart: start, openEnd: end)
    }

    private static func depthOnSide(
        _ content: Fragment,
        end: Bool,
        openIsolating: Bool
    ) -> Int {
        var depth = 0
        var node: TreeNode? = end ? content.lastChild : content.firstChild
        while let current = node, case .structural(let pNode, let kids) = current {
            if !openIsolating, isIsolating(pNode) { break }
            depth += 1
            node = end ? kids.last : kids.first
        }
        return depth
    }

    private static func isIsolating(_ node: ProseNode) -> Bool {
        // The schema would tell us this, but `Slice.maxOpen` is called
        // from layers that don't always have the schema in hand. Today
        // only `table` is isolating in `Schema.defaultMarkdown`; a future
        // refactor can route the schema through the call sites.
        node.type == "table"
    }
}

// MARK: - JSON

public extension Slice {

    /// Encode to PM-shaped JSON. PM's `Slice.toJSON()` emits `{ content, openStart, openEnd }`
    /// where `content` is the fragment's PM nodes and the open fields are
    /// omitted when they're 0.
    func toJSON(schema: Schema) -> PMValue {
        var obj: [String: PMValue] = [
            "content": .array(content.children.compactMap { treeToPM($0, schema: schema) })
        ]
        if openStart > 0 { obj["openStart"] = .int(openStart) }
        if openEnd > 0 { obj["openEnd"] = .int(openEnd) }
        return .object(obj)
    }

    /// Decode from PM-shaped JSON. Unknown nodes/marks are dropped (the
    /// schema validator surfaces them as diagnostics elsewhere).
    static func fromJSON(_ value: PMValue, schema: Schema) -> Slice? {
        guard let obj = value.objectValue else { return nil }
        guard let contentArray = obj["content"]?.arrayValue else { return nil }
        var children: [TreeNode] = []
        for raw in contentArray {
            if let tree = pmToTree(raw, schema: schema) {
                children.append(tree)
            }
        }
        let openStart = obj["openStart"]?.intValue ?? 0
        let openEnd = obj["openEnd"]?.intValue ?? 0
        return Slice(content: Fragment(children), openStart: openStart, openEnd: openEnd)
    }

    private func treeToPM(_ node: TreeNode, schema: Schema) -> PMValue? {
        switch node {
        case .inline(let text, let marks):
            var obj: [String: PMValue] = [
                "type": .string("text"),
                "text": .string(text)
            ]
            if !marks.isEmpty {
                obj["marks"] = .array(marks.marks.map { mark in
                    var m: [String: PMValue] = ["type": .string(mark.type)]
                    if !mark.attrs.isEmpty {
                        m["attrs"] = .object(mark.attrs.mapValues { $0.toPMValue() })
                    }
                    return .object(m)
                })
            }
            return .object(obj)
        case .leaf(let pn, let marks):
            var obj: [String: PMValue] = ["type": .string(pn.type)]
            if !pn.attrs.isEmpty {
                obj["attrs"] = .object(pn.attrs.mapValues { $0.toPMValue() })
            }
            if !marks.isEmpty {
                obj["marks"] = .array(marks.marks.map { mark in
                    var m: [String: PMValue] = ["type": .string(mark.type)]
                    if !mark.attrs.isEmpty {
                        m["attrs"] = .object(mark.attrs.mapValues { $0.toPMValue() })
                    }
                    return .object(m)
                })
            }
            return .object(obj)
        case .structural(let pn, let kids):
            var obj: [String: PMValue] = ["type": .string(pn.type)]
            if !pn.attrs.isEmpty {
                obj["attrs"] = .object(pn.attrs.mapValues { $0.toPMValue() })
            }
            if !kids.isEmpty {
                obj["content"] = .array(kids.compactMap { kid in
                    Slice(content: Fragment(), openStart: 0, openEnd: 0).treeToPM(kid, schema: schema)
                })
            }
            return .object(obj)
        }
    }

    private static func pmToTree(_ value: PMValue, schema: Schema) -> TreeNode? {
        guard let obj = value.objectValue else { return nil }
        guard let typeName = obj["type"]?.stringValue else { return nil }
        if typeName == "text" {
            let text = obj["text"]?.stringValue ?? ""
            let marks = decodeMarks(obj["marks"], schema: schema)
            return .inline(text: text, marks: marks)
        }
        guard let nt = schema.nodeType(typeName) else { return nil }
        var attrs: [String: ProseAttrValue] = nt.defaultAttrs()
        if let attrsObj = obj["attrs"]?.objectValue {
            for (k, v) in attrsObj {
                attrs[k] = ProseAttrValue(pmValue: v)
            }
        }
        let node = ProseNode(type: typeName, attrs: attrs)
        if nt.isLeaf {
            let marks = decodeMarks(obj["marks"], schema: schema)
            return .leaf(node, marks)
        }
        var kids: [TreeNode] = []
        if let contentArr = obj["content"]?.arrayValue {
            for raw in contentArr {
                if let kid = pmToTree(raw, schema: schema) {
                    kids.append(kid)
                }
            }
        }
        return .structural(node, kids)
    }

    private static func decodeMarks(_ raw: PMValue?, schema: Schema) -> MarkSet {
        guard let arr = raw?.arrayValue else { return MarkSet() }
        var marks: [ProseMark] = []
        for entry in arr {
            guard let obj = entry.objectValue,
                  let typeName = obj["type"]?.stringValue,
                  schema.markType(typeName) != nil else { continue }
            var attrs: [String: ProseAttrValue] = [:]
            if let attrsObj = obj["attrs"]?.objectValue {
                for (k, v) in attrsObj {
                    attrs[k] = ProseAttrValue(pmValue: v)
                }
            }
            marks.append(ProseMark(type: typeName, attrs: attrs))
        }
        return MarkSet(marks)
    }
}
