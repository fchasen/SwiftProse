import Foundation
import os
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct MarkdownLoader {
    public var inlineContentRules: [InlineContentRule]
    public var inlineContentProvider: ProseInlineContentProvider?

    public init(
        inlineContentRules: [InlineContentRule] = [],
        inlineContentProvider: ProseInlineContentProvider? = nil
    ) {
        self.inlineContentRules = inlineContentRules
        self.inlineContentProvider = inlineContentProvider
    }

    public func load(_ markdown: String) -> NSMutableAttributedString {
        loadWithReport(markdown).storage
    }

    static let logger = Logger(subsystem: "SwiftProse", category: "Loader")

    static let parsingOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible,
        languageCode: nil,
        appliesSourcePositionAttributes: true
    )

    static func normalizeLineEndings(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func loadWithReport(_ markdown: String) -> (storage: NSMutableAttributedString, report: LoaderReport) {
        let normalized = Self.normalizeLineEndings(markdown)
        var report = LoaderReport()
        guard !normalized.isEmpty else { return (NSMutableAttributedString(), report) }
        let source = MarkdownSourceText(normalized)
        guard let parsed = try? AttributedString(markdown: normalized, options: Self.parsingOptions) else {
            return (Self.plainFallback(normalized), report)
        }
        let structure = LoaderStructure(source: source, runs: LoaderRun.runs(of: parsed))
        report.recoveredLines = structure.recoveredLines
        var inline = LoaderInline(source: source)
        var paragraphs: [(content: NSAttributedString, block: MarkdownBlock, lists: [NSTextList])] = []

        for leaf in structure.leaves {
            let containers = leaf.containers
            let lists = leaf.textLists
            switch leaf.kind {
            case .paragraph, .heading:
                let startByte = leaf.lines.map { source.lineStarts[$0.lowerBound - 1] } ?? 0
                let endByte = leaf.lines.map { source.lineByteRange($0.upperBound).upperBound }
                let content = inline.build(leaf.runs, startByte: startByte, endByte: endByte) { line in
                    structure.stripContinuationPrefix(line, chain: leaf.chain, markerLine: false)
                }
                var task: TaskState?
                if leaf.chain.last.map(Self.isItem) == true, !leaf.isContinuation, case .paragraph = leaf.kind {
                    task = Self.stripTask(content)
                }
                applyInlineContentRules(to: content)
                let leafValue: MarkdownBlock.Leaf
                if case .heading(let level) = leaf.kind {
                    leafValue = .heading(level: level)
                } else {
                    leafValue = .paragraph
                }
                let block = MarkdownBlock(
                    leaf: leafValue,
                    containers: containers,
                    isContinuation: leaf.isContinuation,
                    task: task
                )
                paragraphs.append((content, block, lists))
            case .code(let language):
                let group = GroupToken.mint()
                var lines = leaf.runs.map(\.text).joined().components(separatedBy: "\n")
                if lines.count > 1, lines.last == "" { lines.removeLast() }
                for (index, line) in lines.enumerated() {
                    let block = MarkdownBlock(
                        leaf: .code(language: language, group: group),
                        containers: containers,
                        isContinuation: !lists.isEmpty && (leaf.isContinuation || index > 0)
                    )
                    paragraphs.append((SeparatorLiteral.substituting(line, attributes: [:]), block, lists))
                }
            case .thematicBreak:
                let attachment = HorizontalRuleAttachment(color: .horizontalRuleDefault)
                attachment.markdownSource = leaf.thematicSource ?? "---"
                let block = MarkdownBlock(leaf: .thematicBreak, containers: containers, isContinuation: leaf.isContinuation)
                paragraphs.append((LoaderInline.atom(attachment, intent: [], link: nil), block, lists))
            case .table(let columns):
                let table = tableSources(for: leaf, columns: columns, in: structure)
                let group = GroupToken.mint()
                let inList = !lists.isEmpty
                for (index, cells) in table.rows.enumerated() {
                    let content = NSMutableAttributedString()
                    for (column, cell) in cells.enumerated() {
                        if column > 0 { content.append(Self.tableSeparator()) }
                        content.append(tableCell(cell, report: &report))
                    }
                    let block = MarkdownBlock(
                        leaf: .tableRow(group: group, alignments: table.alignments, isHeader: index == 0),
                        containers: containers,
                        isContinuation: index == 0 ? leaf.isContinuation : inList
                    )
                    paragraphs.append((content, block, lists))
                }
            case .html:
                var html = leaf.runs.map(\.text).joined()
                if html.hasSuffix("\n") { html.removeLast() }
                let attachment = HTMLBlockAttachment(markdownSource: html)
                let block = MarkdownBlock(leaf: .html, containers: containers, isContinuation: leaf.isContinuation)
                paragraphs.append((LoaderInline.atom(attachment, intent: [], link: nil), block, lists))
            }
        }
        report.fallbackRuns = inline.fallbackRuns

        let storage = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let start = storage.length
            storage.append(paragraph.content)
            let isLast = index == paragraphs.count - 1
            if !isLast || paragraph.content.length == 0 {
                storage.append(NSAttributedString(string: "\n"))
            }
            let range = NSRange(location: start, length: storage.length - start)
            guard range.length > 0 else { continue }
            storage.addAttribute(.markdownBlock, value: paragraph.block, range: range)
            if !paragraph.lists.isEmpty {
                let style = NSMutableParagraphStyle()
                style.textLists = paragraph.lists
                storage.addAttribute(.paragraphStyle, value: style.copy(), range: range)
            }
        }
        return (storage, report)
    }

    private static func isItem(_ link: LoaderLink) -> Bool {
        if case .item = link { return true }
        return false
    }

    static func plainFallback(_ text: String) -> NSMutableAttributedString {
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return NSMutableAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [.markdownBlock: MarkdownBlock.paragraph]
        )
    }

    static func stripTask(_ content: NSMutableAttributedString) -> TaskState? {
        let ns = content.string as NSString
        guard ns.length >= 3 else { return nil }
        let marker = ns.substring(to: 3)
        let state: TaskState
        switch marker {
        case "[ ]": state = .unchecked
        case "[x]", "[X]": state = .checked
        default: return nil
        }
        let removable: Int
        if ns.length == 3 {
            removable = 3
        } else {
            let next = ns.character(at: 3)
            guard next == 0x20 || next == 0x09 else { return nil }
            removable = 4
        }
        for index in 0..<removable {
            if content.markdownLiteral(at: index) != nil
                || content.attribute(.attachment, at: index, effectiveRange: nil) != nil
                || content.markdownLink(at: index) != nil
                || !content.markdownInlineIntent(at: index).isEmpty {
                return nil
            }
        }
        content.deleteCharacters(in: NSRange(location: 0, length: removable))
        return state
    }

    func applyInlineContentRules(to content: NSMutableAttributedString) {
        guard !inlineContentRules.isEmpty, let provider = inlineContentProvider, content.length > 1 else { return }
        let text = content.string
        let ns = text as NSString
        var claimed: [(range: NSRange, attachment: NSTextAttachment & ProseSourceAttachment)] = []
        for rule in inlineContentRules {
            rule.regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, _ in
                guard let result, result.range.length > 1 else { return }
                let range = result.range
                guard !claimed.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
                guard Self.isRuleEligible(content, range: range) else { return }
                var groups: [String?] = []
                for index in 0..<result.numberOfRanges {
                    let group = result.range(at: index)
                    groups.append(group.location == NSNotFound ? nil : ns.substring(with: group))
                }
                let matched = ns.substring(with: range)
                guard let inlineContent = rule.content(InlineContentMatch(matched: matched, groups: groups)),
                      let attachment = provider(inlineContent) as? (NSTextAttachment & ProseSourceAttachment)
                else { return }
                attachment.markdownSource = matched
                if attachment.contentKind.isEmpty { attachment.contentKind = inlineContent.kind }
                claimed.append((range, attachment))
            }
        }
        for claim in claimed.sorted(by: { $0.range.location > $1.range.location }) {
            var attributes = content.attributes(at: claim.range.location, effectiveRange: nil)
            attributes[.attachment] = claim.attachment
            content.replaceCharacters(in: claim.range, with: NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }
    }

    private static func isRuleEligible(_ content: NSAttributedString, range: NSRange) -> Bool {
        let firstIntent = content.markdownInlineIntent(at: range.location)
        for index in range.location..<NSMaxRange(range) {
            if content.isMarkdownBreak(at: index)
                || content.markdownLiteral(at: index) != nil
                || content.markdownLink(at: index) != nil
                || content.attribute(.attachment, at: index, effectiveRange: nil) != nil {
                return false
            }
            let intent = content.markdownInlineIntent(at: index)
            if intent.contains(.code) || intent != firstIntent { return false }
        }
        return true
    }

    static func tableSeparator() -> NSAttributedString {
        NSAttributedString(string: MarkdownTableSeparator.string, attributes: [.markdownTableSeparator: true])
    }

    private func tableSources(
        for leaf: LoaderLeaf,
        columns: [PresentationIntent.TableColumn],
        in structure: LoaderStructure
    ) -> (alignments: [TableColumnAlignment], rows: [[String]]) {
        let fallbackAlignments = columns.map(Self.alignment)
        guard let lines = leaf.lines, lines.count >= 2 else {
            return Self.fitted(fallbackAlignments, Self.tableRowTexts(leaf.runs, columnCount: columns.count))
        }
        let texts = lines.map { line in
            structure.stripContinuationPrefix(
                line,
                chain: leaf.chain,
                markerLine: line == lines.lowerBound && !leaf.newItemKeys.isEmpty
            )
        }
        let alignments = TableSource.alignments(ofDelimiterRow: texts[1]) ?? fallbackAlignments
        var rows = [TableSource.cells(ofRow: texts[0])]
        rows.append(contentsOf: texts.dropFirst(2).map(TableSource.cells(ofRow:)))
        return Self.fitted(alignments, rows)
    }

    private static func fitted(_ alignments: [TableColumnAlignment], _ rows: [[String]]) -> (alignments: [TableColumnAlignment], rows: [[String]]) {
        let width = max(1, alignments.count)
        let padded = alignments.count == width ? alignments : alignments + Array(repeating: .none, count: width - alignments.count)
        let fittedRows = (rows.isEmpty ? [[]] : rows).map { row -> [String] in
            let clipped = Array(row.prefix(width))
            return clipped + Array(repeating: "", count: width - clipped.count)
        }
        return (padded, fittedRows)
    }

    private static func alignment(_ column: PresentationIntent.TableColumn) -> TableColumnAlignment {
        switch column.alignment {
        case .center: return .center
        case .right: return .right
        default: return .none
        }
    }

    private func tableCell(_ source: String, report: inout LoaderReport) -> NSMutableAttributedString {
        let text = TableSource.unescapingPipes(source)
        guard !text.isEmpty else { return NSMutableAttributedString() }
        guard let parsed = try? AttributedString(markdown: text, options: LoaderInline.inlineOptions) else {
            return NSMutableAttributedString(string: text)
        }
        let cellSource = MarkdownSourceText(text)
        var inline = LoaderInline(source: cellSource)
        let content = inline.build(LoaderRun.runs(of: parsed), startByte: 0, endByte: cellSource.bytes.count)
        report.fallbackRuns += inline.fallbackRuns
        applyInlineContentRules(to: content)
        let ns = content.string as NSString
        for index in stride(from: ns.length - 1, through: 0, by: -1) {
            let unit = ns.character(at: index)
            if unit == MarkdownBreak.utf16 || unit == MarkdownTableSeparator.utf16 || unit == MarkdownParagraph.separator {
                content.replaceCharacters(in: NSRange(location: index, length: 1), with: " ")
            }
        }
        return content
    }

    static func tableRowTexts(_ runs: [LoaderRun], columnCount: Int) -> [[String]] {
        var rows: [Int: [Int: String]] = [:]
        for run in runs {
            guard let components = run.intent?.components else { continue }
            var row = 0
            var column = 0
            for component in components {
                switch component.kind {
                case .tableHeaderRow: row = 0
                case .tableRow(let index): row = index
                case .tableCell(let index): column = index
                default: break
                }
            }
            let text = run.inline.contains(.softBreak) || run.inline.contains(.lineBreak) ? " " : run.text
            rows[row, default: [:]][column, default: ""] += text.replacingOccurrences(of: "|", with: "\\|")
        }
        guard let lastRow = rows.keys.max() else { return [] }
        return (0...lastRow).map { row in
            (0..<max(1, columnCount)).map { column in rows[row]?[column] ?? "" }
        }
    }
}
