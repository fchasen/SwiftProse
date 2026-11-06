import Foundation
import Synchronization
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct StorageReader {
    public init() {}

    public func document(from storage: NSAttributedString) -> EditorDocument {
        EditorDocument(blocks: units(in: storage, from: 0, previous: nil).units.map(\.block))
    }

    public func document(from storage: NSAttributedString, range: NSRange) -> EditorDocument {
        let text = Self.backing(storage)
        var builder = TreeBuilder(storage: storage)
        let paragraphs = scanParagraphs(storage, text: text, range: range)
        let last = paragraphs.lastIndex { !$0.isBlank } ?? -1
        for paragraph in paragraphs.prefix(last + 1) {
            builder.add(paragraph)
        }
        return builder.finish()
    }

    package func units(
        in storage: NSAttributedString,
        from location: Int,
        previous: TopLevelList?,
        stoppingAt shouldStop: ((Int) -> Bool)? = nil
    ) -> TopLevelScan {
        let text = Self.backing(storage)
        let total = text.length
        let start = max(0, min(location, total))
        let shared = shouldStop == nil ? UTF16Text(text, range: NSRange(location: start, length: total - start)) : nil
        var builder = TreeBuilder(storage: storage)
        var heads: [Int] = []
        var pending: [ScannedParagraph] = []
        var stop: Int?
        var cursor = start
        func feed(_ candidate: ScannedParagraph) -> Bool {
            let count = builder.rootCount
            builder.add(candidate)
            guard builder.rootCount > count else { return true }
            if let shouldStop, shouldStop(candidate.range.location) {
                builder.dropLastRoot()
                stop = candidate.range.location
                return false
            }
            heads.append(candidate.range.location)
            return true
        }
        reading: while true {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            let scanned = scan(storage, text: text, paragraph: paragraph, clip: NSRange(location: 0, length: total), shared: shared)
            if scanned.isBlank {
                pending.append(scanned)
            } else {
                for candidate in pending where !feed(candidate) {
                    break reading
                }
                pending.removeAll(keepingCapacity: true)
                if !feed(scanned) { break reading }
            }
            let next = NSMaxRange(paragraph)
            guard paragraph.length > 0, next < total || (next == total && text.character(at: total - 1) == MarkdownParagraph.separator)
            else { break }
            cursor = next
        }
        let end = stop ?? total
        let blocks = builder.finishUnits(previous: previous)
        var units: [TopLevelUnit] = []
        units.reserveCapacity(blocks.count)
        for (index, unit) in blocks.enumerated() {
            let from = index == 0 ? start : heads[index]
            let to = index + 1 < heads.count ? heads[index + 1] : end
            units.append(TopLevelUnit(block: unit.block, list: unit.list, length: to - from, leading: heads[index] - from))
        }
        return TopLevelScan(units: units, start: start, end: end, stopped: stop != nil)
    }

    private static func backing(_ storage: NSAttributedString) -> NSString {
        (storage as? NSMutableAttributedString)?.mutableString ?? (storage.string as NSString)
    }

    private func scanParagraphs(_ storage: NSAttributedString, text: NSString, range: NSRange) -> [ScannedParagraph] {
        let total = text.length
        let start = max(0, min(range.location, total))
        let end = max(start, min(NSMaxRange(range), total))
        let clip = NSRange(location: start, length: end - start)
        return storage.markdownParagraphRanges(in: clip).map { paragraph in
            scan(storage, text: text, paragraph: paragraph, clip: clip)
        }
    }

    private func scan(
        _ storage: NSAttributedString,
        text: NSString,
        paragraph: NSRange,
        clip: NSRange,
        shared: UTF16Text? = nil
    ) -> ScannedParagraph {
        let total = text.length
        var content = paragraph
        while content.length > 0, Self.isParagraphSeparator(text.character(at: NSMaxRange(content) - 1)) {
            content.length -= 1
        }
        content = Self.clamp(content, to: clip)
        let window = shared ?? UTF16Text(text, range: content)
        let anchor = paragraph.location < total ? paragraph.location : nil
        let block = anchor.flatMap { storage.markdownBlock(at: $0) } ?? .paragraph
        let lists = anchor.map { Self.textLists(in: storage, at: $0) } ?? []
        let blank = !block.isCode && !block.isTableRow && Self.isBlank(window, content)
        return ScannedParagraph(block: block, lists: lists, range: paragraph, content: content, text: window, isBlank: blank)
    }

    private static func clamp(_ range: NSRange, to clip: NSRange) -> NSRange {
        let lower = max(range.location, clip.location)
        let upper = min(NSMaxRange(range), NSMaxRange(clip))
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    static func isParagraphSeparator(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2029 || unit == 0x85
    }

    private static func isBlank(_ text: UTF16Text, _ range: NSRange) -> Bool {
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            switch text[index] {
            case 0x20, 0x09, MarkdownBreak.utf16:
                index += 1
            default:
                return false
            }
        }
        return true
    }

    static func textLists(in storage: NSAttributedString, at index: Int) -> [NSTextList] {
        guard let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle else {
            return []
        }
        return style.textLists.filter { !$0.markerFormat.rawValue.isEmpty }
    }
}

package struct TopLevelList: Equatable, Sendable {
    package var isOrdered: Bool
    package var sourceMarker: UInt8?

    package func separates(from previous: TopLevelList?) -> Bool {
        guard let previous else { return false }
        return previous.isOrdered == isOrdered && MarkdownTextList.areDistinct(previous.sourceMarker, sourceMarker)
    }
}

package struct TopLevelUnit: Equatable, Sendable {
    package var block: EditorDocument.Block
    package var list: TopLevelList?
    package var length: Int
    package var leading: Int

    package var canAbsorbFollowingParagraphs: Bool {
        switch block {
        case .list, .quote, .code, .table: return true
        case .paragraph, .heading, .thematicBreak, .atom: return false
        }
    }

    @discardableResult
    package mutating func separate(from previous: TopLevelList?) -> Bool {
        guard let list, case .list(var node) = block else { return false }
        let separates = list.separates(from: previous)
        guard separates != node.separatesFromPrevious else { return false }
        node.separatesFromPrevious = separates
        block = .list(node)
        return true
    }
}

package struct TopLevelScan: Sendable {
    package var units: [TopLevelUnit]
    package var start: Int
    package var end: Int
    package var stopped: Bool
}

private struct ScannedParagraph {
    let block: MarkdownBlock
    let lists: [NSTextList]
    let range: NSRange
    let content: NSRange
    let text: UTF16Text
    let isBlank: Bool
}

private enum PathEntry {
    case quote(GroupToken)
    case list(NSTextList)
}

private protocol BlockHost: AnyObject {
    var blocks: [PendingBlock] { get set }
}

private final class RootNode: BlockHost {
    var blocks: [PendingBlock] = []
}

private final class QuoteNode: BlockHost {
    let token: GroupToken
    var blocks: [PendingBlock] = []

    init(token: GroupToken) {
        self.token = token
    }
}

private final class ItemNode: BlockHost {
    let task: TaskState?
    var blocks: [PendingBlock] = []

    init(task: TaskState?) {
        self.task = task
    }
}

private final class ListNode {
    let kind: EditorDocument.ListKind
    var lists: [ObjectIdentifier]
    var items: [ItemNode] = []
    var sourceMarker: UInt8?

    init(list: NSTextList, kind: EditorDocument.ListKind) {
        self.kind = kind
        lists = [ObjectIdentifier(list)]
        sourceMarker = MarkdownTextList.sourceMarker(of: list)
    }

    func accepts(_ list: NSTextList, kind other: EditorDocument.ListKind) -> Bool {
        if lists.contains(ObjectIdentifier(list)) { return true }
        return other.isOrdered == kind.isOrdered
            && !MarkdownTextList.areDistinct(sourceMarker, MarkdownTextList.sourceMarker(of: list))
    }

    func adopt(_ list: NSTextList) {
        let id = ObjectIdentifier(list)
        if !lists.contains(id) { lists.append(id) }
        if sourceMarker == nil { sourceMarker = MarkdownTextList.sourceMarker(of: list) }
    }

    static func kind(of list: NSTextList) -> EditorDocument.ListKind {
        list.hasOrderedMarker ? .ordered(start: list.startingItemNumber) : .bullet
    }
}

private final class CodeNode {
    let language: String?
    let group: GroupToken
    let isIndented: Bool
    var lines: [String] = []

    init(language: String?, group: GroupToken, isIndented: Bool) {
        self.language = language
        self.group = group
        self.isIndented = isIndented
    }
}

private final class TableNode {
    let group: GroupToken
    let alignments: [TableColumnAlignment]
    var rows: [[EditorDocument.TableCell]] = []

    init(group: GroupToken, alignments: [TableColumnAlignment]) {
        self.group = group
        self.alignments = alignments
    }
}

private enum PendingBlock {
    case leaf(EditorDocument.Block)
    case code(CodeNode)
    case table(TableNode)
    case quote(QuoteNode)
    case list(ListNode)
}

private enum OpenContainer {
    case quote(QuoteNode)
    case list(ListNode)

    var host: BlockHost? {
        switch self {
        case .quote(let node): return node
        case .list(let node): return node.items.last
        }
    }
}

private struct TreeBuilder {
    let storage: NSAttributedString
    let root = RootNode()
    var stack: [OpenContainer] = []
    var openCode: CodeNode? {
        didSet { if openCode == nil { openTable = nil } }
    }
    var openTable: TableNode?
    var listKinds: [ObjectIdentifier: EditorDocument.ListKind] = [:]

    init(storage: NSAttributedString) {
        self.storage = storage
    }

    var rootCount: Int { root.blocks.count }

    func dropLastRoot() {
        root.blocks.removeLast()
    }

    mutating func add(_ paragraph: ScannedParagraph) {
        let block = paragraph.block
        let path = Self.path(for: block, lists: paragraph.lists)
        let innermostList = path.lastIndex { if case .list = $0 { return true } else { return false } }
        let startsItem = innermostList != nil && (!block.isContinuation || paragraph.lists.count > block.listDepth)

        if paragraph.isBlank && !startsItem {
            separate(along: path)
            openCode = nil
            return
        }

        let host = resolve(path: path, startingItemAt: startsItem ? innermostList : nil, task: block.task)
        if paragraph.isBlank {
            openCode = nil
            return
        }
        append(paragraph, block: block, to: host)
    }

    func finish() -> EditorDocument {
        EditorDocument(blocks: Self.materialize(root.blocks))
    }

    func finishUnits(previous: TopLevelList?) -> [(block: EditorDocument.Block, list: TopLevelList?)] {
        var previous = previous
        return root.blocks.map { pending in
            let block = Self.materialize(pending, previous: previous)
            let list = Self.signature(of: pending)
            previous = list
            return (block, list)
        }
    }

    private static func path(for block: MarkdownBlock, lists: [NSTextList]) -> [PathEntry] {
        var entries: [PathEntry] = []
        var next = 0
        for container in block.containers {
            switch container {
            case .quote(let token):
                entries.append(.quote(token))
            case .listItem:
                if next < lists.count {
                    entries.append(.list(lists[next]))
                    next += 1
                }
            }
        }
        while next < lists.count {
            entries.append(.list(lists[next]))
            next += 1
        }
        return entries
    }

    private mutating func separate(along path: [PathEntry]) {
        var keep = 0
        while keep < path.count, keep < stack.count {
            switch (path[keep], stack[keep]) {
            case (.quote(let token), .quote(let node)) where node.token == token:
                keep += 1
            case (.list, .list(let node)) where !node.items.isEmpty:
                keep += 1
            default:
                stack.removeSubrange(keep...)
                return
            }
        }
        if keep < stack.count { stack.removeSubrange(keep...) }
    }

    private mutating func resolve(path: [PathEntry], startingItemAt itemLevel: Int?, task: TaskState?) -> BlockHost {
        var level = 0
        while level < path.count {
            let isItemStart = level == itemLevel
            switch path[level] {
            case .quote(let token):
                if level < stack.count, case .quote(let node) = stack[level], node.token == token {
                    level += 1
                    continue
                }
                truncate(to: level)
                stack.append(.quote(QuoteNode(token: token)))
                parentHost(of: level).blocks.append(.quote(lastQuote()))
            case .list(let list):
                let listKind = kind(of: list)
                if level < stack.count, case .list(let node) = stack[level],
                   reuses(node, list: list, kind: listKind) {
                    node.adopt(list)
                    if isItemStart {
                        truncate(to: level + 1)
                        node.items.append(ItemNode(task: task))
                        openCode = nil
                    }
                    level += 1
                    continue
                }
                truncate(to: level)
                let node = ListNode(list: list, kind: listKind)
                node.items.append(ItemNode(task: isItemStart ? task : nil))
                parentHost(of: level).blocks.append(.list(node))
                stack.append(.list(node))
            }
            level += 1
        }
        truncate(to: path.count)
        return stack.last?.host ?? root
    }

    private func reuses(_ node: ListNode, list: NSTextList, kind: EditorDocument.ListKind) -> Bool {
        guard !node.items.isEmpty else { return false }
        return node.accepts(list, kind: kind)
    }

    private mutating func kind(of list: NSTextList) -> EditorDocument.ListKind {
        let id = ObjectIdentifier(list)
        if let cached = listKinds[id] { return cached }
        let kind = ListNode.kind(of: list)
        listKinds[id] = kind
        return kind
    }

    private mutating func truncate(to count: Int) {
        if stack.count > count {
            stack.removeSubrange(count...)
            openCode = nil
        }
    }

    private func parentHost(of level: Int) -> BlockHost {
        level == 0 ? root : (stack[level - 1].host ?? root)
    }

    private func lastQuote() -> QuoteNode {
        guard case .quote(let node) = stack.last else { preconditionFailure() }
        return node
    }

    private mutating func append(_ paragraph: ScannedParagraph, block: MarkdownBlock, to host: BlockHost) {
        let inline = InlineExtractor(storage: storage, text: paragraph.text)
        switch block.leaf {
        case .code(let language, let group, let style):
            let lines = inline.codeLines(in: paragraph.content)
            if let code = openCode, code.group == group, case .code(let last) = host.blocks.last, last === code {
                code.lines.append(contentsOf: lines)
            } else {
                let code = CodeNode(language: language, group: group, isIndented: style == .indented)
                code.lines = lines
                host.blocks.append(.code(code))
                openCode = code
            }
            return
        case .thematicBreak:
            if let atom = inline.blockAtom(in: paragraph.content, leaf: block.leaf) {
                host.blocks.append(.leaf(.atom(atom)))
            } else {
                host.blocks.append(.leaf(.thematicBreak))
            }
        case .tableRow(let group, let alignments, _):
            let cells = inline.tableCells(in: paragraph.content)
            if let table = openTable, table.group == group, case .table(let last) = host.blocks.last, last === table {
                table.rows.append(cells)
            } else {
                let table = TableNode(group: group, alignments: alignments)
                table.rows = [cells]
                host.blocks.append(.table(table))
                openCode = nil
                openTable = table
            }
            return
        case .html:
            if let atom = inline.blockAtom(in: paragraph.content, leaf: block.leaf) {
                host.blocks.append(.leaf(.atom(atom)))
            } else {
                host.blocks.append(.leaf(.paragraph(inline.runs(in: paragraph.content))))
            }
        case .heading(let level):
            host.blocks.append(.leaf(.heading(level: level, inline.runs(in: paragraph.content))))
        case .paragraph:
            host.blocks.append(.leaf(.paragraph(inline.runs(in: paragraph.content))))
        }
        openCode = nil
    }

    private static func signature(of pending: PendingBlock) -> TopLevelList? {
        guard case .list(let node) = pending else { return nil }
        return TopLevelList(isOrdered: node.kind.isOrdered, sourceMarker: node.sourceMarker)
    }

    private static func materialize(_ pending: [PendingBlock]) -> [EditorDocument.Block] {
        var previous: TopLevelList?
        return pending.map { block in
            defer { previous = signature(of: block) }
            return materialize(block, previous: previous)
        }
    }

    private static func materialize(_ block: PendingBlock, previous: TopLevelList?) -> EditorDocument.Block {
        switch block {
        case .leaf(let leaf):
            return leaf
        case .code(let node):
            return .code(EditorDocument.CodeBlock(language: node.language, lines: node.lines, isIndented: node.isIndented))
        case .table(let node):
            return .table(EditorDocument.TableBlock(
                alignments: node.alignments,
                header: node.rows.first ?? [],
                body: Array(node.rows.dropFirst())
            ))
        case .quote(let node):
            return .quote(materialize(node.blocks))
        case .list(let node):
            let list = TopLevelList(isOrdered: node.kind.isOrdered, sourceMarker: node.sourceMarker)
            return .list(EditorDocument.ListBlock(
                kind: node.kind,
                items: node.items.map { EditorDocument.ListItem(task: $0.task, blocks: materialize($0.blocks)) },
                separatesFromPrevious: list.separates(from: previous)
            ))
        }
    }
}

private struct InlineExtractor {
    let storage: NSAttributedString
    let text: UTF16Text

    private func codeText(_ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        guard text.contains(0x00A0, in: range) else { return text.substring(range) }
        var output = ""
        storage.enumerateAttribute(.markdownLiteral, in: range) { value, run, _ in
            let piece = text.substring(run)
            if let literal = value as? String, SeparatorLiteral.isSource(literal) {
                output += piece.replacingOccurrences(of: SeparatorLiteral.substitute, with: literal)
            } else {
                output += piece
            }
        }
        return output
    }

    func codeLines(in range: NSRange) -> [String] {
        var lines: [String] = []
        var current = ""
        storage.enumerateAttribute(.attachment, in: range, options: []) { value, run, _ in
            var start = run.location
            let end = NSMaxRange(run)
            var index = start
            while index < end {
                let unit = text[index]
                if unit == MarkdownBreak.utf16 || unit == MarkdownParagraph.objectReplacement {
                    current += codeText(NSRange(location: start, length: index - start))
                    if unit == MarkdownBreak.utf16 {
                        lines.append(current)
                        current = ""
                    } else if let attachment = value as? ProseSourceAttachment {
                        current += attachment.markdownSource
                    }
                    start = index + 1
                }
                index += 1
            }
            current += codeText(NSRange(location: start, length: end - start))
        }
        lines.append(current)
        return lines
    }

    func blockAtom(in range: NSRange, leaf: MarkdownBlock.Leaf) -> EditorDocument.Atom? {
        var found: EditorDocument.Atom?
        storage.enumerateAttribute(.attachment, in: range, options: []) { value, _, stop in
            guard let attachment = value as? ProseSourceAttachment else { return }
            let kind: String
            switch leaf {
            case .thematicBreak: kind = AtomKind.thematicBreak
            default: kind = attachment.contentKind.isEmpty ? AtomKind.htmlBlock : attachment.contentKind
            }
            found = EditorDocument.Atom(source: attachment.markdownSource, kind: kind)
            stop.pointee = true
        }
        return found
    }

    func tableCells(in range: NSRange) -> [EditorDocument.TableCell] {
        var cells: [EditorDocument.TableCell] = []
        var start = range.location
        let end = NSMaxRange(range)
        var index = start
        while index < end {
            if text[index] == MarkdownTableSeparator.utf16 {
                cells.append(runs(in: NSRange(location: start, length: index - start)))
                start = index + 1
            }
            index += 1
        }
        cells.append(runs(in: NSRange(location: start, length: end - start)))
        return cells
    }

    func runs(in range: NSRange) -> [EditorDocument.InlineRun] {
        var runs: [EditorDocument.InlineRun] = []
        var location = range.location
        let limit = NSMaxRange(range)
        while location < limit {
            var intentRange = NSRange()
            var linkRange = NSRange()
            var literalRange = NSRange()
            var styleRange = NSRange()
            let intentValue = storage.attribute(.markdownInlineIntent, at: location, effectiveRange: &intentRange)
            let linkValue = storage.attribute(.link, at: location, effectiveRange: &linkRange)
            let literalValue = storage.attribute(.markdownLiteral, at: location, effectiveRange: &literalRange)
            let styleValue = storage.attribute(.markdownLinkStyle, at: location, effectiveRange: &styleRange)
            let end = min(limit, NSMaxRange(intentRange), NSMaxRange(linkRange), NSMaxRange(literalRange), NSMaxRange(styleRange))
            let firstRun = runs.count
            let intentBits = (intentValue as? NSNumber)?.uintValue
                ?? MarkdownInlineIntent(attributeValue: intentValue)?.rawValue ?? 0
            let marks = Self.marks(fromIntentBits: intentBits)
            let isSoftBreak = intentBits & MarkdownInlineIntent.softBreak.rawValue != 0
            let link = Self.linkString(linkValue)
            let rawLiteral = literalValue as? String
            let literal = marks.has(.code) && !SeparatorLiteral.isSource(rawLiteral) ? nil : rawLiteral
            var start = location
            var index = location
            while index < end {
                let unit = text[index]
                if unit == MarkdownBreak.utf16 || unit == MarkdownParagraph.objectReplacement {
                    appendText(NSRange(location: start, length: index - start), marks: marks, link: link, literal: literal, to: &runs)
                    if unit == MarkdownBreak.utf16 {
                        runs.append(EditorDocument.InlineRun(isSoftBreak ? .softBreak : .hardBreak))
                    } else if let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ProseSourceAttachment {
                        let atom = EditorDocument.Atom(source: attachment.markdownSource, kind: attachment.contentKind)
                        runs.append(EditorDocument.InlineRun(.atom(atom), marks: marks.minus(.code), link: link))
                    }
                    start = index + 1
                }
                index += 1
            }
            appendText(NSRange(location: start, length: end - start), marks: marks, link: link, literal: literal, to: &runs)
            if link != nil, let style = (styleValue as? String).flatMap(EditorDocument.LinkStyle.init(rawValue:)) {
                for index in firstRun..<runs.count where runs[index].link != nil {
                    runs[index].linkStyle = style
                }
            }
            location = end
        }
        return runs
    }

    private func appendText(
        _ range: NSRange,
        marks: EditorDocument.InlineMarks,
        link: String?,
        literal: String?,
        to runs: inout [EditorDocument.InlineRun]
    ) {
        guard range.length > 0 else { return }
        if marks.has(.code), let literal {
            let restored = text.substring(range).replacingOccurrences(of: SeparatorLiteral.substitute, with: literal)
            appendPlain(restored, marks: marks, link: link, to: &runs)
            return
        }
        guard let literal, let rendered = LiteralDecoder.rendered(literal), !rendered.isEmpty else {
            appendPlain(text.substring(range), marks: marks, link: link, to: &runs)
            return
        }
        let renderedUnits = Array(rendered.utf16)
        let width = renderedUnits.count
        var textStart = range.location
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            if index + width <= end, text.matches(renderedUnits, at: index) {
                if index > textStart {
                    appendPlain(text.substring(NSRange(location: textStart, length: index - textStart)), marks: marks, link: link, to: &runs)
                }
                runs.append(EditorDocument.InlineRun(.literal(text: rendered, source: literal), marks: marks, link: link))
                index += width
                textStart = index
            } else {
                index += 1
            }
        }
        if end > textStart {
            appendPlain(text.substring(NSRange(location: textStart, length: end - textStart)), marks: marks, link: link, to: &runs)
        }
    }

    private func appendPlain(
        _ string: String,
        marks: EditorDocument.InlineMarks,
        link: String?,
        to runs: inout [EditorDocument.InlineRun]
    ) {
        if let last = runs.last, case .text(let previous) = last.content, last.marks == marks, last.link == link {
            runs[runs.count - 1] = .text(previous + string, marks: marks, link: link)
        } else {
            runs.append(.text(string, marks: marks, link: link))
        }
    }

    private static let strongBit = MarkdownInlineIntent.stronglyEmphasized.rawValue
    private static let emphasisBit = MarkdownInlineIntent.emphasized.rawValue
    private static let codeBit = MarkdownInlineIntent.code.rawValue
    private static let strikeBit = MarkdownInlineIntent.strikethrough.rawValue

    static func marks(fromIntentBits bits: UInt) -> EditorDocument.InlineMarks {
        var raw: UInt8 = 0
        if bits & strongBit != 0 { raw |= EditorDocument.InlineMarks.strong.rawValue }
        if bits & emphasisBit != 0 { raw |= EditorDocument.InlineMarks.emphasis.rawValue }
        if bits & codeBit != 0 { raw |= EditorDocument.InlineMarks.code.rawValue }
        if bits & strikeBit != 0 { raw |= EditorDocument.InlineMarks.strikethrough.rawValue }
        return EditorDocument.InlineMarks(rawValue: raw)
    }

    static func linkString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }
}

struct UTF16Text {
    let base: Int
    let units: [UInt16]

    init(_ string: NSString, range: NSRange) {
        base = range.location
        let length = range.length
        units = [UInt16](unsafeUninitializedCapacity: length) { buffer, count in
            if let base = buffer.baseAddress, length > 0 {
                string.getCharacters(base, range: range)
            }
            count = length
        }
    }

    subscript(index: Int) -> UInt16 { units[index - base] }

    func contains(_ unit: UInt16, in range: NSRange) -> Bool {
        units[(range.location - base)..<(NSMaxRange(range) - base)].contains(unit)
    }

    func substring(_ range: NSRange) -> String {
        units.withUnsafeBufferPointer { buffer in
            let slice = UnsafeBufferPointer(rebasing: buffer[(range.location - base)..<(NSMaxRange(range) - base)])
            guard slice.allSatisfy({ $0 < 0x80 }) else {
                return String(decoding: slice, as: UTF16.self)
            }
            return String(unsafeUninitializedCapacity: slice.count) { bytes in
                for index in slice.indices {
                    bytes[index] = UInt8(truncatingIfNeeded: slice[index])
                }
                return slice.count
            }
        }
    }

    func matches(_ other: [UInt16], at index: Int) -> Bool {
        let offset = index - base
        guard offset >= 0, offset + other.count <= units.count else { return false }
        for position in 0..<other.count where units[offset + position] != other[position] {
            return false
        }
        return true
    }
}

package enum SeparatorLiteral {
    package static let substitute = "\u{00A0}"

    static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{85}"
    }

    static func containsSeparator(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isSeparator)
    }

    package static func isSource(_ literal: String?) -> Bool {
        guard let scalars = literal?.unicodeScalars, scalars.count == 1, let scalar = scalars.first else { return false }
        return isSeparator(scalar)
    }

    package static func storable(_ decoded: String) -> String {
        guard containsSeparator(decoded) else { return decoded }
        var out = String.UnicodeScalarView()
        for scalar in decoded.unicodeScalars {
            if isSeparator(scalar) {
                out.append(contentsOf: substitute.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    static func substituting(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard containsSeparator(text) else { return NSAttributedString(string: text, attributes: attributes) }
        let out = NSMutableAttributedString()
        var pending = String.UnicodeScalarView()
        func flush() {
            guard !pending.isEmpty else { return }
            out.append(NSAttributedString(string: String(pending), attributes: attributes))
            pending = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            guard isSeparator(scalar) else {
                pending.append(scalar)
                continue
            }
            flush()
            var literal = attributes
            literal[.markdownLiteral] = String(scalar)
            out.append(NSAttributedString(string: substitute, attributes: literal))
        }
        flush()
        return out
    }

    package static func removeOtherLiterals(in storage: NSMutableAttributedString, range: NSRange) {
        var removable: [NSRange] = []
        storage.enumerateAttribute(.markdownLiteral, in: range) { value, run, _ in
            if value != nil, !isSource(value as? String) { removable.append(run) }
        }
        for run in removable { storage.removeAttribute(.markdownLiteral, range: run) }
    }
}

enum LiteralDecoder {
    private static let cache = Mutex<[String: String]>([:])

    static func rendered(_ source: String) -> String? {
        if SeparatorLiteral.isSource(source) { return SeparatorLiteral.substitute }
        let scalars = source.unicodeScalars
        if scalars.count == 2, scalars.first == "\\", let second = scalars.last, second.isASCII,
           second.properties.generalCategory.isPunctuationOrSymbol {
            return String(second)
        }
        if let numeric = numericEntity(source) {
            return SeparatorLiteral.storable(numeric)
        }
        let value: String
        if let cached = cache.withLock({ $0[source] }) {
            value = cached
        } else {
            let decoded = (try? AttributedString(
                markdown: source,
                options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )).map { String($0.characters) }
            value = decoded ?? ""
            cache.withLock { $0[source] = value }
        }
        return value.isEmpty || value == source ? nil : value
    }

    private static func numericEntity(_ source: String) -> String? {
        guard source.hasPrefix("&#"), source.hasSuffix(";"), source.count > 3 else { return nil }
        var body = source.dropFirst(2).dropLast()
        var radix = 10
        if body.first == "x" || body.first == "X" {
            radix = 16
            body = body.dropFirst()
        }
        guard !body.isEmpty, body.count <= (radix == 16 ? 6 : 7), let value = UInt32(body, radix: radix) else {
            return nil
        }
        guard value != 0, let scalar = Unicode.Scalar(value) else {
            return "\u{FFFD}"
        }
        return String(scalar)
    }
}

private extension Unicode.GeneralCategory {
    var isPunctuationOrSymbol: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
