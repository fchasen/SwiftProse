import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Phase-2 bridge that adds `proseNodePath` and `proseMarks` attributes to
/// a compiler-produced `NSAttributedString`. Doesn't change the storage's
/// rendering shape — just stamps the new structural attributes alongside
/// the existing `proseBlockSpec`. The layout fragment and serializer still
/// dispatch on `proseBlockSpec`; downstream phases progressively shift the
/// dispatch to walk `proseNodePath` instead.
///
/// The synthesizer derives the structural path from `BlockSpec` plus the
/// inline rendering attributes already present on the storage:
///
/// - `BlockSpec.kind` becomes the leaf node type (paragraph, heading, …).
/// - `blockquoteDepth` introduces N levels of `blockquote` ancestors.
/// - List-item kinds (`.unorderedListItem`, `.orderedListItem`,
///   `.taskListItem`) introduce a `bullet_list` / `ordered_list` /
///   `task_list` ancestor for each `listLevel`.
/// - `pipeTable` paragraphs collapse into a `table` ancestor; consecutive
///   pipe-table runs share the same table node ID. Sub-row structure
///   (rows, cells) is left unmodeled in Phase 2 — the storage shape still
///   has one paragraph per pipe-source line. Phase 6 reshapes this.
/// - Inline `font` traits (bold/italic), `proseInline` tags (codeSpan,
///   link), `strikethroughStyle`, and `proseLink` URLs become a `MarkSet`
///   on each inline run.
public struct NodePathSynthesizer {
    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    /// Re-derive `proseMarks` from the current rendering attributes within
    /// `range`, walking block-by-block so each block's `baseTraits` (e.g.
    /// the implicit bold of a heading) is subtracted correctly. Used by
    /// inline-mark Steps to keep the canonical mark store fresh after they
    /// mutate font / strikethrough / inline-tag attributes directly.
    public func stampMarks(
        in storage: NSMutableAttributedString,
        range: NSRange
    ) {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= storage.length else { return }
        storage.beginEditing()
        storage.enumerateBlockSpecs(in: range) { blockRange, spec in
            let intersection = NSIntersectionRange(blockRange, range)
            guard intersection.length > 0 else { return }
            stampMarks(in: storage, blockRange: intersection, blockKind: spec.kind)
        }
        storage.endEditing()
    }

    /// Stamp `proseNodePath` and `proseMarks` onto every character. Mutates
    /// the input. Idempotent: re-running on a stamped string overwrites
    /// previous attributes deterministically (one fresh `NodeID` per
    /// invocation, which is fine because tree consumers compare paths by
    /// ID identity within a single compile pass, not across passes).
    public func stamp(into storage: NSMutableAttributedString) {
        guard storage.length > 0 else { return }
        let docNode = ProseNode(type: schema.topNodeName, attrs: schema.topNode.defaultAttrs())
        var openLists: [OpenList] = []
        storage.beginEditing()
        storage.enumerateBlockSpecs { blockRange, spec in
            let path = nodePath(
                for: spec,
                doc: docNode,
                openLists: &openLists
            )
            storage.setNodePath(path, in: blockRange)
            // Stamp marks per inline run within this block. Marks come from
            // the rendering attributes the compiler already set.
            stampMarks(in: storage, blockRange: blockRange, blockKind: spec.kind)
        }
        storage.endEditing()
    }

    // MARK: - NodePath synthesis

    /// Tracks which list ancestors are currently open at each depth so
    /// consecutive list-item lines share the same list + (where applicable)
    /// ancestor item nodes.
    private struct OpenList {
        let kind: ListKind
        let listNode: ProseNode
        var itemNode: ProseNode
    }

    private enum ListKind: Equatable {
        case bullet
        case ordered
        case task
    }

    private func nodePath(
        for spec: BlockSpec,
        doc: ProseNode,
        openLists: inout [OpenList]
    ) -> NodePath {
        var nodes: [ProseNode] = [doc]
        // Blockquote nesting: each depth level introduces a blockquote.
        for _ in 0..<spec.blockquoteDepth {
            nodes.append(ProseNode(type: "blockquote"))
        }
        if spec.isListItem, let kind = listKind(for: spec.kind) {
            let depth = spec.listLevel
            // Close any deeper open lists.
            if openLists.count > depth + 1 {
                openLists.removeLast(openLists.count - (depth + 1))
            }
            // Ensure ancestors at every shallower depth exist; outer
            // wrappers default to bullet_list because per-line synthesis
            // doesn't know the outer list kind.
            while openLists.count < depth {
                openLists.append(OpenList(
                    kind: .bullet,
                    listNode: ProseNode(type: listNodeName(for: .bullet)),
                    itemNode: ProseNode(type: "list_item")
                ))
            }
            let leafItem = ProseNode(type: "list_item", attrs: itemAttrs(for: spec.kind))
            // At the line's own depth: reuse the open list when kind matches,
            // mint a new list otherwise. Always mint a new list_item — every
            // list-item line is its own item.
            if openLists.count == depth + 1, openLists[depth].kind == kind {
                openLists[depth].itemNode = leafItem
            } else {
                if openLists.count > depth { openLists.removeLast(openLists.count - depth) }
                openLists.append(OpenList(
                    kind: kind,
                    listNode: ProseNode(type: listNodeName(for: kind)),
                    itemNode: leafItem
                ))
            }
            for level in 0...depth {
                nodes.append(openLists[level].listNode)
                nodes.append(openLists[level].itemNode)
            }
        } else {
            // Non-list-item lines close any open lists.
            openLists.removeAll(keepingCapacity: true)
        }
        // Leaf node — the type that corresponds to this block's kind.
        nodes.append(leafNode(for: spec.kind))
        return NodePath(nodes)
    }

    private func listKind(for kind: BlockSpec.Kind) -> ListKind? {
        switch kind {
        case .unorderedListItem: return .bullet
        case .orderedListItem: return .ordered
        case .taskListItem: return .task
        default: return nil
        }
    }

    private func listNodeName(for kind: ListKind) -> String {
        switch kind {
        case .bullet: return "bullet_list"
        case .ordered: return "ordered_list"
        case .task: return "task_list"
        }
    }

    private func itemAttrs(for kind: BlockSpec.Kind) -> [String: ProseAttrValue] {
        switch kind {
        case .taskListItem(let checked):
            return ["checked": .bool(checked)]
        case .orderedListItem(let index):
            return ["order": .int(index)]
        default:
            return [:]
        }
    }

    private func leafNode(for kind: BlockSpec.Kind) -> ProseNode {
        switch kind {
        case .paragraph:
            return ProseNode(type: "paragraph")
        case .heading(let level):
            return ProseNode(type: "heading", attrs: ["level": .int(level)])
        case .unorderedListItem:
            return ProseNode(type: "paragraph")
        case .orderedListItem(let index):
            return ProseNode(
                type: "paragraph",
                attrs: ["__listOrder": .int(index)]
            )
        case .taskListItem(let checked):
            return ProseNode(
                type: "paragraph",
                attrs: ["__listChecked": .bool(checked)]
            )
        case .fencedCode(let language):
            return ProseNode(
                type: "code_block",
                attrs: [
                    "language": language.map(ProseAttrValue.string) ?? .null,
                    "fenced": .bool(true)
                ]
            )
        case .indentedCode:
            return ProseNode(
                type: "code_block",
                attrs: [
                    "language": .null,
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

    // MARK: - MarkSet synthesis

    private func stampMarks(
        in storage: NSMutableAttributedString,
        blockRange: NSRange,
        blockKind: BlockSpec.Kind
    ) {
        // Code blocks and html blocks don't carry marks; their content is
        // literal text (the schema's `allowsMarks: false`).
        switch blockKind {
        case .fencedCode, .indentedCode, .htmlBlock, .linkReferenceDefinition:
            storage.setMarkSet(MarkSet(), in: blockRange)
            return
        default: break
        }
        // Walk by the union of attribute boundaries across font / inline
        // tag / strikethrough / link. `enumerateAttributes` walks the
        // storage's natural attribute runs, which already split on every
        // attribute change, so each invocation receives a homogeneous run
        // we can synthesize a single MarkSet for.
        let baseTraits = baseTraits(for: blockKind)
        storage.enumerateAttributes(in: blockRange, options: []) { attrs, runRange, _ in
            let marks = synthesizeMarks(from: attrs, baseTraits: baseTraits)
            storage.setMarkSet(marks, in: runRange)
        }
    }

    /// Block-level "implicit" font traits — traits that the compiler
    /// applies as part of the block's base styling and that should not
    /// surface as inline marks on every character. Headings, in
    /// particular, render in bold; without subtracting the implicit bold,
    /// every heading character would carry a `strong` mark and the
    /// serializer would emit `# **all of this**` for plain headings.
    private func baseTraits(for kind: BlockSpec.Kind) -> FontTraits {
        switch kind {
        case .heading: return .bold
        default: return []
        }
    }

    private func synthesizeMarks(
        from attrs: [NSAttributedString.Key: Any],
        baseTraits: FontTraits = []
    ) -> MarkSet {
        var working = MarkSet()
        if let font = attrs[.font] as? PlatformFont {
            let traits = font.proseTraits.subtracting(baseTraits)
            if traits.contains(.bold) {
                working = working.adding(ProseMark(type: "strong"), in: schema)
            }
            if traits.contains(.italic) {
                working = working.adding(ProseMark(type: "em"), in: schema)
            }
        }
        if let inline = attrs[.proseInline] as? InlineTag {
            switch inline {
            case .codeSpan:
                working = working.adding(ProseMark(type: "code"), in: schema)
            case .link:
                let href: String
                if let url = attrs[.proseLink] as? String {
                    href = url
                } else if let url = attrs[.link] as? URL {
                    href = url.absoluteString
                } else {
                    href = ""
                }
                working = working.adding(
                    ProseMark(type: "link", attrs: ["href": .string(href)]),
                    in: schema
                )
            default:
                break
            }
        }
        if let style = attrs[.strikethroughStyle] as? Int, style != 0 {
            working = working.adding(ProseMark(type: "strike"), in: schema)
        }
        return working
    }

}
