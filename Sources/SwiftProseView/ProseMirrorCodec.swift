import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum ProseMirrorCodecError: Error {
    case invalidJSON
    case unknownNodeType(String)
}

public struct ProseMirrorCodec {
    public let schemaMap: SchemaMap
    public let theme: ProseTheme

    public init(schemaMap: SchemaMap = .basic, theme: ProseTheme = .default) {
        self.schemaMap = schemaMap
        self.theme = theme
    }

    // MARK: decode

    public func decode(_ json: Data) throws -> NSAttributedString {
        let root = try JSONDecoder().decode(PMNode.self, from: json)
        let result = NSMutableAttributedString()
        var ctx = BlockContext()
        decodeNode(root, into: result, context: &ctx)
        return result
    }

    public func decode(_ jsonString: String) throws -> NSAttributedString {
        guard let data = jsonString.data(using: .utf8) else {
            throw ProseMirrorCodecError.invalidJSON
        }
        return try decode(data)
    }

    private func decodeNode(_ node: PMNode, into result: NSMutableAttributedString, context: inout BlockContext) {
        switch node.type {
        case "doc":
            for child in node.content ?? [] { decodeNode(child, into: result, context: &context) }
        case "blockquote":
            context.blockquoteDepth += 1
            for child in node.content ?? [] { decodeNode(child, into: result, context: &context) }
            context.blockquoteDepth -= 1
        case "bullet_list":
            context.pushList(.unordered)
            for child in node.content ?? [] { decodeNode(child, into: result, context: &context) }
            context.popList()
        case "ordered_list":
            let start = node.attrs?["order"]?.intValue ?? 1
            context.pushList(.ordered(start: start))
            context.orderedIndex = start
            for child in node.content ?? [] { decodeNode(child, into: result, context: &context) }
            context.popList()
        case "list_item":
            context.listLevel += 1
            for child in node.content ?? [] { decodeNode(child, into: result, context: &context) }
            context.listLevel -= 1
            context.incrementOrderedIndex()
        case "paragraph":
            let detected = detectTaskListPrefix(in: node)
            if context.listStack.last == .unordered, let detected {
                let spec = context.makeBlockSpec(kind: .taskListItem(checked: detected.checked))
                appendTextblock(detected.stripped, spec: spec, into: result)
            } else {
                let spec = context.makeBlockSpec(kind: .paragraph)
                appendTextblock(node, spec: spec, into: result)
            }
        case "heading":
            let level = node.attrs?["level"]?.intValue ?? 1
            let spec = context.makeBlockSpec(kind: .heading(level: level))
            appendTextblock(node, spec: spec, into: result)
        case "code_block":
            let lang = node.attrs?["params"]?.stringValue
            let spec = context.makeBlockSpec(kind: .fencedCode(language: (lang?.isEmpty == true) ? nil : lang))
            appendTextblock(node, spec: spec, into: result)
        case "horizontal_rule":
            appendLeafBlock(spec: BlockSpec(kind: .horizontalRule), into: result)
        case "table":
            decodeTableAsPlaintext(node, into: result, context: &context)
        default:
            if node.content != nil {
                let spec = context.makeBlockSpec(kind: .paragraph)
                appendTextblock(node, spec: spec, into: result)
            }
        }
    }

    /// PM `table` nodes decode to flat paragraphs with literal pipe-table
    /// source. Each row becomes a single paragraph line; header / alignment /
    /// body all share the same plain paragraph spec. Marks within cells are
    /// flattened to plain text.
    private func decodeTableAsPlaintext(
        _ node: PMNode,
        into result: NSMutableAttributedString,
        context: inout BlockContext
    ) {
        let rows = node.content ?? []
        guard !rows.isEmpty else { return }
        let headerCells: [String] = (rows.first?.content ?? []).map { plainCellText(in: $0) }
        let alignmentTokens: [String] = (rows.first?.content ?? []).map { cell in
            guard let attr = cell.attrs?["align"]?.stringValue else { return "---" }
            switch attr {
            case "left": return ":---"
            case "right": return "---:"
            case "center": return ":---:"
            default: return "---"
            }
        }
        let bodyRows: [[String]] = rows.dropFirst().map { row in
            (row.content ?? []).map { plainCellText(in: $0) }
        }
        let columnCount = max(headerCells.count, alignmentTokens.count, bodyRows.map(\.count).max() ?? 0)
        var lines: [String] = []
        lines.append(rowLine(headerCells, columnCount: columnCount))
        lines.append(rowLine(alignmentTokens, columnCount: columnCount))
        for body in bodyRows {
            lines.append(rowLine(body, columnCount: columnCount))
        }
        let spec = context.makeBlockSpec(kind: .paragraph)
        for line in lines {
            let attrs = schemaMap.baseAttributes(for: spec, theme: theme)
            let beforeLength = result.length
            result.append(NSAttributedString(string: line + "\n", attributes: attrs))
            let stampedLength = result.length - beforeLength
            if stampedLength > 0 {
                result.setBlockSpec(spec, in: NSRange(location: beforeLength, length: stampedLength))
            }
        }
    }

    private func plainCellText(in cell: PMNode) -> String {
        guard let inner = cell.content else { return "" }
        var pieces: [String] = []
        for block in inner {
            for child in block.content ?? [] {
                if child.type == "text", let text = child.text { pieces.append(text) }
                if child.type == "hard_break" { pieces.append(" ") }
            }
        }
        return pieces.joined()
    }

    private func rowLine(_ cells: [String], columnCount: Int) -> String {
        var parts: [String] = []
        for i in 0..<columnCount {
            let cell = i < cells.count ? cells[i] : ""
            parts.append(" \(cell) ")
        }
        return "|" + parts.joined(separator: "|") + "|"
    }

    private func detectTaskListPrefix(in node: PMNode) -> (checked: Bool, stripped: PMNode)? {
        guard let first = node.content?.first,
              first.type == "text",
              let text = first.text else { return nil }
        let checked: Bool
        let stripLength: Int
        if text.hasPrefix("[ ] ") { checked = false; stripLength = 4 }
        else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { checked = true; stripLength = 4 }
        else { return nil }
        var newContent = node.content ?? []
        let trimmedText = String(text.dropFirst(stripLength))
        if trimmedText.isEmpty {
            newContent.removeFirst()
        } else {
            newContent[0] = PMNode(type: "text", attrs: first.attrs, text: trimmedText, marks: first.marks)
        }
        return (checked, PMNode(type: node.type, attrs: node.attrs, content: newContent, text: nil, marks: nil))
    }

    private func appendTextblock(_ node: PMNode, spec: BlockSpec, into result: NSMutableAttributedString) {
        let line = NSMutableAttributedString()
        // Image positions inside `line` (local coords) so the post-stamp
        // pass can replace their proseNodePath with the leaf-extended path.
        var imagePositions: [(NSRange, [String: ProseAttrValue])] = []
        for child in node.content ?? [] {
            switch child.type {
            case "text":
                guard let text = child.text else { continue }
                var attrs = schemaMap.baseAttributes(for: spec, theme: theme)
                for mark in child.marks ?? [] {
                    schemaMap.applyMark(mark, to: &attrs, theme: theme)
                }
                line.append(NSAttributedString(string: text, attributes: attrs))
            case "hard_break":
                let attrs = schemaMap.baseAttributes(for: spec, theme: theme)
                line.append(NSAttributedString(string: "\n", attributes: attrs))
            case "image":
                let src = child.attrs?["src"]?.stringValue ?? ""
                let alt = child.attrs?["alt"]?.stringValue ?? ""
                let title = child.attrs?["title"]?.stringValue
                let attrs = schemaMap.baseAttributes(for: spec, theme: theme)
                let placeholder = alt.isEmpty ? "\u{FFFC}" : alt
                let before = line.length
                line.append(NSAttributedString(string: placeholder, attributes: attrs))
                var imgAttrs: [String: ProseAttrValue] = ["src": .string(src)]
                imgAttrs["alt"] = alt.isEmpty ? .null : .string(alt)
                imgAttrs["title"] = title.map(ProseAttrValue.string) ?? .null
                imagePositions.append((NSRange(location: before, length: line.length - before), imgAttrs))
            default:
                continue
            }
        }
        if line.length == 0 {
            let attrs = schemaMap.baseAttributes(for: spec, theme: theme)
            line.append(NSAttributedString(string: "", attributes: attrs))
        }
        if !line.string.hasSuffix("\n") {
            let nlAttrs = schemaMap.baseAttributes(for: spec, theme: theme)
            line.append(NSAttributedString(string: "\n", attributes: nlAttrs))
        }
        // Stamp the entire block with one NodePath run so the tree
        // builder sees one logical block (not one per inline child).
        let beforeLength = result.length
        result.append(line)
        let stampedLength = result.length - beforeLength
        if stampedLength > 0 {
            result.setBlockSpec(spec, in: NSRange(location: beforeLength, length: stampedLength))
            for (localRange, imgAttrs) in imagePositions {
                let absRange = NSRange(
                    location: beforeLength + localRange.location,
                    length: localRange.length
                )
                guard absRange.length > 0,
                      absRange.location + absRange.length <= result.length,
                      let basePath = result.nodePath(at: absRange.location) else { continue }
                let imageNode = ProseNode(type: "image", attrs: imgAttrs)
                let extended = basePath.appending(imageNode)
                result.setNodePath(extended, in: absRange)
            }
        }
    }

    private func appendLeafBlock(spec: BlockSpec, into result: NSMutableAttributedString) {
        let attrs = schemaMap.baseAttributes(for: spec, theme: theme)
        let beforeLength = result.length
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        let stampedLength = result.length - beforeLength
        if stampedLength > 0 {
            result.setBlockSpec(spec, in: NSRange(location: beforeLength, length: stampedLength))
        }
    }

    // MARK: encode

    public func encode(_ storage: NSAttributedString) -> PMNode {
        // Project storage to a tree first, then walk the tree directly.
        // The tree path captures marks via `MarkSet` rather than re-deriving
        // from rendering attributes, which keeps mark fidelity in nested
        // contexts. Refresh `proseMarks` from the rendering attributes so
        // post-mutation storage that didn't update its mark store still
        // emits correct marks.
        let mutable = NSMutableAttributedString(attributedString: storage)
        NodePathSynthesizer(schema: .defaultMarkdown).stampMarks(
            in: mutable,
            range: NSRange(location: 0, length: mutable.length)
        )
        let document = ProseDocument.from(storage: mutable, schema: .defaultMarkdown)
        return encode(document: document)
    }

    public func encodeToJSON(_ storage: NSAttributedString) throws -> Data {
        try JSONEncoder().encode(encode(storage))
    }

    /// Tree-direct encode: walk a `ProseDocument` and emit a PM tree.
    /// Marks come from inline runs' `MarkSet` directly rather than being
    /// re-extracted from rendering attributes, preserving mark fidelity
    /// across nested contexts. Tables encode their literal pipe-source
    /// paragraphs since the storage tree only carries a `table` envelope.
    public func encode(document: ProseDocument) -> PMNode {
        guard case .structural(_, let kids) = document.root else {
            return PMNode(type: "doc", content: nil)
        }
        let children = kids.compactMap { encodeBlock($0) }
        return PMNode(type: "doc", content: children.isEmpty ? nil : children)
    }

    private func encodeBlock(_ node: TreeNode) -> PMNode? {
        switch node {
        case .structural(let pn, let kids):
            switch pn.type {
            case "paragraph":
                return PMNode(type: "paragraph", content: encodeInlines(kids).orNilIfEmpty())
            case "heading":
                let level = pn.attrs["level"]?.intValue ?? 1
                return PMNode(
                    type: "heading",
                    attrs: ["level": .int(level)],
                    content: encodeInlines(kids).orNilIfEmpty()
                )
            case "blockquote":
                let inner = kids.compactMap { encodeBlock($0) }
                return PMNode(type: "blockquote", content: inner.orNilIfEmpty())
            case "bullet_list", "task_list":
                let items = kids.compactMap { encodeBlock($0) }
                return PMNode(type: "bullet_list", content: items.orNilIfEmpty())
            case "ordered_list":
                let items = kids.compactMap { encodeBlock($0) }
                let start = pn.attrs["start"]?.intValue ?? 1
                let attrs: [String: PMValue]? = (start != 1) ? ["order": .int(start)] : nil
                return PMNode(type: "ordered_list", attrs: attrs, content: items.orNilIfEmpty())
            case "list_item":
                var inner = kids.compactMap { encodeBlock($0) }
                // Task list_items carry `checked` in attrs; PM has no
                // native task type, so we render bullet items with a
                // `[x] ` / `[ ] ` text prefix.
                if let checked = pn.attrs["checked"]?.boolValue {
                    let prefix = checked ? "[x] " : "[ ] "
                    let prefixNode = PMNode(type: "text", text: prefix)
                    if let firstIdx = inner.firstIndex(where: { $0.type == "paragraph" }) {
                        var paragraph = inner[firstIdx]
                        var content = paragraph.content ?? []
                        content.insert(prefixNode, at: 0)
                        paragraph.content = content
                        inner[firstIdx] = paragraph
                    }
                }
                return PMNode(type: "list_item", content: inner.orNilIfEmpty())
            case "code_block":
                let language = pn.attrs["language"]?.stringValue ?? ""
                let body = kids.compactMap { kid -> String? in
                    if case .inline(let text, _) = kid { return text }
                    return nil
                }.joined()
                let inner: [PMNode]? = body.isEmpty ? nil : [PMNode(type: "text", text: body)]
                return PMNode(
                    type: "code_block",
                    attrs: ["params": .string(language)],
                    content: inner
                )
            case "table":
                // Emit as joined plain paragraph text — the storage tree
                // doesn't carry per-cell structure.
                let lines = kids.compactMap { kid -> String? in
                    guard case .structural(let pn, let inlineKids) = kid, pn.type == "paragraph" else { return nil }
                    return inlineKids.compactMap {
                        if case .inline(let text, _) = $0 { return text }
                        return nil
                    }.joined()
                }
                let textNodes = lines.enumerated().flatMap { idx, text -> [PMNode] in
                    var out: [PMNode] = []
                    if idx > 0 { out.append(PMNode(type: "hard_break")) }
                    if !text.isEmpty { out.append(PMNode(type: "text", text: text)) }
                    return out
                }
                return PMNode(type: "paragraph", content: textNodes.isEmpty ? nil : textNodes)
            default:
                return nil
            }
        case .leaf(let pn):
            switch pn.type {
            case "horizontal_rule":
                return PMNode(type: "horizontal_rule")
            case "hard_break":
                return PMNode(type: "hard_break")
            default:
                return nil
            }
        case .inline:
            // Top-level inline — wrap in a paragraph.
            return PMNode(type: "paragraph", content: encodeInlines([node]).orNilIfEmpty())
        }
    }

    private func encodeInlines(_ nodes: [TreeNode]) -> [PMNode] {
        var out: [PMNode] = []
        for node in nodes {
            switch node {
            case .inline(let text, let marks):
                guard !text.isEmpty else { continue }
                var pm = PMNode(type: "text", text: text)
                if !marks.isEmpty {
                    pm.marks = marks.marks.map { mark in
                        var attrs: [String: PMValue]? = nil
                        if !mark.attrs.isEmpty {
                            var dict: [String: PMValue] = [:]
                            for (k, v) in mark.attrs {
                                dict[k] = v.toPMValue()
                            }
                            attrs = dict
                        }
                        return PMMark(type: mark.type, attrs: attrs)
                    }
                }
                out.append(pm)
            case .leaf(let pn) where pn.type == "hard_break":
                out.append(PMNode(type: "hard_break"))
            case .leaf(let pn) where pn.type == "image":
                var pmAttrs: [String: PMValue] = [:]
                pmAttrs["src"] = .string(pn.attrs["src"]?.stringValue ?? "")
                if let alt = pn.attrs["alt"]?.stringValue {
                    pmAttrs["alt"] = .string(alt)
                } else {
                    pmAttrs["alt"] = .null
                }
                if let title = pn.attrs["title"]?.stringValue {
                    pmAttrs["title"] = .string(title)
                } else {
                    pmAttrs["title"] = .null
                }
                out.append(PMNode(type: "image", attrs: pmAttrs))
            case .leaf, .structural:
                continue
            }
        }
        return out
    }

}

// MARK: - tree-direct helpers

private extension ProseAttrValue {
    func toPMValue() -> PMValue {
        switch self {
        case .null: return .null
        case .bool(let v): return .bool(v)
        case .int(let v): return .int(v)
        case .double(let v): return .double(v)
        case .string(let v): return .string(v)
        }
    }
}

private extension Array where Element == PMNode {
    func orNilIfEmpty() -> [PMNode]? {
        isEmpty ? nil : self
    }
}

// MARK: - context, supporting types

struct BlockContext {
    var blockquoteDepth = 0
    var listLevel = 0
    var listStack: [ListKind] = []
    var orderedIndex = 1

    enum ListKind: Equatable {
        case unordered
        case ordered(start: Int)
    }

    mutating func pushList(_ kind: ListKind) { listStack.append(kind) }
    mutating func popList() { listStack.removeLast() }

    mutating func incrementOrderedIndex() {
        if case .ordered = listStack.last { orderedIndex += 1 }
    }

    func makeBlockSpec(kind: BlockSpec.Kind) -> BlockSpec {
        var finalKind = kind
        if case .paragraph = kind, let listKind = listStack.last {
            switch listKind {
            case .unordered:
                finalKind = .unorderedListItem
            case .ordered:
                finalKind = .orderedListItem(index: orderedIndex)
            }
        }
        return BlockSpec(kind: finalKind, blockquoteDepth: blockquoteDepth, listLevel: listLevel)
    }
}

// MARK: - SchemaMap

public struct SchemaMap {
    public typealias MarkApplier = (PMMark, inout [NSAttributedString.Key: Any], ProseTheme) -> Void
    public typealias MarkExtractor = ([NSAttributedString.Key: Any]) -> PMMark?

    var markAppliers: [String: MarkApplier] = [:]
    var markExtractors: [String: MarkExtractor] = [:]

    public init() {}

    public mutating func registerMark(
        _ name: String,
        apply: @escaping MarkApplier,
        extract: @escaping MarkExtractor
    ) {
        markAppliers[name] = apply
        markExtractors[name] = extract
    }

    public func applyMark(_ mark: PMMark, to attrs: inout [NSAttributedString.Key: Any], theme: ProseTheme) {
        markAppliers[mark.type]?(mark, &attrs, theme)
    }

    public func extractMarks(from attrs: [NSAttributedString.Key: Any]) -> [PMMark] {
        markExtractors.compactMap { (_, extractor) in extractor(attrs) }
    }

    public func baseAttributes(for spec: BlockSpec, theme: ProseTheme) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor
        ]
        switch spec.kind {
        case .heading(let level):
            attrs[.font] = theme.headingFont(level: level)
        case .fencedCode, .indentedCode:
            attrs[.font] = theme.monospaceFont
        default:
            break
        }
        return attrs
    }

    public static var basic: SchemaMap {
        var map = SchemaMap()
        map.registerMark(
            "strong",
            apply: { _, attrs, theme in
                let font = (attrs[.font] as? PlatformFont) ?? theme.bodyFont
                attrs[.font] = font.addingBoldTrait()
            },
            extract: { attrs in
                guard let font = attrs[.font] as? PlatformFont, font.hasBoldTrait else { return nil }
                return PMMark(type: "strong")
            }
        )
        map.registerMark(
            "em",
            apply: { _, attrs, theme in
                let font = (attrs[.font] as? PlatformFont) ?? theme.bodyFont
                attrs[.font] = font.addingItalicTrait()
            },
            extract: { attrs in
                guard let font = attrs[.font] as? PlatformFont, font.hasItalicTrait else { return nil }
                return PMMark(type: "em")
            }
        )
        map.registerMark(
            "link",
            apply: { mark, attrs, theme in
                guard let href = mark.attrs?["href"]?.stringValue else { return }
                attrs[.link] = href
                attrs[.proseLink] = href
                attrs[.foregroundColor] = theme.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            },
            extract: { attrs in
                guard let href = attrs[.proseLink] as? String else { return nil }
                return PMMark(type: "link", attrs: ["href": .string(href)])
            }
        )
        map.registerMark(
            "code",
            apply: { _, attrs, theme in
                attrs[.font] = theme.monospaceFont
                attrs[.proseInline] = InlineTag.codeSpan
            },
            extract: { attrs in
                guard (attrs[.proseInline] as? InlineTag) == .codeSpan else { return nil }
                return PMMark(type: "code")
            }
        )
        map.registerMark(
            "strike",
            apply: { _, attrs, _ in
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            },
            extract: { attrs in
                guard let v = attrs[.strikethroughStyle] as? Int, v != 0 else { return nil }
                return PMMark(type: "strike")
            }
        )
        return map
    }
}

// MARK: - PlatformFont trait helpers

extension PlatformFont {
    var hasBoldTrait: Bool {
        #if canImport(AppKit) && os(macOS)
        return fontDescriptor.symbolicTraits.contains(.bold)
        #else
        return fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    var hasItalicTrait: Bool {
        #if canImport(AppKit) && os(macOS)
        return fontDescriptor.symbolicTraits.contains(.italic)
        #else
        return fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    func addingBoldTrait() -> PlatformFont {
        #if canImport(AppKit) && os(macOS)
        var traits = fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let desc = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        traits.insert(.traitBold)
        guard let desc = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: desc, size: pointSize)
        #endif
    }

    func addingItalicTrait() -> PlatformFont {
        #if canImport(AppKit) && os(macOS)
        var traits = fontDescriptor.symbolicTraits
        traits.insert(.italic)
        let desc = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: pointSize) ?? self
        #else
        var traits = fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        guard let desc = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: desc, size: pointSize)
        #endif
    }
}
