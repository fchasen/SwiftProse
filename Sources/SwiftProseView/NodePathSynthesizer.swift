import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Refreshes the canonical `proseMarks` attribute by re-deriving marks
/// from the rendering attributes (font traits, foregroundColor,
/// strikethroughStyle, proseInline tag) within a range. Used by
/// inline-mark `Step`s after they mutate font / strikethrough / inline-tag
/// attributes directly so the canonical mark store stays in sync with
/// what the rendering layer paints.
///
/// The compiler stamps `proseNodePath` directly during emit (via
/// `setBlockSpec` → `NodePath.fromBlockSpec`); the synthesizer's job is
/// just keeping `proseMarks` in sync with the rendering attributes.
public struct NodePathSynthesizer {
    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    /// Re-derive `proseMarks` from the current rendering attributes
    /// within `range`, walking block-by-block so each block's
    /// `baseTraits` (e.g. the implicit bold of a heading) is subtracted
    /// correctly.
    public func stampMarks(
        in storage: NSMutableAttributedString,
        range: NSRange
    ) {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= storage.length else { return }
        storage.beginEditing()
        storage.enumerateNodePaths(in: range) { blockRange, path in
            let intersection = NSIntersectionRange(blockRange, range)
            guard intersection.length > 0 else { return }
            let leafType = path.leaf?.type ?? "paragraph"
            stampMarks(in: storage, blockRange: intersection, leafType: leafType)
        }
        storage.endEditing()
    }

    /// Stamp `proseMarks` over every inline run in `range`. Used by the
    /// compiler immediately after laying down rendering attributes so the
    /// canonical mark store is materialized in the same emit pass.
    public func stampMarks(
        in storage: NSMutableAttributedString,
        blockRange: NSRange,
        spec: BlockSpec
    ) {
        let leafType = leafTypeForSpec(spec)
        stampMarks(in: storage, blockRange: blockRange, leafType: leafType)
    }

    private func leafTypeForSpec(_ spec: BlockSpec) -> String {
        switch spec.kind {
        case .paragraph, .unorderedListItem, .orderedListItem, .taskListItem:
            return "paragraph"
        case .heading: return "heading"
        case .fencedCode, .indentedCode: return "code_block"
        case .horizontalRule: return "horizontal_rule"
        case .htmlBlock: return "html_block"
        case .linkReferenceDefinition: return "link_reference"
        }
    }

    private func stampMarks(
        in storage: NSMutableAttributedString,
        blockRange: NSRange,
        leafType: String
    ) {
        // Code blocks and html blocks don't carry marks; their content is
        // literal text (the schema's `allowedMarks: .none`).
        switch leafType {
        case "code_block", "html_block", "link_reference":
            storage.setMarkSet(MarkSet(), in: blockRange)
            return
        default: break
        }
        let baseTraits = baseTraits(forLeafType: leafType)
        storage.enumerateAttributes(in: blockRange, options: []) { attrs, runRange, _ in
            let marks = synthesizeMarks(from: attrs, baseTraits: baseTraits)
            storage.setMarkSet(marks, in: runRange)
        }
    }

    /// Block-level "implicit" font traits — traits that the compiler
    /// applies as part of the block's base styling and that should not
    /// surface as inline marks on every character. Headings render in
    /// bold; without subtracting the implicit bold, every heading
    /// character would carry a `strong` mark and the serializer would
    /// emit `# **all of this**` for plain headings.
    private func baseTraits(forLeafType leafType: String) -> FontTraits {
        switch leafType {
        case "heading": return .bold
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
                // The compiler also stamps `.proseInline = .link` on image
                // alt-text spans (the `[alt]` of `![alt](url)`) even though
                // no surrounding link region exists. Only synthesize a
                // `link` mark when the position has a concrete destination
                // attribute — that signals a real link span, not just
                // image-internal styling.
                let href: String?
                if let url = attrs[.proseLink] as? String, !url.isEmpty {
                    href = url
                } else if let url = attrs[.link] as? URL {
                    href = url.absoluteString
                } else if let url = attrs[.link] as? String, !url.isEmpty {
                    href = url
                } else {
                    href = nil
                }
                if let href {
                    working = working.adding(
                        ProseMark(type: "link", attrs: ["href": .string(href)]),
                        in: schema
                    )
                }
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
