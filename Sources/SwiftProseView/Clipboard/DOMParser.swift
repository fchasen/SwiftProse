import Foundation
import SwiftProseSyntax

/// Parses an HTML string into a `Slice`. Pragmatic tokenizer — handles
/// the tags emitted by `DOMSerializer` and the common subset external
/// apps (Notes, browsers, Word) emit. Anything unknown becomes
/// transparent (the children are still walked).
///
/// PM-wrapped HTML (`data-pm-slice` attribute on the outer element) is
/// detected and used to recover the slice's open depths. External HTML
/// without the marker is parsed and exposed as a closed slice.
public struct DOMParser {

    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    public func parse(_ html: String) -> Slice? {
        var input = html
        // Strip surrounding whitespace; many sources include leading
        // newlines and indentation that throws off block detection.
        input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        // Detect a PM-wrapped slice. Match `<div data-pm-slice="<openStart> <openEnd> JSON">…</div>`.
        if let pmSlice = parsePMSlice(input) {
            return pmSlice
        }

        let tokens = tokenize(input)
        var builder = Builder(schema: schema)
        for token in tokens {
            builder.feed(token)
        }
        let children = builder.finish()
        if children.isEmpty { return nil }
        if children.allSatisfy({ isInlineLike($0) }) {
            return Slice(content: Fragment(children), openStart: 1, openEnd: 1)
        }
        return Slice(content: Fragment(children), openStart: 0, openEnd: 0)
    }

    private func parsePMSlice(_ html: String) -> Slice? {
        // Look for the data-pm-slice attribute on the first opening tag.
        let prefix = "<div data-pm-slice=\""
        guard let attrStart = html.range(of: prefix, options: .caseInsensitive),
              let attrEnd = html[attrStart.upperBound...].firstIndex(of: "\""),
              let bodyStart = html[attrEnd...].firstIndex(of: ">") else {
            return nil
        }
        let marker = String(html[attrStart.upperBound..<attrEnd])
        let bodyOpen = html.index(after: bodyStart)
        // Find matching `</div>`. PM wraps the slice in exactly one div.
        guard let bodyClose = html.range(of: "</div>", options: .backwards) else {
            return nil
        }
        let body = String(html[bodyOpen..<bodyClose.lowerBound])
        let parts = marker.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let openStart = Int(parts.first ?? "") ?? 0
        let openEnd = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let tokens = tokenize(body)
        var builder = Builder(schema: schema)
        for token in tokens { builder.feed(token) }
        let children = builder.finish()
        return Slice(content: Fragment(children), openStart: openStart, openEnd: openEnd)
    }

    private func isInlineLike(_ node: TreeNode) -> Bool {
        switch node {
        case .inline: return true
        case .leaf(let pn, _): return pn.type == "hard_break" || pn.type == "image"
        case .structural: return false
        }
    }

    // MARK: - tokenizer

    enum Token {
        case open(tag: String, attrs: [String: String])
        case close(tag: String)
        case text(String)
    }

    /// Tokenize HTML into a flat stream. Self-closing tags emit a single
    /// `.open`; the tokenizer doesn't track void elements specially —
    /// the builder ignores their close if it never sees one.
    private func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        let scalars = Array(html.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "<" {
                // Skip comments and CDATA.
                if i + 3 < scalars.count, scalars[i + 1] == "!" {
                    if let endRange = findIndex(of: ">", in: scalars, from: i) {
                        i = endRange + 1
                        continue
                    }
                    i += 1
                    continue
                }
                guard let tagEnd = findIndex(of: ">", in: scalars, from: i) else {
                    // Malformed — bail.
                    break
                }
                let tagBody = scalars[(i + 1)..<tagEnd]
                let rendered = String(String.UnicodeScalarView(tagBody))
                let isClose = rendered.hasPrefix("/")
                let trimmed = isClose ? String(rendered.dropFirst()) : rendered
                let parsed = parseTag(trimmed)
                if isClose {
                    tokens.append(.close(tag: parsed.name))
                } else {
                    tokens.append(.open(tag: parsed.name, attrs: parsed.attrs))
                }
                i = tagEnd + 1
                continue
            }
            // Accumulate text until the next '<'.
            var j = i
            while j < scalars.count, scalars[j] != "<" { j += 1 }
            let text = String(String.UnicodeScalarView(scalars[i..<j]))
            let decoded = decodeEntities(text)
            tokens.append(.text(decoded))
            i = j
        }
        return tokens
    }

    private func findIndex(of needle: Unicode.Scalar, in scalars: [Unicode.Scalar], from: Int) -> Int? {
        var i = from
        while i < scalars.count {
            if scalars[i] == needle { return i }
            i += 1
        }
        return nil
    }

    private func parseTag(_ body: String) -> (name: String, attrs: [String: String]) {
        var rest = body
        // Drop trailing `/` for self-closing tags.
        if rest.hasSuffix("/") { rest = String(rest.dropLast()) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        guard let nameEnd = rest.firstIndex(where: { $0.isWhitespace }) else {
            return (name: rest.lowercased(), attrs: [:])
        }
        let name = String(rest[rest.startIndex..<nameEnd]).lowercased()
        let attrPart = rest[nameEnd...].trimmingCharacters(in: .whitespaces)
        let attrs = parseAttrs(attrPart)
        return (name: name, attrs: attrs)
    }

    private func parseAttrs(_ s: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            // skip whitespace
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            if i >= s.endIndex { break }
            let keyStart = i
            while i < s.endIndex, s[i] != "=", !s[i].isWhitespace { i = s.index(after: i) }
            let key = String(s[keyStart..<i]).lowercased()
            // optional value
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            if i < s.endIndex, s[i] == "=" {
                i = s.index(after: i)
                while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
                if i < s.endIndex, s[i] == "\"" || s[i] == "'" {
                    let quote = s[i]
                    i = s.index(after: i)
                    let valStart = i
                    while i < s.endIndex, s[i] != quote { i = s.index(after: i) }
                    attrs[key] = decodeEntities(String(s[valStart..<i]))
                    if i < s.endIndex { i = s.index(after: i) }
                } else {
                    let valStart = i
                    while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
                    attrs[key] = decodeEntities(String(s[valStart..<i]))
                }
            } else {
                attrs[key] = ""
            }
        }
        return attrs
    }

    private func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&" {
                if let semi = s[i...].firstIndex(of: ";") {
                    let entity = String(s[s.index(after: i)..<semi])
                    if let replacement = entityValue(entity) {
                        out.append(replacement)
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private func entityValue(_ entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp", "#160": return "\u{00A0}"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                if let code = UInt32(entity.dropFirst(2), radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    return String(scalar)
                }
            }
            if entity.hasPrefix("#") {
                if let code = UInt32(entity.dropFirst()),
                   let scalar = Unicode.Scalar(code) {
                    return String(scalar)
                }
            }
            return nil
        }
    }

    // MARK: - builder

    /// Stack-driven tree builder. The block stack starts with a synthetic
    /// root; opening a block tag pushes onto it, closing pops. Inline
    /// tags push a `ProseMark` onto the active mark set; inline runs and
    /// leaves go into the current block.
    fileprivate struct Builder {
        let schema: Schema
        var blockStack: [BlockFrame] = [BlockFrame(node: nil, kind: nil, kids: [])]
        var markStack: [ProseMark] = []
        var pendingInline: [TreeNode] = []
        /// When inside `<pre><code>`, accumulate raw text without merging
        /// or splitting; close emits a single inline run carrying the
        /// raw text.
        var inCodeBlock: Bool = false
        var codeBlockLang: String = ""
        var codeBlockText: String = ""
        /// Whitespace handling: collapse runs of inter-tag whitespace
        /// (newlines, repeated spaces) per HTML's text model.
        var lastEmittedWasWhitespace: Bool = true

        struct BlockFrame {
            let node: ProseNode?
            let kind: Kind?
            var kids: [TreeNode]
        }

        enum Kind {
            case paragraph
            case heading(level: Int)
            case blockquote
            case bulletList
            case orderedList(start: Int)
            case taskList
            case listItem
            case codeBlock(lang: String)
            case table
            case tableRow
            case tableCell(align: String, header: Bool)
        }

        mutating func feed(_ token: Token) {
            switch token {
            case .open(let tag, let attrs):
                handleOpen(tag: tag, attrs: attrs)
            case .close(let tag):
                handleClose(tag: tag)
            case .text(let text):
                handleText(text)
            }
        }

        private mutating func handleOpen(tag: String, attrs: [String: String]) {
            switch tag {
            case "p":
                pushBlock(kind: .paragraph, node: ProseNode(type: "paragraph"))
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(tag.dropFirst()) ?? 1
                pushBlock(kind: .heading(level: level), node: ProseNode(type: "heading", attrs: ["level": .int(level)]))
            case "blockquote":
                pushBlock(kind: .blockquote, node: ProseNode(type: "blockquote"))
            case "ul":
                if attrs["data-task-list"] == "true" {
                    pushBlock(kind: .taskList, node: ProseNode(type: "task_list"))
                } else {
                    pushBlock(kind: .bulletList, node: ProseNode(type: "bullet_list"))
                }
            case "ol":
                let start = Int(attrs["start"] ?? "1") ?? 1
                pushBlock(kind: .orderedList(start: start), node: ProseNode(type: "ordered_list", attrs: ["order": .int(start)]))
            case "li":
                pushBlock(kind: .listItem, node: ProseNode(type: "list_item"))
            case "pre":
                // <pre> alone — wait for inner <code> to set the language.
                pushBlock(kind: .codeBlock(lang: ""), node: ProseNode(type: "code_block"))
                inCodeBlock = true
                codeBlockText = ""
            case "code" where inCodeBlock:
                // language class on the inner <code> overrides empty.
                if let cls = attrs["class"], cls.hasPrefix("language-") {
                    codeBlockLang = String(cls.dropFirst("language-".count))
                }
            case "code":
                markStack.append(ProseMark(type: "code"))
            case "strong", "b":
                markStack.append(ProseMark(type: "strong"))
            case "em", "i":
                markStack.append(ProseMark(type: "em"))
            case "s", "strike", "del":
                markStack.append(ProseMark(type: "strike"))
            case "a":
                var markAttrs: [String: ProseAttrValue] = [:]
                if let href = attrs["href"] { markAttrs["href"] = .string(href) }
                if let title = attrs["title"], !title.isEmpty { markAttrs["title"] = .string(title) }
                markStack.append(ProseMark(type: "link", attrs: markAttrs))
            case "br":
                appendInline(.leaf(ProseNode(type: "hard_break"), MarkSet()))
            case "hr":
                emitLeafBlock(.leaf(ProseNode(type: "horizontal_rule"), MarkSet()))
            case "img":
                let src = attrs["src"] ?? ""
                let alt = attrs["alt"] ?? ""
                let title = attrs["title"] ?? ""
                let node = ProseNode(type: "image", attrs: [
                    "src": .string(src),
                    "alt": .string(alt),
                    "title": .string(title)
                ])
                appendInline(.leaf(node, MarkSet(markStack)))
            case "table":
                pushBlock(kind: .table, node: ProseNode(type: "table"))
            case "tr":
                pushBlock(kind: .tableRow, node: ProseNode(type: "table_row"))
            case "td":
                let align = parseAlign(attrs["style"])
                pushBlock(kind: .tableCell(align: align, header: false), node: ProseNode(type: "table_cell", attrs: ["align": .string(align)]))
            case "th":
                let align = parseAlign(attrs["style"])
                pushBlock(kind: .tableCell(align: align, header: true), node: ProseNode(type: "table_header", attrs: ["align": .string(align)]))
            case "div", "span", "section", "article", "main", "body", "html", "head", "tbody", "thead", "tfoot":
                // Transparent — children flow into the current block.
                break
            default:
                // Unknown — treat as transparent.
                break
            }
        }

        private mutating func handleClose(tag: String) {
            switch tag {
            case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
                 "ul", "ol", "li", "table", "tr", "td", "th":
                popBlock()
            case "pre":
                // Emit accumulated code-block text as one inline child of the
                // current code_block frame, then close.
                if inCodeBlock, var frame = blockStack.last {
                    if !codeBlockText.isEmpty {
                        let text = trimTrailingNewline(codeBlockText)
                        frame.kids = [.inline(text: text, marks: MarkSet())]
                    }
                    // Replace stored frame so attrs reflect the captured lang.
                    let node: ProseNode = {
                        if codeBlockLang.isEmpty { return ProseNode(type: "code_block") }
                        return ProseNode(type: "code_block", attrs: ["params": .string(codeBlockLang)])
                    }()
                    blockStack[blockStack.count - 1] = BlockFrame(node: node, kind: frame.kind, kids: frame.kids)
                    inCodeBlock = false
                    codeBlockLang = ""
                    codeBlockText = ""
                    popBlock()
                }
            case "code":
                if !inCodeBlock {
                    popMark(type: "code")
                }
            case "strong", "b": popMark(type: "strong")
            case "em", "i": popMark(type: "em")
            case "s", "strike", "del": popMark(type: "strike")
            case "a": popMark(type: "link")
            default:
                break
            }
        }

        private mutating func handleText(_ text: String) {
            if inCodeBlock {
                codeBlockText.append(text)
                return
            }
            // Collapse runs of whitespace into single spaces, per HTML's
            // default text-node behavior.
            var collapsed = ""
            collapsed.reserveCapacity(text.count)
            var prevWasSpace = lastEmittedWasWhitespace
            for ch in text {
                if ch.isWhitespace {
                    if !prevWasSpace {
                        collapsed.append(" ")
                        prevWasSpace = true
                    }
                } else {
                    collapsed.append(ch)
                    prevWasSpace = false
                }
            }
            if collapsed.isEmpty { return }
            // Drop the leading space when the previous emission already
            // ended with whitespace (or the run is at the start).
            var out = collapsed
            if lastEmittedWasWhitespace, out.hasPrefix(" ") {
                out.removeFirst()
            }
            if out.isEmpty {
                lastEmittedWasWhitespace = true
                return
            }
            lastEmittedWasWhitespace = out.hasSuffix(" ")
            appendInline(.inline(text: out, marks: MarkSet(markStack)))
        }

        private mutating func pushBlock(kind: Kind, node: ProseNode) {
            // Block-opening flushes pending inline content into the current
            // parent block as an implicit paragraph if needed. With our
            // schema, paragraphs/headings hold inline content directly,
            // and `body > inline` shouldn't happen — but be lenient.
            flushPendingInlineToParent()
            blockStack.append(BlockFrame(node: node, kind: kind, kids: []))
            lastEmittedWasWhitespace = true
        }

        private mutating func popBlock() {
            guard blockStack.count > 1 else { return }
            flushPendingInlineToCurrent()
            let frame = blockStack.removeLast()
            if let node = frame.node {
                blockStack[blockStack.count - 1].kids.append(.structural(node, frame.kids))
            } else {
                blockStack[blockStack.count - 1].kids.append(contentsOf: frame.kids)
            }
            lastEmittedWasWhitespace = true
        }

        private mutating func emitLeafBlock(_ node: TreeNode) {
            flushPendingInlineToCurrent()
            blockStack[blockStack.count - 1].kids.append(node)
        }

        /// Flush any pending inline tokens into the current open block.
        private mutating func flushPendingInlineToCurrent() {
            guard !pendingInline.isEmpty else { return }
            blockStack[blockStack.count - 1].kids.append(contentsOf: pendingInline)
            pendingInline.removeAll(keepingCapacity: true)
        }

        /// Flush pending inline tokens to the current block — used before
        /// a structural change (block open) to avoid losing in-between
        /// content.
        private mutating func flushPendingInlineToParent() {
            flushPendingInlineToCurrent()
        }

        private mutating func appendInline(_ node: TreeNode) {
            // If the current block is the synthetic root with no open
            // structural parent, accumulate inline tokens directly. They
            // become an inline-only slice.
            blockStack[blockStack.count - 1].kids.append(node)
        }

        private mutating func popMark(type: String) {
            // Remove last matching mark of this type.
            if let idx = markStack.lastIndex(where: { $0.type == type }) {
                markStack.remove(at: idx)
            }
        }

        private func parseAlign(_ style: String?) -> String {
            guard let style else { return "" }
            // crude `text-align:left` parser
            let lower = style.lowercased()
            if lower.contains("text-align:left") || lower.contains("text-align: left") { return "left" }
            if lower.contains("text-align:right") || lower.contains("text-align: right") { return "right" }
            if lower.contains("text-align:center") || lower.contains("text-align: center") { return "center" }
            return ""
        }

        private func trimTrailingNewline(_ s: String) -> String {
            if s.hasSuffix("\n") { return String(s.dropLast()) }
            return s
        }

        mutating func finish() -> [TreeNode] {
            while blockStack.count > 1 {
                popBlock()
            }
            return blockStack[0].kids
        }
    }
}

