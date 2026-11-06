#if os(macOS)
import AppKit
import Foundation
@_spi(Harness) import SwiftProse

/// One invariant violation, with everything needed to shrink toward it.
struct OracleFailure: Error, CustomStringConvertible, Equatable {
    /// Oracle id — the first half of the shrink signature.
    var oracle: String
    /// Human-readable body. Diffs live here.
    var detail: String
    /// Op index the failure was noticed after. -1 for an end-of-run check.
    var opIndex: Int

    /// What ddmin compares: stable across runs, insensitive to offsets and
    /// document content that shrinking is trying to remove.
    var signature: String {
        var normalized = detail
        normalized = normalized.replacingOccurrences(
            of: "[0-9]+", with: "#", options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: "«[^»]*»", with: "«»", options: .regularExpression
        )
        let firstLine = normalized.split(separator: "\n").first.map(String.init) ?? normalized
        return "\(oracle):\(firstLine.prefix(120))"
    }

    var description: String { "[\(oracle)] op \(opIndex): \(detail)" }
}

/// Invariant checks over the live editor, tiered by cost.
///
/// Cadences are per-op counters, not wall clock: a fuzz run of N ops does
/// the same work regardless of how fast the machine is, so a failure
/// reproduces from the seed alone.
@MainActor
final class Oracles {

    struct Cadence {
        var groups = 25
        var normalizer = 25
        var vocabularyFull = 50
        var reader = 100
        var serialization = 100
        var markdownFixpoint = 250
        var history = 500
        var layout = 500

        /// Everything on every op — what a scenario over a tiny document
        /// wants.
        static let everyOp = Cadence(
            groups: 1, normalizer: 1, vocabularyFull: 1, reader: 1, serialization: 1,
            markdownFixpoint: 0, history: 0, layout: 0
        )

        /// Scaled for a large document, where a whole-document pass is the
        /// dominant cost.
        static func scaled(forLength length: Int) -> Cadence {
            guard length > 4_000 else { return Cadence() }
            let factor = max(1, length / 4_000)
            var c = Cadence()
            c.groups *= factor
            c.normalizer *= factor
            c.vocabularyFull *= factor
            c.reader *= factor
            c.serialization *= factor
            return c
        }
    }

    let controller: EditorController
    let textView: NSTextView
    var cadence: Cadence
    /// Oracles disabled for this run.
    var disabled: Set<String> = []
    /// Every failure seen, so one fuzz run reports many.
    private(set) var failures: [OracleFailure] = []
    /// The last `load`ed markdown — the `history` oracle undoes back to it.
    var baselineMarkdown: String?
    /// Per-op durations in seconds, for the `latency` report.
    private(set) var opDurations: [Double] = []

    static let allIDs = [
        "length", "vocabulary", "scalars", "groups", "normalizer",
        "vocabularyFull", "reader", "serialization", "markdownFixpoint", "history", "layout", "latency"
    ]

    /// The always-on set: cheap enough for every op on any document.
    static let tier0 = ["length", "vocabulary", "scalars"]

    init(controller: EditorController, textView: NSTextView, cadence: Cadence = Cadence()) {
        self.controller = controller
        self.textView = textView
        self.cadence = cadence
    }

    /// Record a failure the driver produced rather than an oracle.
    func note(_ failure: OracleFailure) { failures.append(failure) }

    func reset() {
        failures.removeAll()
        opDurations.removeAll()
    }

    func record(duration: Double) { opDurations.append(duration) }

    // MARK: - Dispatch

    /// Throw on the first failure unless set.
    var collectAll = false

    func checkCadenced(at index: Int, op: EditOp) throws {
        var ids = Self.tier0
        if case .check(let requested) = op { ids += requested }
        func due(_ every: Int) -> Bool { every > 0 && (index + 1) % every == 0 }
        if due(cadence.groups) { ids.append("groups") }
        if due(cadence.normalizer) { ids.append("normalizer") }
        if due(cadence.vocabularyFull) { ids.append("vocabularyFull") }
        if due(cadence.reader) { ids.append("reader") }
        if due(cadence.serialization) { ids.append("serialization") }
        if due(cadence.markdownFixpoint) { ids.append("markdownFixpoint") }
        if due(cadence.history) { ids.append("history") }
        if due(cadence.layout) { ids.append("layout") }
        try run(ids, at: index)
    }

    @discardableResult
    func run(_ ids: [String], at index: Int) throws -> [OracleFailure] {
        var found: [OracleFailure] = []
        var seen = Set<String>()
        for id in ids where !disabled.contains(id) && seen.insert(id).inserted {
            found += check(id, at: index)
        }
        failures += found
        if !collectAll, let first = found.first { throw EditDriver.Failure.oracle(first) }
        return found
    }

    /// Expand the shorthand a scenario's `finally` list may use.
    static func expand(_ ids: [String]) -> [String] {
        var out: [String] = []
        for id in ids {
            switch id {
            case "tier0": out += tier0
            case "all": out += allIDs
            default: out.append(id)
            }
        }
        return out
    }

    /// The end-of-run tier the fuzzer and replay run once.
    static let endOfRun = [
        "markdownFixpoint", "history", "layout", "reader", "serialization", "vocabularyFull", "groups", "normalizer"
    ]

    func check(_ id: String, at index: Int) -> [OracleFailure] {
        HarnessLaunch.trace("oracle \(id) @\(index)")
        func fail(_ detail: String) -> [OracleFailure] {
            [OracleFailure(oracle: id, detail: detail, opIndex: index)]
        }
        let detail: String?
        switch id {
        case "length": detail = checkLength()
        case "vocabulary": detail = checkVocabulary(in: localRange())
        case "scalars": detail = checkScalars()
        case "groups": detail = checkGroups()
        case "normalizer": detail = controller.harnessNormalizationDrift()
        case "vocabularyFull":
            detail = checkVocabulary(in: NSRange(location: 0, length: controller.textStorage.length))
        case "reader": detail = checkReader()
        case "serialization": detail = controller.harnessSerializationDrift()
        case "markdownFixpoint": detail = checkMarkdownFixpoint()
        case "history": detail = checkHistory()
        case "layout": detail = checkLayout()
        case "latency": detail = nil
        default: detail = "unknown oracle id"
        }
        return detail.map(fail) ?? []
    }

    // MARK: - Tier 0

    /// No edit may cut a surrogate pair in half.
    private func checkScalars() -> String? {
        let string = controller.textStorage.string as NSString
        var i = 0
        while i < string.length {
            let unit = string.character(at: i)
            if (0xD800...0xDBFF).contains(unit) {
                let next: unichar = i + 1 < string.length ? string.character(at: i + 1) : 0
                guard (0xDC00...0xDFFF).contains(next) else { return "unpaired high surrogate at \(i)" }
                i += 2
                continue
            }
            if (0xDC00...0xDFFF).contains(unit) { return "unpaired low surrogate at \(i)" }
            i += 1
        }
        return nil
    }

    private func checkLength() -> String? {
        let storageLength = controller.textStorage.length
        let viewLength = (textView.string as NSString).length
        if viewLength != storageLength {
            return "text view string \(viewLength) != storage \(storageLength)"
        }
        let content = controller.textContentStorage
        let documentLength = content.offset(
            from: content.documentRange.location, to: content.documentRange.endLocation
        )
        if documentLength != storageLength {
            return "textContentStorage.documentRange \(documentLength) != storage \(storageLength)"
        }
        let selection = textView.selectedRange()
        if selection.location < 0 || NSMaxRange(selection) > storageLength {
            return "selection \(selection) outside 0…\(storageLength)"
        }
        return nil
    }

    /// The edited paragraph, plus one on each side.
    private func localRange() -> NSRange {
        let storage = controller.textStorage
        guard storage.length > 0 else { return NSRange(location: 0, length: 0) }
        let probe = max(0, min(controller.currentSelection.location, storage.length - 1))
        var range = storage.markdownParagraphRange(at: probe)
        if range.location > 0 {
            range = NSUnionRange(storage.markdownParagraphRange(at: range.location - 1), range)
        }
        if NSMaxRange(range) < storage.length {
            range = NSUnionRange(range, storage.markdownParagraphRange(at: NSMaxRange(range)))
        }
        return range
    }

    /// The storage vocabulary, paragraph by paragraph: a uniform block,
    /// one-character literals, source-backed atoms, separators only in
    /// table rows, no line breaks in code, and one text list per list
    /// container.
    private func checkVocabulary(in range: NSRange) -> String? {
        let storage = controller.textStorage
        guard storage.length > 0, range.length > 0 else { return nil }
        let ns = storage.string as NSString
        for paragraph in storage.markdownParagraphRanges(in: range) where paragraph.length > 0 {
            let context = "in paragraph \(paragraph) \(StorageDump.escape(ns.substring(with: paragraph)))"
            guard let block = storage.markdownBlock(at: paragraph.location) else {
                return "no markdownBlock at \(paragraph.location) \(context)"
            }
            var blockRange = NSRange()
            _ = storage.attribute(.markdownBlock, at: paragraph.location, longestEffectiveRange: &blockRange, in: paragraph)
            if blockRange != paragraph {
                return "markdownBlock is not uniform: \(blockRange) \(context)"
            }
            var literalProblem: String?
            storage.enumerateAttribute(.markdownLiteral, in: paragraph) { value, run, stop in
                guard value != nil else { return }
                var index = run.location
                while index < NSMaxRange(run) {
                    let character = ns.rangeOfComposedCharacterSequence(at: index)
                    let unit = ns.character(at: index)
                    if unit == MarkdownParagraph.separator {
                        literalProblem = "literal on a paragraph separator at \(index) \(context)"
                    } else if character.length > 2 {
                        literalProblem = "literal over \(character.length) units at \(index) \(context)"
                    }
                    if literalProblem != nil {
                        stop.pointee = true
                        return
                    }
                    index = NSMaxRange(character)
                }
            }
            if let literalProblem { return literalProblem }
            for index in paragraph.location..<NSMaxRange(paragraph) {
                let unit = ns.character(at: index)
                let isSeparatorAttribute = storage.attribute(.markdownTableSeparator, at: index, effectiveRange: nil) != nil
                if unit == MarkdownParagraph.objectReplacement, storage.proseSourceAttachment(at: index) == nil {
                    return "U+FFFC without a ProseSourceAttachment at \(index) \(context)"
                }
                if unit == MarkdownTableSeparator.utf16, block.isTableRow, !isSeparatorAttribute {
                    return "table tab without markdownTableSeparator at \(index) \(context)"
                }
                if isSeparatorAttribute, !(block.isTableRow && unit == MarkdownTableSeparator.utf16) {
                    return "markdownTableSeparator outside a table tab at \(index) \(context)"
                }
                if unit == MarkdownBreak.utf16, block.isCode {
                    return "U+2028 inside a code paragraph at \(index) \(context)"
                }
            }
            let lists = StorageDump.textLists(in: storage, at: paragraph.location)
            if lists.count != block.listDepth {
                return "\(lists.count) text list(s) for listDepth \(block.listDepth) \(context)"
            }
        }
        return nil
    }

    // MARK: - Tiered

    private struct Paragraph {
        var range: NSRange
        var block: MarkdownBlock
    }

    private func paragraphs() -> [Paragraph] {
        let storage = controller.textStorage
        guard storage.length > 0 else { return [] }
        return storage.markdownParagraphRanges().compactMap { range in
            guard range.length > 0, let block = storage.markdownBlock(at: range.location) else { return nil }
            return Paragraph(range: range, block: block)
        }
    }

    /// Code, table and quote groups are contiguous; a table's rows agree
    /// on column count and alignments, only the first is a header, and the
    /// row geometry, where stamped, counts the same rows.
    private func checkGroups() -> String? {
        let storage = controller.textStorage
        let ns = storage.string as NSString
        let all = paragraphs()
        var lastSeen: [String: Int] = [:]
        for (index, paragraph) in all.enumerated() {
            var tokens: [String] = []
            if let group = paragraph.block.codeGroup { tokens.append("code \(group)") }
            if let group = paragraph.block.tableGroup { tokens.append("table \(group)") }
            tokens += paragraph.block.quoteTokens.map { "quote \($0)" }
            for token in tokens {
                if let previous = lastSeen[token], previous != index - 1 {
                    return "\(token) resumes at paragraph \(index) after a gap from \(previous)"
                }
                lastSeen[token] = index
            }
        }
        var start = 0
        while start < all.count {
            guard let group = all[start].block.tableGroup else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < all.count, all[end + 1].block.tableGroup == group { end += 1 }
            let rows = Array(all[start...end])
            let first = rows[0]
            let separators = { (range: NSRange) in
                (range.location..<NSMaxRange(range)).filter { ns.character(at: $0) == MarkdownTableSeparator.utf16 }.count
            }
            let columns = separators(first.range)
            for (offset, row) in rows.enumerated() {
                let label = "table \(group) row \(offset) \(StorageDump.escape(ns.substring(with: row.range)))"
                if separators(row.range) != columns {
                    return "\(label) has \(separators(row.range) + 1) cells, the first row \(columns + 1)"
                }
                if row.block.tableAlignments != first.block.tableAlignments {
                    return "\(label) alignments \(row.block.tableAlignments) differ from the first row"
                }
                if row.block.isTableHeader != (offset == 0) {
                    return "\(label) isHeader \(row.block.isTableHeader)"
                }
                if let geometry = controller.harnessTableGeometry(at: row.range.location),
                   geometry.row != offset || geometry.rows != rows.count {
                    return "\(label) geometry says row \(geometry.row) of \(geometry.rows), storage \(offset) of \(rows.count)"
                }
            }
            start = end + 1
        }
        return nil
    }

    /// The writer-side tree is a pure function of storage, and writing it
    /// is what `markdown(from:)` does.
    private func checkReader() -> String? {
        let storage = controller.textStorage
        let reader = StorageReader()
        let once = reader.document(from: storage)
        let twice = reader.document(from: storage)
        if once != twice {
            return "StorageReader is not deterministic\n"
                + StorageDump.diff(StorageDump.describeTree(once), StorageDump.describeTree(twice))
        }
        let written = MarkdownWriter().write(once)
        let direct = MarkdownWriter().markdown(from: storage)
        if written != direct {
            return "write(document) differs from markdown(from: storage)\n" + StorageDump.diff(written, direct)
        }
        return nil
    }

    /// Writing and re-loading must be a fixpoint. `markdown()` returns the
    /// load bytes until the first edit, so the comparison goes through a
    /// fresh loader and writer.
    private func checkMarkdownFixpoint() -> String? {
        let markdown = controller.markdown()
        let again = Self.roundTrip(markdown)
        guard !Self.sameMarkdown(markdown, again) else { return nil }
        return "markdown is not a fixpoint\n" + StorageDump.diff(markdown, again)
    }

    static func roundTrip(_ markdown: String) -> String {
        MarkdownWriter().markdown(from: MarkdownLoader().load(markdown))
    }

    /// Equal up to what loading discards by design: one trailing newline,
    /// and spaces at the edges of a paragraph, which the writer keeps so
    /// the bound text matches what was typed.
    static func sameMarkdown(_ lhs: String, _ rhs: String) -> Bool {
        trimmingParagraphEdges(lhs) == trimmingParagraphEdges(rhs)
    }

    private static func trimmingParagraphEdges(_ markdown: String) -> [String] {
        var lines = EditDriver.trimOneTrailingNewline(markdown).components(separatedBy: "\n")
        func isBlank(_ index: Int) -> Bool {
            index < 0 || index >= lines.count || lines[index].allSatisfy { $0 == " " || $0 == "\t" || $0 == ">" }
        }
        let blanks = lines.indices.map(isBlank)
        for index in lines.indices where !blanks[index] {
            let endsParagraph = index + 1 >= lines.count || blanks[index + 1]
            if endsParagraph {
                while let last = lines[index].last, last == " " || last == "\t" { lines[index].removeLast() }
            }
            let startsParagraph = index == 0 || blanks[index - 1]
            let leading = lines[index].prefix { $0 == " " }.count
            if startsParagraph, leading > 0, leading < 4 { lines[index].removeFirst(leading) }
        }
        return lines.map { line in
            line.allSatisfy { $0 == " " || $0 == "\t" || $0 == ">" } ? line.filter { $0 == ">" } : line
        }
    }

    /// Undo to the bottom must restore the loaded document, and redoing
    /// everything must restore the storage it started from.
    private func checkHistory() -> String? {
        let manager = controller.activeUndoManagerForHarness
        controller.breakUndoCoalescingForHarness()
        let before = StorageDump.rows(controller.textStorage).joined(separator: "\n")
        var undone = 0
        while manager.canUndo, undone < 64 {
            manager.undo()
            controller.settleForHarness()
            undone += 1
        }
        var problem: String?
        if let baseline = baselineMarkdown, undone > 0, !manager.canUndo {
            let bottom = controller.markdown()
            let expected = EditDriver.trimOneTrailingNewline(baseline)
            if bottom != expected, bottom != baseline {
                problem = "undo to the bottom did not restore the loaded document\n"
                    + StorageDump.diff(expected, bottom)
            }
        }
        var redone = 0
        while manager.canRedo, redone < undone {
            manager.redo()
            controller.settleForHarness()
            redone += 1
        }
        if let problem { return problem }
        let after = StorageDump.rows(controller.textStorage).joined(separator: "\n")
        guard before != after else { return nil }
        return "undo \(undone) + redo \(redone) did not restore the document\n"
            + StorageDump.diff(before, after)
    }

    /// Laying the document out is the check: TextKit 2 traps rather than
    /// returning an error when a fragment's character range is impossible.
    private func checkLayout() -> String? {
        let layoutManager = controller.textLayoutManager
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: []) { _ in true }
        return nil
    }

    // MARK: - Latency

    var latencyReport: String {
        guard !opDurations.isEmpty else { return "no ops timed" }
        let sorted = opDurations.sorted()
        func pct(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let ms = { (v: Double) in String(format: "%.3f", v * 1000) }
        return "ops \(sorted.count)  p50 \(ms(pct(0.5)))ms  "
            + "p90 \(ms(pct(0.9)))ms  p99 \(ms(pct(0.99)))ms  max \(ms(sorted.last!))ms"
    }
}
#endif
