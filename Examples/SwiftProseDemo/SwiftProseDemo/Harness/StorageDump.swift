import Foundation
@_spi(Harness) import SwiftProse

/// Attribute-run dump of the text storage: what a failure message needs to
/// explain *why* an oracle tripped, in a form that diffs cleanly.
enum StorageDump {

    /// `range | text | nodePath | marks | blockSpec`, one line per
    /// attribute run of `.proseNodePath`, with unstamped gaps called out.
    static func dump(_ storage: NSAttributedString) -> String {
        var lines: [String] = []
        lines.append("length \(storage.length)")
        lines.append(String(repeating: "-", count: 72))
        var cursor = 0
        storage.enumerateAttribute(
            .proseNodePath,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, _ in
            if range.location > cursor {
                let gap = NSRange(location: cursor, length: range.location - cursor)
                lines.append(row(storage, gap, path: nil))
            }
            lines.append(row(storage, range, path: (value as? NodePathBox)?.path))
            cursor = range.location + range.length
        }
        if cursor < storage.length {
            lines.append(row(storage, NSRange(location: cursor, length: storage.length - cursor), path: nil))
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ storage: NSAttributedString,
                            _ range: NSRange,
                            path: NodePath?) -> String {
        let text = escape((storage.string as NSString).substring(with: range))
        let pathText = path.map { p in
            p.nodes.map { "\($0.type)#\(shortID($0.id))" }.joined(separator: ">")
        } ?? "‹none›"
        let marks = markSummary(storage, range)
        let spec = range.length > 0
            ? storage.blockSpec(at: range.location).map { describe($0) } ?? "‹none›"
            : "‹empty›"
        return "\(pad("\(range.location)…\(range.location + range.length)", 12))"
            + "\(pad(text, 30)) | \(pathText) | \(marks) | \(spec)"
    }

    /// Marks over a run, collapsed when uniform.
    private static func markSummary(_ storage: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "-" }
        var seen: [String] = []
        storage.enumerateAttribute(.proseMarks, in: range, options: []) { value, _, _ in
            let names = (value as? MarkSetBox)?.marks.marks.map(\.type).sorted() ?? []
            let text = names.isEmpty ? "-" : names.joined(separator: "+")
            if seen.last != text { seen.append(text) }
        }
        return seen.isEmpty ? "-" : seen.joined(separator: "/")
    }

    static func describe(_ spec: BlockSpec) -> String {
        var out = "\(spec.kind)"
        if spec.blockquoteDepth > 0 { out += " q\(spec.blockquoteDepth)" }
        if spec.listLevel > 0 { out += " l\(spec.listLevel)" }
        return out
    }

    /// Stable textual form of a projected tree, ids elided. Two trees that
    /// render the same describe the same document.
    static func describeTree(_ document: ProseDocument) -> String {
        var out: [String] = []
        describeNode(document.root, depth: 0, into: &out)
        return out.joined(separator: "\n")
    }

    /// Same, minus the doc root — a full projection mints a fresh root id
    /// while a splice keeps the old one, so root identity is not a
    /// difference worth reporting.
    static func describeChildren(_ document: ProseDocument) -> String {
        var out: [String] = []
        for child in document.root.children {
            describeNode(child, depth: 0, into: &out)
        }
        return out.joined(separator: "\n")
    }

    private static func describeNode(_ node: TreeNode, depth: Int, into out: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        switch node {
        case .inline(let text, let marks):
            let names = marks.marks.map(\.type).sorted()
            out.append("\(indent)text \(escape(text))\(names.isEmpty ? "" : " {\(names.joined(separator: ","))}")")
        case .leaf(let n, let marks):
            let names = marks.marks.map(\.type).sorted()
            out.append("\(indent)\(n.type)\(attrsText(n))\(names.isEmpty ? "" : " {\(names.joined(separator: ","))}")")
        case .structural(let n, let kids):
            out.append("\(indent)\(n.type)\(attrsText(n)) [\(node.contentLength)]")
            for kid in kids { describeNode(kid, depth: depth + 1, into: &out) }
        }
    }

    private static func attrsText(_ node: ProseNode) -> String {
        guard !node.attrs.isEmpty else { return "" }
        let pairs = node.attrs.keys.sorted().map { "\($0)=\(node.attrs[$0]!)" }
        return "(\(pairs.joined(separator: ",")))"
    }

    static func escape(_ s: String) -> String {
        let e = s
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\u{FFFC}", with: "▣")
        return "«\(e)»"
    }

    private static func shortID(_ id: NodeID) -> String {
        String(String(describing: id).suffix(4))
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
