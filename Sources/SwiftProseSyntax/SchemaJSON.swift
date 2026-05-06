import Foundation

/// Schema-level helpers for converting between PM JSON value shapes and the
/// typed `ProseAttrValue` / `ProseNode` / `ProseMark` model. Lives in the
/// SwiftProseSyntax layer so headless callers — code that only needs a
/// `ProseDocument` from JSON, no rendering — can decode without pulling in
/// the View layer's full codec.
public extension Schema {
    /// Project PM JSON attrs onto a node type, filling declared defaults.
    /// Unknown JSON keys are dropped silently. Known keys whose value is
    /// missing fall back to the schema-declared default; if no default is
    /// declared, the attr is omitted.
    func nodeAttrs(
        _ name: NodeType.Name,
        from json: [String: PMValue]?
    ) -> [String: ProseAttrValue] {
        guard let nt = nodeType(name) else { return [:] }
        return resolveAttrs(specs: nt.attrs, from: json)
    }

    /// Same as `nodeAttrs(_:from:)` but for mark types.
    func markAttrs(
        _ name: MarkType.Name,
        from json: [String: PMValue]?
    ) -> [String: ProseAttrValue] {
        guard let mt = markType(name) else { return [:] }
        return resolveAttrs(specs: mt.attrs, from: json)
    }

    /// Build a `ProseNode` (instance) from a PM JSON node, applying
    /// schema-declared defaults. Returns nil when the node type is unknown
    /// to this schema.
    func nodeFromJSON(_ pm: PMNode) -> ProseNode? {
        guard nodeType(pm.type) != nil else { return nil }
        return ProseNode(type: pm.type, attrs: nodeAttrs(pm.type, from: pm.attrs))
    }

    /// Build a `ProseMark` from a PM JSON mark, applying schema-declared
    /// defaults. Returns nil when the mark type is unknown.
    func markFromJSON(_ pm: PMMark) -> ProseMark? {
        guard markType(pm.type) != nil else { return nil }
        return ProseMark(type: pm.type, attrs: markAttrs(pm.type, from: pm.attrs))
    }

    private func resolveAttrs(
        specs: [AttrSpec],
        from json: [String: PMValue]?
    ) -> [String: ProseAttrValue] {
        var out: [String: ProseAttrValue] = [:]
        for spec in specs {
            if let raw = json?[spec.name] {
                out[spec.name] = ProseAttrValue(pmValue: raw)
            } else if let dflt = spec.defaultValue {
                out[spec.name] = dflt
            }
        }
        return out
    }
}

public extension ProseAttrValue {
    /// Convert a wire `PMValue` to the typed `ProseAttrValue` shape.
    /// Recursive for arrays and objects; null surfaces as `.null`.
    init(pmValue value: PMValue) {
        switch value {
        case .null: self = .null
        case .bool(let v): self = .bool(v)
        case .int(let v): self = .int(v)
        case .double(let v): self = .double(v)
        case .string(let v): self = .string(v)
        case .array(let v): self = .array(v.map { ProseAttrValue(pmValue: $0) })
        case .object(let v): self = .object(v.mapValues { ProseAttrValue(pmValue: $0) })
        }
    }

    /// Convert this typed attr value back to a wire `PMValue` shape.
    func toPMValue() -> PMValue {
        switch self {
        case .null: return .null
        case .bool(let v): return .bool(v)
        case .int(let v): return .int(v)
        case .double(let v): return .double(v)
        case .string(let v): return .string(v)
        case .array(let v): return .array(v.map { $0.toPMValue() })
        case .object(let v): return .object(v.mapValues { $0.toPMValue() })
        }
    }
}
