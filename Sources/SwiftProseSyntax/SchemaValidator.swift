import Foundation

public enum SchemaDiagnostic: Equatable, Sendable {
    case unknownNodeType(name: NodeType.Name)
    case unknownMarkType(name: MarkType.Name)
    case invalidContent(parent: NodeType.Name, found: [NodeType.Name], expected: String)
    case textInNonTextblock(parent: NodeType.Name)
    case markOnDisallowedNode(parent: NodeType.Name, mark: MarkType.Name)
}

/// Walks a `ProseDocument` and emits diagnostics for schema violations:
/// unknown node or mark types, content-expression mismatches, marks on
/// nodes whose type sets `allowsMarks == false` (code blocks, html blocks).
/// The current implementation reports — repair lives in
/// `SwiftProseView.SpecValidator` for now and will fold in once Phase 10
/// retires `BlockSpec`.
public enum SchemaValidator {

    public static func validate(_ document: ProseDocument) -> [SchemaDiagnostic] {
        var diagnostics: [SchemaDiagnostic] = []
        validateNode(document.root, schema: document.schema, parent: nil, into: &diagnostics)
        return diagnostics
    }

    private static func validateNode(
        _ node: TreeNode,
        schema: Schema,
        parent: ProseNode?,
        into diagnostics: inout [SchemaDiagnostic]
    ) {
        switch node {
        case .structural(let pn, let kids):
            guard let nodeType = schema.nodeType(pn.type) else {
                diagnostics.append(.unknownNodeType(name: pn.type))
                return
            }
            let childTypes = kids.map(childTypeName)
            if let content = nodeType.content,
               !content.matches(childTypes: childTypes) {
                diagnostics.append(.invalidContent(
                    parent: pn.type,
                    found: childTypes,
                    expected: content.raw
                ))
            }
            for kid in kids {
                validateNode(kid, schema: schema, parent: pn, into: &diagnostics)
            }
        case .leaf(let pn):
            if schema.nodeType(pn.type) == nil {
                diagnostics.append(.unknownNodeType(name: pn.type))
            }
        case .inline(_, let marks):
            let parentType = parent.flatMap { schema.nodeType($0.type) }
            for mark in marks.marks {
                if schema.markType(mark.type) == nil {
                    diagnostics.append(.unknownMarkType(name: mark.type))
                    continue
                }
                if let parentType, !parentType.allowsMarks {
                    diagnostics.append(.markOnDisallowedNode(
                        parent: parent!.type,
                        mark: mark.type
                    ))
                }
            }
        }
    }

    private static func childTypeName(_ node: TreeNode) -> NodeType.Name {
        switch node {
        case .structural(let pn, _): return pn.type
        case .leaf(let pn): return pn.type
        case .inline: return "text"
        }
    }
}
