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
        // Numbers and quoted strings vary with the document; the shape of
        // the complaint does not.
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
        var coverage = 10
        var schema = 25
        var projection = 25
        var specFull = 50
        var offsets = 100
        var markdownFixpoint = 250
        var pmJSON = 250
        var history = 500
        var layout = 500

        /// Everything on every op — what a scenario over a tiny document
        /// wants.
        static let everyOp = Cadence(
            coverage: 1, schema: 1, projection: 1, specFull: 1, offsets: 1,
            markdownFixpoint: 0, pmJSON: 0, history: 0, layout: 0
        )

        /// Scaled for an ~85 KB document, where a full projection is the
        /// dominant cost.
        static func scaled(forLength length: Int) -> Cadence {
            guard length > 4_000 else { return Cadence() }
            let factor = max(1, length / 4_000)
            var c = Cadence()
            c.coverage *= factor
            c.schema *= factor
            c.projection *= factor
            c.specFull *= factor
            c.offsets *= factor
            return c
        }
    }

    let controller: EditorController
    let textView: NSTextView
    var cadence: Cadence
    /// Oracles disabled for this run (a scenario that deliberately makes
    /// one of them fail turns it off by id).
    var disabled: Set<String> = []
    /// Every failure seen, so one fuzz run reports many.
    private(set) var failures: [OracleFailure] = []
    /// Collected by an `addOnDiagnostic` subscription.
    private var diagnostics: [SpecDiagnostic] = []
    private var diagnosticToken: EditorController.ObserverToken?
    /// The last `load`ed markdown — the `history` oracle undoes back to it.
    var baselineMarkdown: String?
    /// Per-op durations in seconds, for the `latency` report.
    private(set) var opDurations: [Double] = []

    static let allIDs = [
        "diagnostics", "length", "specLocal", "coverage", "schema",
        "projection", "specFull", "offsets", "markdownFixpoint", "pmJSON",
        "history", "layout", "latency"
    ]

    /// The always-on set: cheap enough for every op on any document.
    static let tier0 = ["diagnostics", "length", "specLocal"]

    init(controller: EditorController, textView: NSTextView, cadence: Cadence = Cadence()) {
        self.controller = controller
        self.textView = textView
        self.cadence = cadence
        diagnosticToken = controller.addOnDiagnostic { [weak self] diagnostic in
            self?.diagnostics.append(diagnostic)
        }
    }

    deinit {
        // Observer tokens are cheap and the controller outlives us; drop
        // the subscription so a finished run stops collecting.
        if let diagnosticToken {
            MainActor.assumeIsolated { controller.removeObserver(diagnosticToken) }
        }
    }

    /// Record a failure the driver produced rather than an oracle — a
    /// thrown driver error is still something the run has to report.
    func note(_ failure: OracleFailure) { failures.append(failure) }

    func reset() {
        failures.removeAll()
        diagnostics.removeAll()
        opDurations.removeAll()
    }

    func record(duration: Double) { opDurations.append(duration) }

    // MARK: - Dispatch

    /// Run tier 0 every op, plus whichever tiered oracles this index is due
    /// for. Throws on the first failure when `collectAll` is false.
    var collectAll = false

    func checkCadenced(at index: Int, op: EditOp) throws {
        var ids = Self.tier0
        if case .check(let requested) = op { ids += requested }
        func due(_ every: Int) -> Bool { every > 0 && (index + 1) % every == 0 }
        if due(cadence.coverage) { ids.append("coverage") }
        if due(cadence.schema) { ids.append("schema") }
        if due(cadence.projection) { ids.append("projection") }
        if due(cadence.specFull) { ids.append("specFull") }
        if due(cadence.offsets) { ids.append("offsets") }
        if due(cadence.markdownFixpoint) { ids.append("markdownFixpoint") }
        if due(cadence.pmJSON) { ids.append("pmJSON") }
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

    func check(_ id: String, at index: Int) -> [OracleFailure] {
        HarnessLaunch.trace("oracle \(id) @\(index)")
        func fail(_ detail: String) -> [OracleFailure] {
            [OracleFailure(oracle: id, detail: detail, opIndex: index)]
        }
        switch id {
        case "diagnostics": return checkDiagnostics(index)
        case "length": return checkLength(index)
        case "specLocal": return checkSpec(range: localRange(), index: index, id: id)
        case "coverage": return checkCoverage(index)
        case "schema": return checkSchema(index)
        case "projection": return checkProjection(index)
        case "specFull":
            return checkSpec(range: NSRange(location: 0, length: controller.textStorage.length),
                             index: index, id: id)
        case "offsets": return checkOffsets(index, sampled: true)
        case "offsetsFull": return checkOffsets(index, sampled: false)
        case "markdownFixpoint": return checkMarkdownFixpoint(index)
        case "pmJSON": return checkProseMirrorJSON(index)
        case "history": return checkHistory(index)
        case "layout": return checkLayout(index)
        case "latency": return []
        default: return fail("unknown oracle id")
        }
    }

    // MARK: - Tier 0

    private func checkDiagnostics(_ index: Int) -> [OracleFailure] {
        guard !diagnostics.isEmpty else { return [] }
        let collected = diagnostics
        diagnostics.removeAll()
        // One line per distinct issue shape; a missing spec on a 10-char
        // line reports 10 identical diagnostics otherwise.
        var shapes: [String] = []
        for d in collected {
            let shape = shapeOf(d.issue)
            if !shapes.contains(shape) { shapes.append(shape) }
        }
        return [OracleFailure(
            oracle: "diagnostics",
            detail: "\(collected.count) spec diagnostic(s): \(shapes.joined(separator: ", "))",
            opIndex: index
        )]
    }

    private func shapeOf(_ issue: SpecDiagnostic.Issue) -> String {
        switch issue {
        case .missingSpec: return "missingSpec"
        case .inconsistentSpec(_, let found):
            return "inconsistentSpec(\(found.map { StorageDump.describe($0) }.joined(separator: " vs ")))"
        case .markerWithoutListItem: return "markerWithoutListItem"
        case .listItemWithoutMarker: return "listItemWithoutMarker"
        }
    }

    private func checkLength(_ index: Int) -> [OracleFailure] {
        var out: [OracleFailure] = []
        let storageLength = controller.textStorage.length
        let viewLength = (textView.string as NSString).length
        if viewLength != storageLength {
            out.append(OracleFailure(
                oracle: "length",
                detail: "text view string \(viewLength) != storage \(storageLength)",
                opIndex: index
            ))
        }
        let documentLength = controller.document.contentLength
        if documentLength != storageLength {
            out.append(OracleFailure(
                oracle: "length",
                detail: "document.contentLength \(documentLength) != storage \(storageLength)",
                opIndex: index
            ))
        }
        let selection = textView.selectedRange()
        if selection.location < 0 || selection.location + selection.length > storageLength {
            out.append(OracleFailure(
                oracle: "length",
                detail: "selection \(selection) outside 0…\(storageLength)",
                opIndex: index
            ))
        }
        return out
    }

    /// The edited paragraph, plus one on each side — an edit at a boundary
    /// can merge or split blocks.
    private func localRange() -> NSRange {
        let storage = controller.textStorage
        guard storage.length > 0 else { return NSRange(location: 0, length: 0) }
        let string = storage.string as NSString
        let selection = controller.currentSelection
        let probe = max(0, min(selection.location, string.length - 1))
        var range = string.paragraphRange(for: NSRange(location: probe, length: 0))
        if range.location > 0 {
            let prev = string.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            range = NSUnionRange(prev, range)
        }
        let end = range.location + range.length
        if end < string.length {
            let next = string.paragraphRange(for: NSRange(location: end, length: 0))
            range = NSUnionRange(range, next)
        }
        return range
    }

    private func checkSpec(range: NSRange, index: Int, id: String) -> [OracleFailure] {
        guard range.length > 0 else { return [] }
        let found = SpecValidator.validate(in: controller.textStorage, range: range)
        guard !found.isEmpty else { return [] }
        var shapes: [String] = []
        for d in found where !shapes.contains(shapeOf(d.issue)) { shapes.append(shapeOf(d.issue)) }
        let first = found[0]
        return [OracleFailure(
            oracle: id,
            detail: "\(found.count) violation(s) \(shapes.joined(separator: ", ")) "
                + "in line \(first.lineRange): "
                + StorageDump.escape((controller.textStorage.string as NSString).substring(with: first.lineRange)),
            opIndex: index
        )]
    }

    // MARK: - Tiered

    /// Every attribute run must carry both canonical attributes. Table
    /// lines are exempt, as they are for `SpecValidator`.
    private func checkCoverage(_ index: Int) -> [OracleFailure] {
        let storage = controller.textStorage
        guard storage.length > 0 else { return [] }
        let full = NSRange(location: 0, length: storage.length)
        var gaps: [NSRange] = []
        var cursor = 0
        storage.enumerateAttribute(.proseNodePath, in: full, options: []) { value, range, _ in
            if value == nil || range.location > cursor {
                let gap = NSRange(location: cursor, length: max(0, range.location - cursor))
                if gap.length > 0 { gaps.append(gap) }
            }
            if value != nil { cursor = range.location + range.length }
        }
        if cursor < storage.length {
            gaps.append(NSRange(location: cursor, length: storage.length - cursor))
        }
        guard let first = gaps.first else { return [] }
        return [OracleFailure(
            oracle: "coverage",
            detail: "\(gaps.count) run(s) without proseNodePath, first \(first): "
                + StorageDump.escape((storage.string as NSString).substring(with: first)),
            opIndex: index
        )]
    }

    /// Never installed as `onSchemaDiagnostic` — that projects the whole
    /// document on every transaction. Run against the tree we already have.
    private func checkSchema(_ index: Int) -> [OracleFailure] {
        let found = SchemaValidator.validate(controller.document)
        guard !found.isEmpty else { return [] }
        return [OracleFailure(
            oracle: "schema",
            detail: "\(found.count) schema diagnostic(s): "
                + found.prefix(3).map { String(describing: $0) }.joined(separator: "; "),
            opIndex: index
        )]
    }

    /// The spliced tree must describe the same document a fresh projection
    /// would. Node ids are excluded — a splice keeps the doc root's id
    /// while a full projection mints a new one.
    private func checkProjection(_ index: Int) -> [OracleFailure] {
        let spliced = StorageDump.describeChildren(controller.document)
        let fresh = StorageDump.describeChildren(
            ProseDocument.from(storage: controller.textStorage, schema: .defaultMarkdown)
        )
        guard spliced != fresh else { return [] }
        return [OracleFailure(
            oracle: "projection",
            detail: "spliced tree differs from a full projection\n"
                + StorageDump.diff(fresh, spliced),
            opIndex: index
        )]
    }

    /// Every block boundary resolves, plus a sample of interior offsets.
    private func checkOffsets(_ index: Int, sampled: Bool) -> [OracleFailure] {
        let document = controller.document
        let length = controller.textStorage.length
        guard length > 0 else { return [] }
        var probes: [Int] = [0, length]
        let string = controller.textStorage.string as NSString
        var i = 0
        while i < length {
            let line = string.lineRange(for: NSRange(location: i, length: 0))
            probes.append(line.location)
            probes.append(line.location + line.length)
            i = line.location + max(1, line.length)
        }
        if sampled {
            let step = max(1, length / 256)
            probes += stride(from: 0, through: length, by: step).map { $0 }
        } else {
            probes += Array(0...length)
        }
        for pos in Set(probes).sorted() where pos >= 0 && pos <= length {
            guard let resolved = document.resolve(pos) else {
                return [OracleFailure(
                    oracle: "offsets", detail: "resolve(\(pos)) returned nil (length \(length))",
                    opIndex: index
                )]
            }
            if resolved.pos != pos {
                return [OracleFailure(
                    oracle: "offsets",
                    detail: "resolve(\(pos)).pos == \(resolved.pos)",
                    opIndex: index
                )]
            }
        }
        return []
    }

    /// Serializing and re-parsing must be a fixpoint. A miss is an
    /// escaping or round-trip bug, so it is strict and reported under its
    /// own id.
    private func checkMarkdownFixpoint(_ index: Int) -> [OracleFailure] {
        let markdown = controller.markdown()
        guard let fresh = try? EditorController(initialMarkdown: markdown) else {
            return [OracleFailure(oracle: "markdownFixpoint",
                                  detail: "could not build a comparison controller",
                                  opIndex: index)]
        }
        let again = fresh.markdown()
        guard again != markdown else { return [] }
        return [OracleFailure(
            oracle: "markdownFixpoint",
            detail: "markdown is not a fixpoint\n" + StorageDump.diff(markdown, again),
            opIndex: index
        )]
    }

    /// Export → load into a separate headless controller → export. The
    /// encoder is a bare `JSONEncoder`, so key order is not stable;
    /// compare re-serialized with sorted keys.
    private func checkProseMirrorJSON(_ index: Int) -> [OracleFailure] {
        do {
            let exported = try controller.exportProseMirrorJSON()
            let mirror = try EditorController()
            try mirror.loadProseMirrorJSON(exported)
            let again = try mirror.exportProseMirrorJSON()
            let a = try Self.canonicalJSON(exported)
            let b = try Self.canonicalJSON(again)
            guard a != b else { return [] }
            return [OracleFailure(
                oracle: "pmJSON",
                detail: "PM JSON is not a round-trip fixpoint\n" + StorageDump.diff(a, b),
                opIndex: index
            )]
        } catch {
            return [OracleFailure(oracle: "pmJSON", detail: "\(error)", opIndex: index)]
        }
    }

    static func canonicalJSON(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let normalized = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted]
        )
        return String(decoding: normalized, as: UTF8.self)
    }

    /// Undo N then redo N must restore the string, the per-line block
    /// specs and the per-run marks. Node ids re-mint on undo, so they are
    /// deliberately not compared.
    private func checkHistory(_ index: Int) -> [OracleFailure] {
        let before = snapshotForHistory()
        var undone = 0
        while controller.undoManager.canUndo, undone < 64 {
            controller.undoManager.undo()
            undone += 1
        }
        if let baseline = baselineMarkdown, undone > 0 {
            let bottom = controller.markdown()
            if bottom != EditDriver.trimOneTrailingNewline(baseline) {
                // Redo back up before reporting so the run can continue.
                for _ in 0..<undone where controller.undoManager.canRedo {
                    controller.undoManager.redo()
                }
                return [OracleFailure(
                    oracle: "history",
                    detail: "undo to the bottom did not restore the loaded document\n"
                        + StorageDump.diff(EditDriver.trimOneTrailingNewline(baseline), bottom),
                    opIndex: index
                )]
            }
        }
        for _ in 0..<undone where controller.undoManager.canRedo {
            controller.undoManager.redo()
        }
        let after = snapshotForHistory()
        guard before != after else { return [] }
        return [OracleFailure(
            oracle: "history",
            detail: "undo \(undone) + redo \(undone) did not restore the document\n"
                + StorageDump.diff(before, after),
            opIndex: index
        )]
    }

    /// String + per-line block spec + per-run marks. Ids excluded.
    private func snapshotForHistory() -> String {
        let storage = controller.textStorage
        var lines: [String] = [storage.string]
        let string = storage.string as NSString
        var i = 0
        while i < string.length {
            let line = string.lineRange(for: NSRange(location: i, length: 0))
            let spec = storage.blockSpec(at: line.location).map { StorageDump.describe($0) } ?? "-"
            lines.append("\(line.location): \(spec)")
            i = line.location + max(1, line.length)
        }
        storage.enumerateAttribute(
            .proseMarks, in: NSRange(location: 0, length: storage.length), options: []
        ) { value, range, _ in
            let names = (value as? MarkSetBox)?.marks.marks.map(\.type).sorted() ?? []
            if !names.isEmpty { lines.append("\(range): \(names.joined(separator: "+"))") }
        }
        return lines.joined(separator: "\n")
    }

    /// Laying the document out is the check: TextKit 2 traps rather than
    /// returning an error when a fragment's character range is impossible.
    private func checkLayout(_ index: Int) -> [OracleFailure] {
        let layoutManager = controller.layoutManager
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var laidOut = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location, options: []
        ) { fragment in
            for line in fragment.textLineFragments where line.typographicBounds.width > 0 {
                laidOut += line.characterRange.length
            }
            return true
        }
        return []
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
