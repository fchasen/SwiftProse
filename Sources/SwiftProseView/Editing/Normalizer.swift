import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

package struct Normalizer {
    @discardableResult
    func normalize(
        _ storage: NSMutableAttributedString,
        editedRange: NSRange,
        changeInLength: Int = 0,
        markedRange: NSRange? = nil
    ) -> NSRange {
        normalizeRecordingRevert(
            storage,
            editedRange: editedRange,
            changeInLength: changeInLength,
            markedRange: markedRange,
            recordsRevert: false
        ).touched
    }

    func normalizeRecordingRevert(
        _ storage: NSMutableAttributedString,
        editedRange: NSRange,
        changeInLength: Int = 0,
        markedRange: NSRange? = nil,
        recordsRevert: Bool = true
    ) -> NormalizationResult {
        let total = storage.length
        let edited = Self.clamp(editedRange, to: total)
        guard total > 0 else { return NormalizationResult(touched: NSRange(location: 0, length: 0)) }

        let paragraphs = Self.affectedParagraphs(for: edited, in: storage).filter { paragraph in
            !(markedRange.map { Self.paragraph(paragraph, intersects: $0) } ?? false)
        }
        guard let firstParagraph = paragraphs.first, let lastParagraph = paragraphs.last else {
            return NormalizationResult(touched: NSRange(location: edited.location, length: 0))
        }
        let touched = NSUnionRange(firstParagraph, lastParagraph)
        let before = recordsRevert ? VocabularySnapshot(capturing: storage, in: touched) : nil

        for paragraph in paragraphs {
            normalizeParagraph(paragraph, in: storage, edited: edited)
        }
        uncheckTasksCreatedByReturn(in: storage, edited: edited, changeInLength: changeInLength, markedRange: markedRange)

        guard let before, !before.matches(storage) else { return NormalizationResult(touched: touched) }
        return NormalizationResult(touched: touched, revert: before)
    }

    static func affectedParagraphs(for editedRange: NSRange, in storage: NSAttributedString) -> [NSRange] {
        let total = storage.length
        guard total > 0 else { return [] }
        let edited = clamp(editedRange, to: total)
        var paragraphs = storage.markdownParagraphRanges(in: edited).filter { $0.length > 0 }
        if paragraphs.isEmpty {
            paragraphs = [storage.markdownParagraphRange(at: max(0, edited.location - 1))]
        }
        if let first = paragraphs.first, first.location > 0 {
            paragraphs.insert(storage.markdownParagraphRange(at: first.location - 1), at: 0)
        }
        if let last = paragraphs.last, NSMaxRange(last) < total {
            paragraphs.append(storage.markdownParagraphRange(at: NSMaxRange(last)))
        }
        return paragraphs.filter { $0.length > 0 }
    }

    static func affectedRange(for editedRange: NSRange, in storage: NSAttributedString) -> NSRange {
        let paragraphs = affectedParagraphs(for: editedRange, in: storage)
        guard let first = paragraphs.first, let last = paragraphs.last else {
            return clamp(editedRange, to: storage.length)
        }
        return NSUnionRange(first, last)
    }

    @discardableResult
    func normalizeAll(
        _ storage: NSMutableAttributedString,
        markedRange: NSRange? = nil,
        recordsRevert: Bool = false
    ) -> NormalizationResult {
        let full = NSRange(location: 0, length: storage.length)
        let before = recordsRevert ? VocabularySnapshot(capturing: storage, in: full) : nil
        for paragraph in storage.markdownParagraphRanges() where paragraph.length > 0 {
            if let markedRange, Self.paragraph(paragraph, intersects: markedRange) { continue }
            normalizeParagraph(paragraph, in: storage, edited: full)
        }
        guard let before, !before.matches(storage) else { return NormalizationResult(touched: full) }
        return NormalizationResult(touched: full, revert: before)
    }

    private func normalizeParagraph(_ paragraph: NSRange, in storage: NSMutableAttributedString, edited: NSRange) {
        let ns = storage.string as NSString
        let hasSeparator = ns.character(at: NSMaxRange(paragraph) - 1) == MarkdownParagraph.separator
        let content = NSRange(location: paragraph.location, length: paragraph.length - (hasSeparator ? 1 : 0))

        let seed = seedBlock(in: paragraph, storage: storage, edited: edited) ?? .paragraph
        let lists = MarkdownTextList.effectiveTextLists(in: storage, at: paragraph.location)
        var block = Self.reconcile(seed, listCount: lists.count)
        if block.isAtom, !Self.containsSourceAttachment(in: content, storage: storage) {
            block = block.with(leaf: .paragraph)
        }
        if block.isTableRow {
            block = Self.positionedTableRow(block, at: paragraph, in: storage)
        }
        applyBlock(block, to: paragraph, in: storage)
        normalizeTableSeparators(in: paragraph, content: content, isTableRow: block.isTableRow, storage: storage)

        if block.isCode {
            storage.removeAttribute(.markdownInlineIntent, range: paragraph)
            storage.removeAttribute(.link, range: paragraph)
            SeparatorLiteral.removeOtherLiterals(in: storage, range: paragraph)
            dropStaleLiterals(in: content, storage: storage)
        } else {
            dropStaleLiterals(in: content, storage: storage)
            stripSoftBreakBits(in: content, storage: storage)
        }

        if hasSeparator {
            let separator = NSRange(location: NSMaxRange(paragraph) - 1, length: 1)
            storage.removeAttribute(.link, range: separator)
            storage.removeAttribute(.markdownLiteral, range: separator)
        }
    }

    static func positionedTableRow(_ block: MarkdownBlock, at paragraph: NSRange, in storage: NSAttributedString) -> MarkdownBlock {
        guard case .tableRow(let group, let alignments, let isHeader) = block.leaf else { return block }
        let previous = paragraph.location > 0 ? storage.markdownBlock(at: paragraph.location - 1) : nil
        let leaf: MarkdownBlock.Leaf
        if let previous, previous.tableGroup == group {
            leaf = .tableRow(group: group, alignments: previous.tableAlignments, isHeader: false)
        } else {
            leaf = .tableRow(group: group, alignments: alignments.isEmpty ? [.none] : alignments, isHeader: true)
        }
        if case .tableRow(_, let newAlignments, let newHeader) = leaf, newAlignments == alignments, newHeader == isHeader {
            return block
        }
        return block.with(leaf: leaf)
    }

    private func normalizeTableSeparators(
        in paragraph: NSRange,
        content: NSRange,
        isTableRow: Bool,
        storage: NSMutableAttributedString
    ) {
        guard isTableRow else {
            var stale: [NSRange] = []
            storage.enumerateAttribute(.markdownTableSeparator, in: paragraph) { value, run, _ in
                if value != nil { stale.append(run) }
            }
            for run in stale { storage.removeAttribute(.markdownTableSeparator, range: run) }
            return
        }
        let ns = storage.string as NSString
        var separators: [NSRange] = []
        var stale: [NSRange] = []
        for index in content.location..<NSMaxRange(content) {
            let range = NSRange(location: index, length: 1)
            if ns.character(at: index) == MarkdownTableSeparator.utf16 {
                separators.append(range)
            } else if storage.attribute(.markdownTableSeparator, at: index, effectiveRange: nil) != nil {
                stale.append(range)
            }
        }
        for range in stale { storage.removeAttribute(.markdownTableSeparator, range: range) }
        for range in separators {
            let attributes = storage.attributes(at: range.location, effectiveRange: nil)
            if attributes[.markdownTableSeparator] == nil {
                storage.addAttribute(.markdownTableSeparator, value: true, range: range)
            }
            for key in [NSAttributedString.Key.markdownInlineIntent, .link, .markdownLiteral] where attributes[key] != nil {
                storage.removeAttribute(key, range: range)
            }
        }
    }

    static func tableRepairs(in storage: NSAttributedString, range: NSRange) -> [(range: NSRange, replacement: String)] {
        let total = storage.length
        guard total > 0 else { return [] }
        let ns = storage.string as NSString
        var repairs: [(range: NSRange, replacement: String)] = []
        for paragraph in storage.markdownParagraphRanges(in: clamp(range, to: total)) where paragraph.length > 0 {
            guard let block = storage.markdownBlock(at: paragraph.location), block.isTableRow else { continue }
            let content = storage.markdownTableContentRange(ofRow: paragraph)
            let wanted = max(1, block.tableAlignments.count) - 1
            var separators = 0
            for index in content.location..<NSMaxRange(content) {
                let unit = ns.character(at: index)
                if unit == MarkdownTableSeparator.utf16 {
                    separators += 1
                    if separators > wanted {
                        repairs.append((NSRange(location: index, length: 1), " "))
                    }
                } else if unit == MarkdownBreak.utf16 || unit == 0x2029 || unit == 0x0D || unit == 0x85 {
                    repairs.append((NSRange(location: index, length: 1), " "))
                }
            }
            if separators < wanted {
                repairs.append((
                    NSRange(location: NSMaxRange(content), length: 0),
                    String(repeating: MarkdownTableSeparator.string, count: wanted - separators)
                ))
            }
        }
        return repairs
    }

    private func seedBlock(in paragraph: NSRange, storage: NSAttributedString, edited: NSRange) -> MarkdownBlock? {
        var preserved: MarkdownBlock?
        var any: MarkdownBlock?
        storage.enumerateAttribute(.markdownBlock, in: paragraph) { value, run, stop in
            guard let block = value as? MarkdownBlock else { return }
            if any == nil { any = block }
            if Self.hasIndexOutside(edited, in: run) {
                preserved = block
                stop.pointee = true
            }
        }
        return preserved ?? any
    }

    private func applyBlock(_ block: MarkdownBlock, to paragraph: NSRange, in storage: NSMutableAttributedString) {
        var effective = NSRange()
        let current = storage.attribute(
            .markdownBlock,
            at: paragraph.location,
            longestEffectiveRange: &effective,
            in: paragraph
        ) as? MarkdownBlock
        if let current, current.isEqual(block), NSEqualRanges(effective, paragraph) { return }
        storage.addAttribute(.markdownBlock, value: block, range: paragraph)
    }

    static func reconcile(_ block: MarkdownBlock, listCount: Int) -> MarkdownBlock {
        let depth = block.listDepth
        var containers = block.containers
        var isContinuation = block.isContinuation
        var task = block.task

        if listCount > depth {
            containers.append(contentsOf: Array(repeating: .listItem, count: listCount - depth))
            isContinuation = false
        } else if listCount < depth {
            var remaining = depth
            while remaining > listCount, let index = containers.lastIndex(of: .listItem) {
                containers.remove(at: index)
                remaining -= 1
            }
        }

        if listCount == 0 {
            isContinuation = false
            task = nil
        } else if isContinuation || block.leaf != .paragraph {
            task = nil
        }

        guard containers != block.containers || isContinuation != block.isContinuation || task != block.task else {
            return block
        }
        return MarkdownBlock(leaf: block.leaf, containers: containers, isContinuation: isContinuation, task: task)
    }

    private static func containsSourceAttachment(in range: NSRange, storage: NSAttributedString) -> Bool {
        guard range.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value is ProseSourceAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func dropStaleLiterals(in content: NSRange, storage: NSMutableAttributedString) {
        guard content.length > 0 else { return }
        let ns = storage.string as NSString
        var stale: [NSRange] = []
        storage.enumerateAttribute(.markdownLiteral, in: content) { value, run, _ in
            guard let source = value as? String else {
                if value != nil { stale.append(run) }
                return
            }
            let rendered = Self.renderedText(forLiteral: source)
            var index = run.location
            while index < NSMaxRange(run) {
                let composed = ns.rangeOfComposedCharacterSequence(at: index)
                let character = NSIntersectionRange(composed, run)
                let keep = rendered != nil
                    && ns.substring(with: character) == rendered
                    && (SeparatorLiteral.isSource(source) || !storage.markdownInlineIntent(at: index).contains(.code))
                if !keep { stale.append(character) }
                index = NSMaxRange(character)
            }
        }
        for range in stale { storage.removeAttribute(.markdownLiteral, range: range) }
    }

    private func stripSoftBreakBits(in content: NSRange, storage: NSMutableAttributedString) {
        guard content.length > 0 else { return }
        let ns = storage.string as NSString
        var fixes: [(NSRange, MarkdownInlineIntent)] = []
        storage.enumerateAttribute(.markdownInlineIntent, in: content) { value, run, _ in
            guard let intent = MarkdownInlineIntent(attributeValue: value), intent.contains(.softBreak) else { return }
            let stripped = intent.subtracting(.softBreak)
            for index in run.location..<NSMaxRange(run) where ns.character(at: index) != MarkdownBreak.utf16 {
                fixes.append((NSRange(location: index, length: 1), stripped))
            }
        }
        for (range, intent) in fixes {
            if intent.isEmpty {
                storage.removeAttribute(.markdownInlineIntent, range: range)
            } else {
                storage.addAttribute(.markdownInlineIntent, value: intent.attributeValue, range: range)
            }
        }
    }

    private func uncheckTasksCreatedByReturn(
        in storage: NSMutableAttributedString,
        edited: NSRange,
        changeInLength: Int,
        markedRange: NSRange?
    ) {
        guard edited.length > 0, changeInLength == edited.length else { return }
        let ns = storage.string as NSString
        let inserted = edited.location..<NSMaxRange(edited)
        guard inserted.allSatisfy({ ns.character(at: $0) == MarkdownParagraph.separator }) else { return }
        for index in inserted {
            let upper = storage.markdownParagraphRange(at: index)
            let lowerStart = index + 1
            guard lowerStart < storage.length else { continue }
            let lower = storage.markdownParagraphRange(at: lowerStart)
            if let markedRange,
               Self.paragraph(upper, intersects: markedRange) || Self.paragraph(lower, intersects: markedRange) {
                continue
            }
            guard let upperBlock = storage.markdownBlock(at: upper.location),
                  let lowerBlock = storage.markdownBlock(at: lower.location),
                  upperBlock.task != nil else { continue }
            let upperIsEmpty = upper.length <= 1
            if upperIsEmpty, upperBlock.task == .checked, lowerBlock.task != nil {
                storage.addAttribute(.markdownBlock, value: upperBlock.with(task: .unchecked), range: upper)
            } else if !upperIsEmpty, lowerBlock.task == .checked {
                storage.addAttribute(.markdownBlock, value: lowerBlock.with(task: .unchecked), range: lower)
            }
        }
    }

    static func renderedText(forLiteral source: String) -> String? {
        if SeparatorLiteral.isSource(source) { return SeparatorLiteral.substitute }
        if source.hasPrefix("\\") {
            let rest = source.dropFirst()
            return rest.count == 1 ? String(rest) : nil
        }
        guard source.hasPrefix("&"), source.hasSuffix(";"), source.count > 2 else { return nil }
        let body = source.dropFirst().dropLast()
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value else { return nil }
            guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
            return SeparatorLiteral.storable(String(Character(scalar)))
        }
        if let named = namedEntities[String(body)] { return named }
        guard let parsed = try? AttributedString(markdown: source) else { return nil }
        let text = String(parsed.characters)
        return text.isEmpty || text == source ? nil : text
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "hellip": "\u{2026}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "deg": "\u{00B0}", "plusmn": "\u{00B1}",
        "middot": "\u{00B7}", "bull": "\u{2022}", "para": "\u{00B6}", "sect": "\u{00A7}",
        "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}"
    ]

    package static func clamp(_ range: NSRange, to total: Int) -> NSRange {
        let start = max(0, min(range.location, total))
        let end = max(start, min(range.location + max(0, range.length), total))
        return NSRange(location: start, length: end - start)
    }

    private static func hasIndexOutside(_ edited: NSRange, in run: NSRange) -> Bool {
        guard edited.length > 0 else { return run.length > 0 }
        return run.location < edited.location || NSMaxRange(run) > NSMaxRange(edited)
    }

    static func paragraph(_ paragraph: NSRange, intersects marked: NSRange) -> Bool {
        if marked.length == 0 {
            return marked.location >= paragraph.location && marked.location < NSMaxRange(paragraph)
        }
        return NSIntersectionRange(paragraph, marked).length > 0
    }
}
