import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Serializes a `ProseDocument` tree back into markdown source.
/// Mark-order ambiguity is resolved by the schema's `markTypeOrder` so the
/// same tree always emits the same bytes.
public struct MarkdownTreeSerializer {
    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    public func serialize(_ document: ProseDocument) -> String {
        guard case .structural(_, let kids) = document.root else { return "" }
        var ctx = Context()
        for child in kids {
            emitBlock(child, ctx: &ctx)
        }
        return ensureTrailingNewline(ctx.output)
    }

    // MARK: - block emission

    private struct Context {
        var output: String = ""
        var blockquoteDepth: Int = 0
        var listLevel: Int = 0
        /// Per-level marker width in characters. Bullet/task = 2 ("- " or
        /// "- [x] "). Ordered = digits-of-max-marker + 2 for ". " (e.g.
        /// "1. " = 3, "10. " = 4). Mirrors prosemirror-markdown's
        /// `wrapBlock` indent calculation so a nested block under a
        /// list_item lines up with the start of the marker's content.
        var listMarkerWidths: [Int] = []
        /// Number of block-level emits at the current level — used to
        /// decide whether to insert a blank-line separator before this
        /// block.
        var blocksAtThisLevel: Int = 0

        mutating func emitNewline() {
            if !output.hasSuffix("\n") { output.append("\n") }
        }

        mutating func emitBlankLineBetweenBlocks() {
            if blocksAtThisLevel == 0 { return }
            // Ensure exactly one blank line between blocks (two "\n").
            while output.hasSuffix("\n\n") { break }
            if !output.hasSuffix("\n") { output.append("\n") }
            output.append("\n")
        }

        /// Indent (in spaces) for content sitting at the given list level.
        /// Sums each outer level's marker width.
        func listIndentSpaces(through level: Int) -> String {
            let count = listMarkerWidths.prefix(max(0, level)).reduce(0, +)
            return String(repeating: " ", count: count)
        }
    }

    private func emitBlock(_ node: TreeNode, ctx: inout Context) {
        switch node {
        case .structural(let pn, let kids):
            switch pn.type {
            case "paragraph": emitParagraph(kids, attrs: pn.attrs, ctx: &ctx)
            case "heading": emitHeading(level: pn.attrs["level"]?.intValue ?? 1, kids: kids, ctx: &ctx)
            case "blockquote": emitBlockquote(kids, ctx: &ctx)
            case "bullet_list": emitBulletList(kids, ctx: &ctx)
            case "ordered_list":
                let start = pn.attrs["order"]?.intValue ?? 1
                emitOrderedList(start: start, kids: kids, ctx: &ctx)
            case "task_list": emitTaskList(kids, ctx: &ctx)
            case "list_item": emitListItem(node: pn, kids: kids, ctx: &ctx)
            case "code_block":
                let params = pn.attrs["params"]?.stringValue
                let language = (params?.isEmpty == false) ? params : nil
                let fenced = pn.attrs["fenced"]?.boolValue ?? true
                emitCodeBlock(kids: kids, language: language, fenced: fenced, ctx: &ctx)
            case "html_block": emitOpaque(kids: kids, ctx: &ctx)
            case "table": emitTable(kids, ctx: &ctx)
            default:
                // Unknown structural node — fall back to walking its
                // children at the current level so content survives even
                // if the wrapping is unrecognized.
                for child in kids { emitBlock(child, ctx: &ctx) }
            }
        case .leaf(let pn):
            switch pn.type {
            case "horizontal_rule":
                ctx.emitBlankLineBetweenBlocks()
                ctx.output.append(blockLinePrefix(ctx))
                ctx.output.append("---")
                ctx.emitNewline()
                ctx.blocksAtThisLevel += 1
            case "link_reference":
                let label = pn.attrs["label"]?.stringValue ?? ""
                let href = pn.attrs["href"]?.stringValue ?? ""
                let title = pn.attrs["title"]?.stringValue
                ctx.emitBlankLineBetweenBlocks()
                ctx.output.append(blockLinePrefix(ctx))
                if let title, !title.isEmpty {
                    ctx.output.append("[\(label)]: \(href) \"\(title)\"")
                } else {
                    ctx.output.append("[\(label)]: \(href)")
                }
                ctx.emitNewline()
                ctx.blocksAtThisLevel += 1
            default: break
            }
        case .inline:
            // Inline at top level — wrap in an implicit paragraph.
            emitParagraph([node], attrs: [:], ctx: &ctx)
        }
    }

    private func blockLinePrefix(_ ctx: Context) -> String {
        String(repeating: "> ", count: max(0, ctx.blockquoteDepth))
    }

    private func listIndent(_ ctx: Context) -> String {
        ctx.listIndentSpaces(through: ctx.listLevel)
    }

    private func emitParagraph(_ kids: [TreeNode], attrs: [String: ProseAttrValue], ctx: inout Context) {
        ctx.emitBlankLineBetweenBlocks()
        let prefix = blockLinePrefix(ctx) + listIndent(ctx)
        let inline = renderInline(kids)
        // Multi-line paragraphs (with hard breaks) get the prefix on each
        // resulting line; markdown convention.
        let lines = inline.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            ctx.output.append(prefix)
            ctx.output.append(String(line))
            if i < lines.count - 1 { ctx.output.append("\n") }
        }
        ctx.emitNewline()
        ctx.blocksAtThisLevel += 1
    }

    private func emitHeading(level: Int, kids: [TreeNode], ctx: inout Context) {
        ctx.emitBlankLineBetweenBlocks()
        let lvl = max(1, min(6, level))
        ctx.output.append(blockLinePrefix(ctx))
        ctx.output.append(String(repeating: "#", count: lvl))
        ctx.output.append(" ")
        ctx.output.append(renderInline(kids))
        ctx.emitNewline()
        ctx.blocksAtThisLevel += 1
    }

    private func emitBlockquote(_ kids: [TreeNode], ctx: inout Context) {
        ctx.emitBlankLineBetweenBlocks()
        ctx.blockquoteDepth += 1
        let savedBlocksAtThisLevel = ctx.blocksAtThisLevel
        ctx.blocksAtThisLevel = 0
        for child in kids {
            emitBlock(child, ctx: &ctx)
        }
        ctx.blockquoteDepth -= 1
        ctx.blocksAtThisLevel = savedBlocksAtThisLevel + 1
    }

    private func emitBulletList(_ items: [TreeNode], ctx: inout Context) {
        ctx.emitBlankLineBetweenBlocks()
        ctx.listLevel += 1
        ctx.listMarkerWidths.append(2)
        let savedBlocks = ctx.blocksAtThisLevel
        ctx.blocksAtThisLevel = 0
        for item in items {
            emitListItemMarker("- ", node: item, ctx: &ctx)
        }
        ctx.listLevel -= 1
        ctx.listMarkerWidths.removeLast()
        ctx.blocksAtThisLevel = savedBlocks + 1
    }

    private func emitOrderedList(start: Int, kids: [TreeNode], ctx: inout Context) {
        ctx.emitBlankLineBetweenBlocks()
        ctx.listLevel += 1
        // prosemirror-markdown picks the indent off the *widest* marker
        // any item in this list will get, so all rows line up with the
        // first marker's content column.
        let lastIndex = start + max(0, kids.count - 1)
        let maxDigits = String(lastIndex).count
        ctx.listMarkerWidths.append(maxDigits + 2) // ". "
        var counter = start
        let savedBlocks = ctx.blocksAtThisLevel
        ctx.blocksAtThisLevel = 0
        for item in kids {
            let raw = "\(counter). "
            let pad = String(repeating: " ", count: max(0, (maxDigits + 2) - (raw as NSString).length))
            emitListItemMarker(pad + raw, node: item, ctx: &ctx)
            counter += 1
        }
        ctx.listLevel -= 1
        ctx.listMarkerWidths.removeLast()
        ctx.blocksAtThisLevel = savedBlocks + 1
    }

    private func emitTaskList(_ kids: [TreeNode], ctx: inout Context) {
        ctx.emitBlankLineBetweenBlocks()
        ctx.listLevel += 1
        ctx.listMarkerWidths.append(2)
        let savedBlocks = ctx.blocksAtThisLevel
        ctx.blocksAtThisLevel = 0
        for item in kids {
            let checked: Bool = {
                if case .structural(let n, _) = item {
                    return n.attrs["checked"]?.boolValue ?? false
                }
                return false
            }()
            emitListItemMarker("- [\(checked ? "x" : " ")] ", node: item, ctx: &ctx)
        }
        ctx.listLevel -= 1
        ctx.listMarkerWidths.removeLast()
        ctx.blocksAtThisLevel = savedBlocks + 1
    }

    private func emitListItemMarker(_ marker: String, node: TreeNode, ctx: inout Context) {
        guard case .structural(_, let kids) = node else { return }
        // Emit the marker as a manual leading prefix on the FIRST inline
        // paragraph child; subsequent children get a hanging-indent.
        var first = true
        for child in kids {
            if first {
                first = false
                emitListItemFirstChild(marker: marker, child: child, ctx: &ctx)
                // Children that follow the marker line (e.g. a nested list)
                // belong to the same list_item — drop the prior block count
                // so they don't trigger a blank-line separator before the
                // first nested block.
                ctx.blocksAtThisLevel = 0
            } else {
                emitBlock(child, ctx: &ctx)
            }
        }
    }

    private func emitListItemFirstChild(marker: String, child: TreeNode, ctx: inout Context) {
        let preMarker = ctx.listIndentSpaces(through: ctx.listLevel - 1)
        switch child {
        case .structural(let pn, let kids) where pn.type == "paragraph":
            ctx.output.append(blockLinePrefix(ctx))
            ctx.output.append(preMarker)
            ctx.output.append(marker)
            ctx.output.append(renderInline(kids))
            ctx.emitNewline()
            ctx.blocksAtThisLevel += 1
        default:
            // Marker still leads even when first child isn't a paragraph;
            // emit it on its own line, then recurse.
            ctx.output.append(blockLinePrefix(ctx))
            ctx.output.append(preMarker)
            ctx.output.append(marker.trimmingCharacters(in: .whitespaces))
            ctx.emitNewline()
            ctx.blocksAtThisLevel += 1
            emitBlock(child, ctx: &ctx)
        }
    }

    private func emitListItem(node: ProseNode, kids: [TreeNode], ctx: inout Context) {
        // Stand-alone list_item without a parent list — uncommon. Emit as
        // a bullet for compatibility.
        emitListItemMarker("- ", node: .structural(node, kids), ctx: &ctx)
    }

    private func emitCodeBlock(kids: [TreeNode], language: String?, fenced: Bool, ctx: inout Context) {
        ctx.emitBlankLineBetweenBlocks()
        let prefix = blockLinePrefix(ctx)
        let body = kids.compactMap { kid -> String? in
            if case .inline(let text, _) = kid { return text }
            return nil
        }.joined()
        if fenced {
            let lang = language ?? ""
            ctx.output.append(prefix)
            ctx.output.append("```\(lang)\n")
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                ctx.output.append(prefix)
                ctx.output.append(String(line))
                ctx.output.append("\n")
            }
            ctx.output.append(prefix)
            ctx.output.append("```")
            ctx.emitNewline()
        } else {
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                ctx.output.append(prefix)
                ctx.output.append("    ")
                ctx.output.append(String(line))
                ctx.output.append("\n")
            }
        }
        ctx.blocksAtThisLevel += 1
    }

    private func emitOpaque(kids: [TreeNode], ctx: inout Context) {
        ctx.emitBlankLineBetweenBlocks()
        let prefix = blockLinePrefix(ctx)
        let body = kids.compactMap { kid -> String? in
            if case .inline(let text, _) = kid { return text }
            return nil
        }.joined()
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            ctx.output.append(prefix)
            ctx.output.append(String(line))
            ctx.output.append("\n")
        }
        ctx.blocksAtThisLevel += 1
    }

    private func emitTable(_ rows: [TreeNode], ctx: inout Context) {
        // When the tree carries `table_row` → `table_cell` → `paragraph`
        // children we emit canonical pipe markdown; otherwise children are
        // emitted as their literal pipe-source paragraphs.
        ctx.emitBlankLineBetweenBlocks()
        let prefix = blockLinePrefix(ctx)
        var emittedAsTable = false
        var headerRow: [String]? = nil
        var bodyRows: [[String]] = []
        var alignments: [PipeTableAlignment] = []
        for row in rows {
            guard case .structural(let rowNode, let cellNodes) = row,
                  rowNode.type == "table_row" else { continue }
            let cells = cellNodes.compactMap { node -> String? in
                guard case .structural(let cellNode, let cellKids) = node else { return nil }
                guard cellNode.type == "table_cell" || cellNode.type == "table_header" else { return nil }
                if alignments.count < cellNodes.count {
                    let align = cellNode.attrs["align"]?.stringValue
                    alignments.append(parseAlign(align))
                }
                return cellKids.compactMap {
                    if case .structural(let p, let inlineKids) = $0, p.type == "paragraph" {
                        return renderInline(inlineKids)
                    }
                    return nil
                }.joined(separator: " ")
            }
            if rowNode.attrs["header"]?.boolValue == true, headerRow == nil {
                headerRow = cells
            } else {
                bodyRows.append(cells)
            }
            emittedAsTable = true
        }
        if emittedAsTable, let headerRow {
            let cols = headerRow.count
            while alignments.count < cols { alignments.append(.none) }
            ctx.output.append(prefix)
            ctx.output.append(rowLine(headerRow, cols: cols))
            ctx.output.append("\n")
            ctx.output.append(prefix)
            ctx.output.append(alignLine(alignments, cols: cols))
            ctx.output.append("\n")
            for row in bodyRows {
                ctx.output.append(prefix)
                ctx.output.append(rowLine(row, cols: cols))
                ctx.output.append("\n")
            }
            ctx.blocksAtThisLevel += 1
            return
        }
        // Fallback: tree wraps consecutive table paragraphs in a `table`
        // envelope without breaking out cells. Emit each child paragraph's
        // literal inline text so the pipe source round-trips byte-for-byte.
        for child in rows {
            switch child {
            case .structural(_, let kids):
                let inline = renderInline(kids)
                ctx.output.append(prefix)
                ctx.output.append(inline)
                ctx.output.append("\n")
            default: break
            }
        }
        ctx.blocksAtThisLevel += 1
    }

    private func rowLine(_ cells: [String], cols: Int) -> String {
        var parts: [String] = []
        for i in 0..<cols {
            parts.append(" \(i < cells.count ? cells[i] : "") ")
        }
        return "|" + parts.joined(separator: "|") + "|"
    }

    private func alignLine(_ aligns: [PipeTableAlignment], cols: Int) -> String {
        var parts: [String] = []
        for i in 0..<cols {
            let token = (i < aligns.count ? aligns[i] : .none).alignmentRowToken
            parts.append(" \(token) ")
        }
        return "|" + parts.joined(separator: "|") + "|"
    }

    private func parseAlign(_ s: String?) -> PipeTableAlignment {
        switch s {
        case "left": return .left
        case "right": return .right
        case "center": return .center
        default: return .none
        }
    }

    // MARK: - inline emission

    private func renderInline(_ kids: [TreeNode]) -> String {
        var result = ""
        for child in kids {
            switch child {
            case .inline(let text, let marks):
                result.append(emitInline(text: text, marks: marks))
            case .leaf(let node) where node.type == "hard_break":
                result.append("  \n")
            case .leaf(let node) where node.type == "image":
                result.append(emitImage(node))
            case .leaf:
                continue
            case .structural:
                // Nested structural nodes inside an inline context
                // shouldn't happen in our schema; render as if they were
                // inline runs of their flattened content.
                continue
            }
        }
        return result
    }

    private func emitImage(_ node: ProseNode) -> String {
        let src = node.attrs["src"]?.stringValue ?? ""
        let alt = node.attrs["alt"]?.stringValue ?? ""
        let title = node.attrs["title"]?.stringValue
        let escapedSrc = src
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        if let title, !title.isEmpty {
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            return "![\(alt)](\(escapedSrc) \"\(escapedTitle)\")"
        }
        return "![\(alt)](\(escapedSrc))"
    }

    private func emitInline(text: String, marks: MarkSet) -> String {
        guard !text.isEmpty else { return "" }
        var inner = text
        // Sort marks in declared rank order so output is deterministic
        // regardless of how the marks were applied.
        let ordered = marks.marks.sorted { schema.rank(ofMark: $0.type) < schema.rank(ofMark: $1.type) }
        // Special-case marks that change the inner text shape.
        if let codeMark = ordered.first(where: { $0.type == "code" }) {
            _ = codeMark // existence is what we need
            inner = "`\(inner)`"
            // Code excludes other inline marks per schema; emit only it.
            if let link = ordered.first(where: { $0.type == "link" }) {
                let href = link.attrs["href"]?.stringValue ?? ""
                inner = "[\(inner)](\(href))"
            }
            return inner
        }
        // Bold + italic combine into "***x***" when both apply.
        let bold = marks.contains(type: "strong")
        let em = marks.contains(type: "em")
        let strike = marks.contains(type: "strike")
        if bold && em {
            inner = "***\(inner)***"
        } else if bold {
            inner = "**\(inner)**"
        } else if em {
            inner = "*\(inner)*"
        }
        if strike {
            inner = "~~\(inner)~~"
        }
        if let link = ordered.first(where: { $0.type == "link" }) {
            let href = link.attrs["href"]?.stringValue ?? ""
            inner = "[\(inner)](\(href))"
        }
        return inner
    }

    // MARK: - helpers

    private func ensureTrailingNewline(_ s: String) -> String {
        if s.isEmpty { return "" }
        return s.hasSuffix("\n") ? s : s + "\n"
    }
}
