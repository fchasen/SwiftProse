import Foundation
import SwiftProseSyntax
import SwiftProseRendering

/// Renders a `Fragment` as the text the editor shows — the pasteboard's
/// plain-text form. No markdown: marks are dropped, list items keep the
/// marker they display (`•` / `◦` / `▪` / `▫` by level, `1.` / `a.` /
/// `i.`, `☐` / `☑`) indented one tab per nesting level, table rows are
/// tab-separated lines, hard breaks are newlines, images are their alt
/// text. Blocks are separated by a single newline, as in storage.
public struct PlainTextSerializer {

    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    public func serialize(_ fragment: Fragment) -> String {
        var lines: [String] = []
        var inlineRun: String?
        for kid in fragment.children {
            if isInline(kid) {
                inlineRun = (inlineRun ?? "") + inlineText(kid)
            } else {
                if let run = inlineRun {
                    lines.append(run)
                    inlineRun = nil
                }
                lines.append(contentsOf: blockLines(kid, level: 0))
            }
        }
        if let run = inlineRun { lines.append(run) }
        return lines.joined(separator: "\n")
    }

    // MARK: - blocks

    /// `level` is the list nesting depth; only list markers use it.
    private func blockLines(_ node: TreeNode, level: Int) -> [String] {
        switch node {
        case .inline, .leaf:
            return [inlineText(node)]
        case .structural(let pn, let kids):
            switch pn.type {
            case "bullet_list", "ordered_list", "task_list":
                return listLines(pn, items: kids, level: level)
            case "list_item":
                return itemLines(node, marker: bulletGlyph(level), level: level)
            case "table":
                return [kids.map(rowText).joined(separator: "\n")]
            case "table_row":
                return [rowText(node)]
            case "code_block", "html_block":
                return [droppingTerminator(rawText(kids))]
            case "paragraph", "heading", "table_cell", "table_header", "link_reference":
                return [inlineText(kids)]
            default:
                return kids.flatMap { blockLines($0, level: level) }
            }
        }
    }

    private func listLines(_ list: ProseNode, items: [TreeNode], level: Int) -> [String] {
        let start = list.attrs["order"]?.intValue
            ?? items.first?.node?.attrs["order"]?.intValue
            ?? 1
        var lines: [String] = []
        for (i, item) in items.enumerated() {
            let marker: String
            switch list.type {
            case "ordered_list":
                let index = item.node?.attrs["order"]?.intValue ?? (start + i)
                marker = OrderedMarkerFormatter.format(
                    index: index,
                    style: OrderedMarkerFormatter.style(forLevel: level)
                )
            case "task_list":
                marker = (item.node?.attrs["checked"]?.boolValue ?? false) ? "☑" : "☐"
            default:
                marker = bulletGlyph(level)
            }
            lines.append(contentsOf: itemLines(item, marker: marker, level: level))
        }
        return lines
    }

    /// The marker leads the item's first line; nested lists indent one
    /// level deeper.
    private func itemLines(_ item: TreeNode, marker: String, level: Int) -> [String] {
        let indent = String(repeating: "\t", count: level)
        guard case .structural(_, let kids) = item, !kids.isEmpty else {
            return [indent + marker + " " + inlineText(item)]
        }
        var lines: [String] = []
        for (i, child) in kids.enumerated() {
            let childLines = blockLines(child, level: level + 1)
            if i == 0 {
                lines.append(indent + marker + " " + (childLines.first ?? ""))
                lines.append(contentsOf: childLines.dropFirst())
            } else {
                lines.append(contentsOf: childLines)
            }
        }
        return lines
    }

    private func bulletGlyph(_ level: Int) -> String {
        switch BulletGlyphAttachment.Shape.forLevel(level) {
        case .filledDisc: return "•"
        case .strokedCircle: return "◦"
        case .filledSquare: return "▪"
        case .strokedSquare: return "▫"
        }
    }

    private func rowText(_ row: TreeNode) -> String {
        row.children.map { inlineText($0.children) }.joined(separator: "\t")
    }

    // MARK: - inline

    private func isInline(_ node: TreeNode) -> Bool {
        switch node {
        case .inline: return true
        case .leaf(let pn, _): return schema.nodeType(pn.type)?.isInline ?? false
        case .structural: return false
        }
    }

    private func inlineText(_ kids: [TreeNode]) -> String {
        kids.map(inlineText).joined()
    }

    private func inlineText(_ node: TreeNode) -> String {
        switch node {
        case .inline(let text, _):
            return text
        case .leaf(let pn, _):
            switch pn.type {
            case "hard_break": return "\n"
            case "image": return pn.attrs["alt"]?.stringValue ?? ""
            case InlineContentNode.type: return pn.attrs[InlineContentNode.rawAttr]?.stringValue ?? ""
            default: return ""
            }
        case .structural(_, let kids):
            return inlineText(kids)
        }
    }

    private func rawText(_ kids: [TreeNode]) -> String {
        var out = ""
        for kid in kids {
            if case .inline(let text, _) = kid { out.append(text) }
        }
        return out
    }

    /// A code block's inline text carries the block's own terminator in a
    /// projected tree; the caller joins blocks with newlines already.
    private func droppingTerminator(_ s: String) -> String {
        s.hasSuffix("\n") ? String(s.dropLast()) : s
    }
}
