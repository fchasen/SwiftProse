import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@_spi(Harness) import SwiftProse

/// Paragraph-by-paragraph dump of the text storage: what a failure message
/// needs to explain *why* an oracle tripped, in a form that diffs cleanly.
enum StorageDump {

    /// `range | text | block | lists | intent runs | literals | atoms`, one
    /// row per paragraph.
    static func dump(_ storage: NSAttributedString, includesGeometry: Bool = true) -> String {
        var lines = ["length \(storage.length)", String(repeating: "-", count: 72)]
        lines += rows(storage, includesGeometry: includesGeometry)
        return lines.joined(separator: "\n")
    }

    static func rows(_ storage: NSAttributedString, includesGeometry: Bool = false) -> [String] {
        guard storage.length > 0 else { return [] }
        return storage.markdownParagraphRanges().filter { $0.length > 0 }.map {
            row(storage, $0, includesGeometry: includesGeometry)
        }
    }

    private static func row(_ storage: NSAttributedString, _ range: NSRange, includesGeometry: Bool) -> String {
        let text = escape((storage.string as NSString).substring(with: range))
        let block = storage.markdownBlock(at: range.location)
        let lists = textLists(in: storage, at: range.location)
        var columns = [
            pad("\(range.location)…\(NSMaxRange(range))", 12) + pad(text, 30),
            block.map { describe(block: $0, lists: lists) } ?? "‹no block›",
            describe(lists: lists),
            intentRuns(storage, range),
            literals(storage, range),
            atoms(storage, range),
        ]
        if includesGeometry, let geometry = groupSummary(storage, range) {
            columns.append(geometry)
        }
        return columns.joined(separator: " | ")
    }

    // MARK: - Block descriptions

    /// `<leaf>[ quote:<n>][ list:<bullet|ordered>@<depth>][ task:<state>][ cont]`
    static func describe(block: MarkdownBlock, lists: [NSTextList]) -> String {
        var out = leafName(block)
        let quotes = block.quoteTokens.count
        if quotes > 0 { out += " quote:\(quotes)" }
        if block.listDepth > 0 {
            let kind = lists.last.map { isOrdered($0) ? "ordered" : "bullet" } ?? "?"
            out += " list:\(kind)@\(block.listDepth)"
        }
        if let task = block.task { out += " task:\(task.isChecked ? "checked" : "unchecked")" }
        if block.isContinuation { out += " cont" }
        return out
    }

    private static func leafName(_ block: MarkdownBlock) -> String {
        if let level = block.headingLevel { return "heading(\(level))" }
        if block.isCode {
            guard let language = block.codeLanguage, !language.isEmpty else { return "code" }
            return "code(\(language))"
        }
        if block.isTableRow { return block.isTableHeader ? "tableRow(header)" : "tableRow" }
        switch block.leaf {
        case .thematicBreak: return "thematicBreak"
        case .html: return "html"
        default: return "paragraph"
        }
    }

    /// The marker-bearing lists on a paragraph's style, outermost first.
    static func textLists(in storage: NSAttributedString, at index: Int) -> [NSTextList] {
        guard index >= 0, index < storage.length,
              let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        else { return [] }
        return textLists(of: style)
    }

    static func textLists(of style: NSParagraphStyle?) -> [NSTextList] {
        (style?.textLists ?? []).filter { !$0.markerFormat.rawValue.isEmpty }
    }

    private static let bulletFormats: Set<NSTextList.MarkerFormat> = [
        .disc, .circle, .square, .hyphen, .box, .check, .diamond,
    ]

    static func isOrdered(_ list: NSTextList) -> Bool {
        !bulletFormats.contains(list.markerFormat)
    }

    private static func describe(lists: [NSTextList]) -> String {
        guard !lists.isEmpty else { return "-" }
        return lists.map { list in
            isOrdered(list) ? "ol@\(list.startingItemNumber)" : "ul"
        }.joined(separator: ">")
    }

    // MARK: - Inline runs

    /// The mark names on one character, sorted: `code`, `emphasis`,
    /// `link`, `strikethrough`, `strong`.
    static func markNames(_ storage: NSAttributedString, at index: Int) -> [String] {
        guard index >= 0, index < storage.length else { return [] }
        return markNames(intent: storage.markdownInlineIntent(at: index),
                         link: storage.markdownLink(at: index) != nil)
    }

    static func markNames(intent: MarkdownInlineIntent, link: Bool) -> [String] {
        var names: [String] = []
        if intent.contains(.code) { names.append("code") }
        if intent.contains(.emphasized) { names.append("emphasis") }
        if link { names.append("link") }
        if intent.contains(.strikethrough) { names.append("strikethrough") }
        if intent.contains(.stronglyEmphasized) { names.append("strong") }
        return names
    }

    private static func intentRuns(_ storage: NSAttributedString, _ range: NSRange) -> String {
        var runs: [String] = []
        var index = range.location
        while index < NSMaxRange(range) {
            let names = markNames(storage, at: index)
            var end = index + 1
            while end < NSMaxRange(range), markNames(storage, at: end) == names { end += 1 }
            if !names.isEmpty { runs.append("\(index)…\(end):\(names.joined(separator: "+"))") }
            index = end
        }
        return runs.isEmpty ? "-" : runs.joined(separator: " ")
    }

    private static func literals(_ storage: NSAttributedString, _ range: NSRange) -> String {
        var out: [String] = []
        storage.enumerateAttribute(.markdownLiteral, in: range) { value, run, _ in
            guard let literal = value as? String else { return }
            out.append("\(run.location)=\(escape(literal))")
        }
        return out.isEmpty ? "-" : out.joined(separator: " ")
    }

    private static func atoms(_ storage: NSAttributedString, _ range: NSRange) -> String {
        var out: [String] = []
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            guard value != nil else { return }
            if let atom = storage.proseSourceAttachment(at: run.location) {
                out.append("\(run.location)=\(atom.contentKind):\(escape(atom.markdownSource))")
            } else {
                out.append("\(run.location)=‹foreign attachment›")
            }
        }
        return out.isEmpty ? "-" : out.joined(separator: " ")
    }

    private static func groupSummary(_ storage: NSAttributedString, _ range: NSRange) -> String? {
        guard let block = storage.markdownBlock(at: range.location) else { return nil }
        var parts: [String] = []
        if let group = block.codeGroup { parts.append("code \(group)") }
        if let group = block.tableGroup { parts.append("table \(group)") }
        if !block.quoteTokens.isEmpty { parts.append("quote \(block.quoteTokens.map(\.description).joined(separator: ","))") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Trees

    /// Stable textual form of a writer-side tree.
    static func describeTree(_ document: EditorDocument) -> String {
        var out: [String] = []
        for block in document.blocks { describe(block, depth: 0, into: &out) }
        return out.joined(separator: "\n")
    }

    private static func describe(_ block: EditorDocument.Block, depth: Int, into out: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        switch block {
        case .paragraph(let runs):
            out.append("\(indent)paragraph \(describe(runs))")
        case .heading(let level, let runs):
            out.append("\(indent)heading(\(level)) \(describe(runs))")
        case .code(let code):
            out.append("\(indent)code(\(code.language ?? "")) \(escape(code.lines.joined(separator: "\n")))")
        case .thematicBreak:
            out.append("\(indent)thematicBreak")
        case .atom(let atom):
            out.append("\(indent)atom \(atom.kind) \(escape(atom.source))")
        case .quote(let blocks):
            out.append("\(indent)quote")
            for child in blocks { describe(child, depth: depth + 1, into: &out) }
        case .list(let list):
            out.append("\(indent)list \(list.kind)\(list.separatesFromPrevious ? " separated" : "")")
            for item in list.items {
                out.append("\(indent)  item\(item.task.map { " task:\($0.isChecked ? "checked" : "unchecked")" } ?? "")")
                for child in item.blocks { describe(child, depth: depth + 2, into: &out) }
            }
        case .table(let table):
            out.append("\(indent)table \(table.alignments.map(\.rawValue)) header \(table.header.map(describe))")
            for row in table.body { out.append("\(indent)  row \(row.map(describe))") }
        }
    }

    private static func describe(_ runs: [EditorDocument.InlineRun]) -> String {
        runs.map { run in
            var text = "\(run.content)"
            if !run.marks.isEmpty { text += "{\(run.marks.rawValue)}" }
            if let link = run.link { text += "->\(link)" }
            return text
        }.joined(separator: " ")
    }

    // MARK: - Formatting

    static func escape(_ s: String) -> String {
        let e = s
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\u{2028}", with: "↵")
            .replacingOccurrences(of: "\u{FFFC}", with: "▣")
        return "«\(e)»"
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    /// Unified-ish diff of two multi-line strings, first divergence first.
    static func diff(_ expected: String, _ actual: String, context: Int = 3) -> String {
        let e = expected.components(separatedBy: "\n")
        let a = actual.components(separatedBy: "\n")
        var firstDiff = 0
        while firstDiff < min(e.count, a.count), e[firstDiff] == a[firstDiff] { firstDiff += 1 }
        let from = max(0, firstDiff - context)
        let to = min(max(e.count, a.count), firstDiff + context + 1)
        var out: [String] = ["first difference at line \(firstDiff + 1)"]
        for i in from..<to {
            let le = i < e.count ? e[i] : "‹eof›"
            let la = i < a.count ? a[i] : "‹eof›"
            if le == la {
                out.append("   \(le)")
            } else {
                out.append(" - \(le)")
                out.append(" + \(la)")
            }
        }
        return out.joined(separator: "\n")
    }
}
