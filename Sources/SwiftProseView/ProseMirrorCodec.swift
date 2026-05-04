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
            decodeTable(node, into: result, context: &context)
        default:
            if node.content != nil {
                let spec = context.makeBlockSpec(kind: .paragraph)
                appendTextblock(node, spec: spec, into: result)
            }
        }
    }

    /// Decode a `table` PM node into one `.pipeTable` paragraph per source
    /// line. We synthesize the GFM source from the model and run it through
    /// the same emit machinery the markdown compiler uses (per-line spec +
    /// header/alignment-row attribute flags) so storage looks identical to
    /// a freshly parsed table.
    private func decodeTable(_ node: PMNode, into result: NSMutableAttributedString, context: inout BlockContext) {
        let rows = node.content ?? []
        guard !rows.isEmpty else { return }
        // Pull header text + alignments from the first row.
        let headerCells: [String] = (rows.first?.content ?? []).map { cellText(in: $0) }
        let alignments: [PipeTableAlignment] = (rows.first?.content ?? []).map { cellAlignment(in: $0) }
        let bodyRows: [[String]] = rows.dropFirst().map { row in
            (row.content ?? []).map { cellText(in: $0) }
        }
        let columnCount = max(
            headerCells.count,
            alignments.count,
            bodyRows.map(\.count).max() ?? 0
        )
        let model = PipeTableModel(
            sourceRange: NSRange(location: 0, length: 0),
            lineRanges: [],
            lineKinds: [],
            headerCells: headerCells,
            alignments: alignments,
            bodyRows: bodyRows,
            columnCount: columnCount
        )
        let source = model.renderSource()
        // Lay out one paragraph per source line, all spec'd as .pipeTable.
        let blockquoteDepth = context.blockquoteDepth
        let spec = BlockSpec(kind: .pipeTable, blockquoteDepth: blockquoteDepth)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, line) in lines.enumerated() {
            guard !line.isEmpty || lineIndex < lines.count - 1 else { continue }
            var attrs = schemaMap.baseAttributes(for: spec, theme: theme)
            attrs[.proseBlockSpec] = BlockSpecBox(spec)
            // Identify header (line 0) vs alignment (line 1) for chrome.
            if lineIndex == 0 {
                attrs[.proseTableHeader] = true
            } else if lineIndex == 1 {
                attrs[.proseTableAlignmentRow] = true
            }
            result.append(NSAttributedString(string: String(line) + "\n", attributes: attrs))
        }
    }

    private func cellText(in cell: PMNode) -> String {
        // table_cell / table_header → paragraph → text nodes
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

    private func cellAlignment(in cell: PMNode) -> PipeTableAlignment {
        guard let attr = cell.attrs?["align"]?.stringValue else { return .none }
        switch attr {
        case "left": return .left
        case "right": return .right
        case "center": return .center
        default: return .none
        }
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
        for child in node.content ?? [] {
            switch child.type {
            case "text":
                guard let text = child.text else { continue }
                var attrs = schemaMap.baseAttributes(for: spec, theme: theme)
                for mark in child.marks ?? [] {
                    schemaMap.applyMark(mark, to: &attrs, theme: theme)
                }
                attrs[.proseBlockSpec] = BlockSpecBox(spec)
                line.append(NSAttributedString(string: text, attributes: attrs))
            case "hard_break":
                var attrs = schemaMap.baseAttributes(for: spec, theme: theme)
                attrs[.proseBlockSpec] = BlockSpecBox(spec)
                line.append(NSAttributedString(string: "\n", attributes: attrs))
            case "image":
                let src = child.attrs?["src"]?.stringValue ?? ""
                let alt = child.attrs?["alt"]?.stringValue ?? ""
                let title = child.attrs?["title"]?.stringValue
                var attrs = schemaMap.baseAttributes(for: spec, theme: theme)
                attrs[.proseBlockSpec] = BlockSpecBox(spec)
                let label = alt.isEmpty ? src : alt
                let titleSuffix = title.map { " \"\($0)\"" } ?? ""
                line.append(NSAttributedString(string: "![\(label)](\(src)\(titleSuffix))", attributes: attrs))
            default:
                continue
            }
        }
        if line.length == 0 {
            var attrs = schemaMap.baseAttributes(for: spec, theme: theme)
            attrs[.proseBlockSpec] = BlockSpecBox(spec)
            line.append(NSAttributedString(string: "", attributes: attrs))
        }
        if !line.string.hasSuffix("\n") {
            var nlAttrs = schemaMap.baseAttributes(for: spec, theme: theme)
            nlAttrs[.proseBlockSpec] = BlockSpecBox(spec)
            line.append(NSAttributedString(string: "\n", attributes: nlAttrs))
        }
        result.append(line)
    }

    private func appendLeafBlock(spec: BlockSpec, into result: NSMutableAttributedString) {
        var attrs = schemaMap.baseAttributes(for: spec, theme: theme)
        attrs[.proseBlockSpec] = BlockSpecBox(spec)
        result.append(NSAttributedString(string: "\n", attributes: attrs))
    }

    // MARK: encode

    public func encode(_ storage: NSAttributedString) -> PMNode {
        let blocks = extractFlatBlocks(from: storage)
        let children = buildPMTree(from: blocks)
        return PMNode(type: "doc", content: children)
    }

    public func encodeToJSON(_ storage: NSAttributedString) throws -> Data {
        try JSONEncoder().encode(encode(storage))
    }

    /// Tree-direct encode: walk a `ProseDocument` and emit a PM tree.
    /// Marks come from inline runs' `MarkSet` directly rather than being
    /// re-extracted from rendering attributes, which keeps mark fidelity
    /// in nested contexts (table cells will benefit once Phase 6 reshapes
    /// table storage). Tables today still rely on the flat-block path
    /// because the storage tree only carries a `table` envelope.
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
                let inner = kids.compactMap { encodeBlock($0) }
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
                return encodeTableFromTree(kids)
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

    /// Walk a table envelope's flat paragraph children, parse pipe content
    /// while tracking inline marks per character, and emit a PM table with
    /// row/cell structure. Marks survive into cell text — the output of
    /// `**bold**` inside a cell becomes a `text` node carrying a `strong`
    /// mark, which the existing storage-path encoder loses by joining
    /// inline runs to a flat string before parsing.
    private func encodeTableFromTree(_ kids: [TreeNode]) -> PMNode? {
        let lineRuns: [[(text: String, marks: MarkSet)]] = kids.compactMap { kid in
            guard case .structural(let pn, let inlines) = kid, pn.type == "paragraph" else { return nil }
            return inlines.compactMap { node -> (String, MarkSet)? in
                if case .inline(let text, let marks) = node { return (text, marks) }
                return nil
            }
        }
        guard lineRuns.count >= 2 else { return nil }
        // Identify alignment row by scanning line cells for `:?-+:?`.
        var alignmentLineIdx: Int? = nil
        for (idx, runs) in lineRuns.enumerated() {
            let cellTexts = splitLineByPipes(runs).map { runsToText($0) }
            if !cellTexts.isEmpty,
               cellTexts.allSatisfy({ PipeTableAlignment(alignmentRowCell: $0.trimmingCharacters(in: .whitespaces)) != nil }) {
                alignmentLineIdx = idx
                break
            }
        }
        guard let alignIdx = alignmentLineIdx, alignIdx > 0 else { return nil }
        let alignmentTexts = splitLineByPipes(lineRuns[alignIdx]).map { runsToText($0) }
        let alignments: [PipeTableAlignment] = alignmentTexts.map {
            PipeTableAlignment(alignmentRowCell: $0.trimmingCharacters(in: .whitespaces)) ?? .none
        }
        // Header row — line before alignment.
        let headerCells = splitLineByPipes(lineRuns[alignIdx - 1])
        // Body rows — lines after alignment.
        let bodyCellsByRow: [[[(text: String, marks: MarkSet)]]] = lineRuns
            .dropFirst(alignIdx + 1)
            .map { splitLineByPipes($0) }
        let columnCount = max(
            headerCells.count,
            alignments.count,
            bodyCellsByRow.map(\.count).max() ?? 0
        )
        var rows: [PMNode] = []
        rows.append(makeTableRowFromTreeRuns(
            cells: headerCells,
            alignments: alignments,
            columnCount: columnCount,
            isHeader: true
        ))
        for body in bodyCellsByRow {
            rows.append(makeTableRowFromTreeRuns(
                cells: body,
                alignments: alignments,
                columnCount: columnCount,
                isHeader: false
            ))
        }
        return PMNode(type: "table", content: rows)
    }

    private func makeTableRowFromTreeRuns(
        cells: [[(text: String, marks: MarkSet)]],
        alignments: [PipeTableAlignment],
        columnCount: Int,
        isHeader: Bool
    ) -> PMNode {
        var cellNodes: [PMNode] = []
        for col in 0..<columnCount {
            let runs = (col < cells.count) ? cells[col] : []
            let alignment = (col < alignments.count) ? alignments[col] : .none
            var attrs: [String: PMValue] = [
                "colspan": .int(1),
                "rowspan": .int(1)
            ]
            if let alignString = pmAlignString(for: alignment) {
                attrs["align"] = .string(alignString)
            }
            let textNodes = runs.compactMap { run -> PMNode? in
                guard !run.text.isEmpty else { return nil }
                var pm = PMNode(type: "text", text: run.text)
                if !run.marks.isEmpty {
                    pm.marks = run.marks.marks.map { PMMark(type: $0.type, attrs: nil) }
                }
                return pm
            }
            let paragraph = PMNode(type: "paragraph", content: textNodes.isEmpty ? nil : textNodes)
            cellNodes.append(PMNode(
                type: isHeader ? "table_header" : "table_cell",
                attrs: attrs,
                content: [paragraph]
            ))
        }
        return PMNode(type: "table_row", content: cellNodes)
    }

    /// Split a line's inline runs into cells by walking unescaped `|`. Each
    /// cell preserves the (text, marks) shape of the runs that fall within
    /// it, with leading/trailing whitespace trimmed and empty leading/
    /// trailing cells (from outer pipes) dropped.
    private func splitLineByPipes(
        _ runs: [(text: String, marks: MarkSet)]
    ) -> [[(text: String, marks: MarkSet)]] {
        // Char-stream representation: each character with its source marks.
        var stream: [(Character, MarkSet)] = []
        for run in runs {
            for ch in run.text {
                stream.append((ch, run.marks))
            }
        }
        var cells: [[(Character, MarkSet)]] = []
        var current: [(Character, MarkSet)] = []
        var prevEscape = false
        for (ch, marks) in stream {
            if ch == "|", !prevEscape {
                cells.append(current)
                current = []
            } else {
                current.append((ch, marks))
            }
            prevEscape = (ch == "\\" && !prevEscape)
        }
        cells.append(current)
        // Drop optional empty leading/trailing cells from outer pipes.
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        // Trim each cell's leading/trailing whitespace.
        let trimmed: [[(Character, MarkSet)]] = cells.map { cell in
            var c = cell
            while let first = c.first, first.0.isWhitespace { c.removeFirst() }
            while let last = c.last, last.0.isWhitespace { c.removeLast() }
            return c
        }
        // Group consecutive same-mark characters into runs.
        return trimmed.map { cell in
            var out: [(text: String, marks: MarkSet)] = []
            var i = 0
            while i < cell.count {
                let marks = cell[i].1
                var text = ""
                while i < cell.count, cell[i].1 == marks {
                    text.append(cell[i].0)
                    i += 1
                }
                out.append((text, marks))
            }
            return out
        }
    }

    private func runsToText(_ runs: [(text: String, marks: MarkSet)]) -> String {
        runs.map(\.text).joined()
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
            case .leaf, .structural:
                continue
            }
        }
        return out
    }

    private func extractFlatBlocks(from storage: NSAttributedString) -> [FlatBlock] {
        var blocks: [FlatBlock] = []
        let ns = storage.string as NSString
        var cursor = 0
        while cursor < ns.length {
            let lineRange = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            let spec = storage.blockSpec(at: lineRange.location) ?? .paragraph
            let inlineNodes = extractInlineNodes(from: storage, range: lineRange)
            blocks.append(FlatBlock(spec: spec, range: lineRange, inlineNodes: inlineNodes))
            cursor = lineRange.location + lineRange.length
        }
        return blocks
    }

    private func extractInlineNodes(from storage: NSAttributedString, range: NSRange) -> [PMNode] {
        var nodes: [PMNode] = []
        storage.enumerateAttributes(in: range) { attrs, subRange, _ in
            let text = (storage.string as NSString).substring(with: subRange)
            let cleaned = text.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !cleaned.isEmpty else { return }
            if (attrs[.proseListMarker] as? Bool) == true { return }
            let marks = schemaMap.extractMarks(from: attrs)
            var node = PMNode(type: "text", text: cleaned)
            if !marks.isEmpty { node.marks = marks }
            nodes.append(node)
        }
        return nodes
    }

    private func buildPMTree(from blocks: [FlatBlock]) -> [PMNode] {
        var result: [PMNode] = []
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            if block.spec.blockquoteDepth > 0 {
                let (node, consumed) = wrapBlockquote(blocks, from: i, atDepth: 1)
                result.append(node)
                i += consumed
            } else if block.spec.isListItem {
                let (node, consumed) = wrapList(blocks, from: i)
                result.append(node)
                i += consumed
            } else if case .pipeTable = block.spec.kind {
                let (node, consumed) = wrapPipeTable(blocks, from: i)
                result.append(node)
                i += consumed
            } else {
                result.append(blockToPMNode(block))
                i += 1
            }
        }
        return result
    }

    /// Merge consecutive `.pipeTable` blocks into a single `table` PM node.
    /// Each block here is one source line (the segmenter emits per-line);
    /// joining them and re-parsing with `PipeTableModel` is cheaper than
    /// reaching back into storage for the original source.
    private func wrapPipeTable(_ blocks: [FlatBlock], from start: Int) -> (PMNode, Int) {
        var i = start
        var lineTexts: [String] = []
        while i < blocks.count, case .pipeTable = blocks[i].spec.kind {
            // inlineNodes is text-only post-stripping; rebuild the line.
            let line = blocks[i].inlineNodes.compactMap(\.text).joined()
            lineTexts.append(line)
            i += 1
        }
        let consumed = i - start
        let source = lineTexts.joined(separator: "\n") + "\n"
        guard let model = PipeTableModel.parse(source: source) else {
            // Couldn't parse — fall back to one paragraph per line so the
            // round-trip preserves text even if structure is lost.
            let paragraphs = lineTexts.map { line in
                PMNode(type: "paragraph", content: [PMNode(type: "text", text: line)])
            }
            return (PMNode(type: "doc", content: paragraphs), consumed)
        }
        var rows: [PMNode] = []
        rows.append(makeTableRow(cells: model.headerCells, alignments: model.alignments, columnCount: model.columnCount, isHeader: true))
        for body in model.bodyRows {
            rows.append(makeTableRow(cells: body, alignments: model.alignments, columnCount: model.columnCount, isHeader: false))
        }
        return (PMNode(type: "table", content: rows), consumed)
    }

    private func makeTableRow(
        cells: [String],
        alignments: [PipeTableAlignment],
        columnCount: Int,
        isHeader: Bool
    ) -> PMNode {
        var cellNodes: [PMNode] = []
        for col in 0..<columnCount {
            let text = (col < cells.count) ? cells[col] : ""
            let alignment = (col < alignments.count) ? alignments[col] : .none
            var attrs: [String: PMValue] = [
                "colspan": .int(1),
                "rowspan": .int(1)
            ]
            if let alignString = pmAlignString(for: alignment) {
                attrs["align"] = .string(alignString)
            }
            let inner: [PMNode] = text.isEmpty
                ? []
                : [PMNode(type: "text", text: text)]
            let paragraph = PMNode(type: "paragraph", content: inner.isEmpty ? nil : inner)
            cellNodes.append(PMNode(
                type: isHeader ? "table_header" : "table_cell",
                attrs: attrs,
                content: [paragraph]
            ))
        }
        return PMNode(type: "table_row", content: cellNodes)
    }

    private func pmAlignString(for alignment: PipeTableAlignment) -> String? {
        switch alignment {
        case .none: return nil
        case .left: return "left"
        case .right: return "right"
        case .center: return "center"
        }
    }

    private func wrapBlockquote(_ blocks: [FlatBlock], from start: Int, atDepth: Int) -> (PMNode, Int) {
        var consumed = 0
        var children: [FlatBlock] = []
        while start + consumed < blocks.count, blocks[start + consumed].spec.blockquoteDepth >= atDepth {
            let original = blocks[start + consumed]
            children.append(FlatBlock(
                spec: BlockSpec(kind: original.spec.kind, blockquoteDepth: original.spec.blockquoteDepth - 1, listLevel: original.spec.listLevel),
                range: original.range,
                inlineNodes: original.inlineNodes
            ))
            consumed += 1
        }
        let inner = buildPMTree(from: children)
        return (PMNode(type: "blockquote", content: inner), consumed)
    }

    private func wrapList(_ blocks: [FlatBlock], from start: Int) -> (PMNode, Int) {
        let firstKind = blocks[start].spec.kind
        let listType: String
        switch firstKind {
        case .orderedListItem: listType = "ordered_list"
        default: listType = "bullet_list"
        }
        var items: [PMNode] = []
        var i = start
        while i < blocks.count, blocks[i].spec.isListItem {
            let block = blocks[i]
            var inlineNodes = block.inlineNodes
            if case .taskListItem(let checked) = block.spec.kind {
                let prefix = checked ? "[x] " : "[ ] "
                inlineNodes.insert(PMNode(type: "text", text: prefix), at: 0)
            }
            let inner = PMNode(
                type: "paragraph",
                content: inlineNodes.isEmpty ? nil : inlineNodes
            )
            items.append(PMNode(type: "list_item", content: [inner]))
            i += 1
        }
        var attrs: [String: PMValue]? = nil
        if listType == "ordered_list" {
            if case .orderedListItem(let idx) = firstKind, idx != 1 {
                attrs = ["order": .int(idx)]
            }
        }
        return (PMNode(type: listType, attrs: attrs, content: items), i - start)
    }

    private func blockToPMNode(_ block: FlatBlock) -> PMNode {
        switch block.spec.kind {
        case .paragraph:
            return PMNode(type: "paragraph", content: block.inlineNodes.isEmpty ? nil : block.inlineNodes)
        case .heading(let level):
            return PMNode(
                type: "heading",
                attrs: ["level": .int(level)],
                content: block.inlineNodes.isEmpty ? nil : block.inlineNodes
            )
        case .fencedCode(let lang):
            return PMNode(
                type: "code_block",
                attrs: ["params": .string(lang ?? "")],
                content: block.inlineNodes.isEmpty ? nil : block.inlineNodes
            )
        case .indentedCode:
            return PMNode(
                type: "code_block",
                attrs: ["params": .string("")],
                content: block.inlineNodes.isEmpty ? nil : block.inlineNodes
            )
        case .horizontalRule:
            return PMNode(type: "horizontal_rule")
        default:
            return PMNode(type: "paragraph", content: block.inlineNodes.isEmpty ? nil : block.inlineNodes)
        }
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

struct FlatBlock {
    let spec: BlockSpec
    let range: NSRange
    let inlineNodes: [PMNode]
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
