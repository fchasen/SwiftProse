import Foundation
import SwiftProseSyntax

/// Walks a `Fragment` and emits an HTML representation. Mirrors PM's
/// `DOMSerializer` — each node type maps to a single HTML element (with
/// any attributes), each mark to a wrapping element. Open marks wrap
/// inline content as they're entered and unwrap as they're exited so
/// adjacent runs that share a prefix mark set share their wrapper.
///
/// Phase 3 covers the core schema types: paragraph, heading, blockquote,
/// hr, list/list_item, code_block, hard_break, image; marks: strong, em,
/// code, link, strike. Unknown types fall back to a generic element so
/// content isn't lost — Phase 4's parser will skip the unknown wrapper.
public struct DOMSerializer {

    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    public func serialize(_ fragment: Fragment) -> String {
        var out = ""
        for kid in fragment.children {
            renderNode(kid, into: &out)
        }
        return out
    }

    /// Order in which to nest marks. PM lets the schema declare mark
    /// order; we match `schema.markTypeOrder` so encode is deterministic
    /// and decode can rely on a stable nesting.
    private var markOrder: [MarkType.Name] {
        schema.markTypeOrder
    }

    private func renderNode(_ node: TreeNode, into out: inout String) {
        switch node {
        case .inline(let text, let marks):
            let escaped = escapeText(text)
            out.append(applyMarks(marks, to: escaped))
        case .leaf(let pn, let marks):
            let body = renderLeaf(pn)
            if marks.isEmpty {
                out.append(body)
            } else {
                out.append(applyMarks(marks, to: body))
            }
        case .structural(let pn, let kids):
            out.append(renderStructural(pn, kids: kids))
        }
    }

    private func renderStructural(_ pn: ProseNode, kids: [TreeNode]) -> String {
        let inner = inlineRender(kids)
        switch pn.type {
        case "paragraph": return "<p>\(inner)</p>"
        case "heading":
            let level = pn.attrs["level"]?.intValue ?? 1
            let n = max(1, min(6, level))
            return "<h\(n)>\(inner)</h\(n)>"
        case "blockquote": return "<blockquote>\(blockRender(kids))</blockquote>"
        case "bullet_list": return "<ul>\(blockRender(kids))</ul>"
        case "ordered_list":
            let order = pn.attrs["order"]?.intValue ?? 1
            let startAttr = order == 1 ? "" : " start=\"\(order)\""
            return "<ol\(startAttr)>\(blockRender(kids))</ol>"
        case "list_item": return "<li>\(blockRender(kids))</li>"
        case "task_list": return "<ul data-task-list=\"true\">\(blockRender(kids))</ul>"
        case "code_block":
            let params = pn.attrs["params"]?.stringValue ?? ""
            let langAttr = params.isEmpty ? "" : " class=\"language-\(escapeAttr(params))\""
            return "<pre><code\(langAttr)>\(escapeText(rawText(kids)))</code></pre>"
        case "html_block":
            // Round-trip raw HTML content directly. Inline children carry it.
            return rawText(kids)
        case "table": return "<table>\(blockRender(kids))</table>"
        case "table_row": return "<tr>\(blockRender(kids))</tr>"
        case "table_cell":
            let align = pn.attrs["align"]?.stringValue
            let style = align.flatMap { $0.isEmpty ? nil : "text-align:\($0)" }
            let styleAttr = style.map { " style=\"\($0)\"" } ?? ""
            return "<td\(styleAttr)>\(inlineRender(kids))</td>"
        case "table_header":
            let align = pn.attrs["align"]?.stringValue
            let style = align.flatMap { $0.isEmpty ? nil : "text-align:\($0)" }
            let styleAttr = style.map { " style=\"\($0)\"" } ?? ""
            return "<th\(styleAttr)>\(inlineRender(kids))</th>"
        default:
            return "<div data-prose-node=\"\(escapeAttr(pn.type))\">\(blockRender(kids))</div>"
        }
    }

    private func blockRender(_ kids: [TreeNode]) -> String {
        var out = ""
        for kid in kids { renderNode(kid, into: &out) }
        return out
    }

    private func inlineRender(_ kids: [TreeNode]) -> String {
        var out = ""
        // For inline content, merge adjacent runs sharing the same mark
        // prefix into a single wrapper. PM's DOMSerializer does this so
        // `**a** **b**` round-trips as `<strong>a</strong><strong>b</strong>`
        // rather than `<strong>a b</strong>` — but adjacent identical-mark
        // runs already collapse upstream (the codec's pmMarksEqual). We
        // just emit each run individually here.
        for kid in kids {
            renderNode(kid, into: &out)
        }
        return out
    }

    private func renderLeaf(_ pn: ProseNode) -> String {
        switch pn.type {
        case "hard_break": return "<br>"
        case "horizontal_rule": return "<hr>"
        case "image":
            let src = pn.attrs["src"]?.stringValue ?? ""
            let alt = pn.attrs["alt"]?.stringValue ?? ""
            let title = pn.attrs["title"]?.stringValue ?? ""
            var attrs = "src=\"\(escapeAttr(src))\""
            if !alt.isEmpty { attrs += " alt=\"\(escapeAttr(alt))\"" }
            if !title.isEmpty { attrs += " title=\"\(escapeAttr(title))\"" }
            return "<img \(attrs)>"
        case InlineContentNode.type:
            let kind = pn.attrs[InlineContentNode.kindAttr]?.stringValue ?? ""
            let raw = pn.attrs[InlineContentNode.rawAttr]?.stringValue ?? ""
            // `raw` rides an attribute, not the text node: HTML collapses
            // whitespace in text, and the source has to come back byte-exact.
            return "<span data-prose-leaf=\"inline_content\" data-kind=\"\(escapeAttr(kind))\""
                + " data-raw=\"\(escapeAttr(raw))\">\(escapeText(raw))</span>"
        default:
            return "<span data-prose-leaf=\"\(escapeAttr(pn.type))\"></span>"
        }
    }

    private func rawText(_ kids: [TreeNode]) -> String {
        var out = ""
        for kid in kids {
            if case .inline(let text, _) = kid {
                out.append(text)
            }
        }
        return out
    }

    // MARK: - mark wrapping

    private func applyMarks(_ marks: MarkSet, to inner: String) -> String {
        guard !marks.isEmpty else { return inner }
        // Sort the active marks by schema.markTypeOrder so nesting is
        // deterministic and round-trippable.
        let sorted = sortedMarks(marks)
        var out = inner
        // Innermost first → outermost — apply in reverse order so the
        // outermost is the first listed in markOrder.
        for mark in sorted.reversed() {
            out = wrapWithMark(mark, inner: out)
        }
        return out
    }

    private func sortedMarks(_ marks: MarkSet) -> [ProseMark] {
        let order = markOrder
        return marks.marks.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.type) ?? Int.max
            let ri = order.firstIndex(of: rhs.type) ?? Int.max
            if li != ri { return li < ri }
            return lhs.type < rhs.type
        }
    }

    private func wrapWithMark(_ mark: ProseMark, inner: String) -> String {
        switch mark.type {
        case "strong": return "<strong>\(inner)</strong>"
        case "em": return "<em>\(inner)</em>"
        case "code": return "<code>\(inner)</code>"
        case "strike": return "<s>\(inner)</s>"
        case "link":
            let href = mark.attrs["href"]?.stringValue ?? ""
            let title = mark.attrs["title"]?.stringValue ?? ""
            let titleAttr = title.isEmpty ? "" : " title=\"\(escapeAttr(title))\""
            return "<a href=\"\(escapeAttr(href))\"\(titleAttr)>\(inner)</a>"
        default:
            return "<span data-prose-mark=\"\(escapeAttr(mark.type))\">\(inner)</span>"
        }
    }

    // MARK: - escaping

    private func escapeText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default: out.append(ch)
            }
        }
        return out
    }

    private func escapeAttr(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }
}
