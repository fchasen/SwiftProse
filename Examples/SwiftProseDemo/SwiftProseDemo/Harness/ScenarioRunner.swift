#if os(macOS)
import AppKit
import Foundation
@_spi(Harness) import SwiftProse

/// Runs one `Scenario` against a live editor.
///
/// The interesting part is the marker mapping. `<|>` sits in *source*
/// markdown; compiling that source moves everything after it by however
/// many characters the presentation markers add (`"1. "`, a bullet glyph
/// plus tab, a checkbox). So the marker's source offset is not the storage
/// offset. Recovering the real one is a sentinel compile: swap the markers
/// for private-use scalars, compile, read where they landed, then compile
/// the clean source and assert the two strings agree.
@MainActor
struct ScenarioRunner {

    struct Result {
        var scenario: Scenario
        var failures: [OracleFailure]
        var expectationFailure: String?
        var opLog: [EditOp]
        var storageDump: String
        var finalMarkdown: String

        var passed: Bool { failures.isEmpty && expectationFailure == nil }
    }

    enum Failure: Error, CustomStringConvertible {
        case markerMovedParsing(String)
        case driver(String)

        var description: String {
            switch self {
            case .markerMovedParsing(let m): return m
            case .driver(let m): return m
            }
        }
    }

    /// Private-use scalars: never produced by the compiler, never
    /// meaningful to the markdown grammar.
    private static let caretSentinel = "\u{F8FF}"
    private static let selectionStartSentinel = "\u{F8FE}"
    private static let selectionEndSentinel = "\u{F8FD}"

    let controller: EditorController
    let textView: NSTextView

    // MARK: - Loading

    /// Install `source` (marker-bearing markdown) and return the storage
    /// selection its markers describe.
    @discardableResult
    func load(markedSource: String, markers: Scenario.Markers) throws -> NSRange {
        let parsed = try MarkedText.parse(markedSource, markers: markers)

        // An empty document has no content to place a marker inside: the
        // sentinel would be the only character, and `ensureTrailingParagraph`
        // gives a one-character document a trailing newline an empty one
        // doesn't have. The only selection it can describe is (0, 0).
        guard !parsed.clean.isEmpty else {
            controller.setMarkdown(parsed.clean, async: false)
            controller.undoManager.removeAllActions()
            controller.closeHistoryGroup()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            return NSRange(location: 0, length: 0)
        }

        guard parsed.caret != nil || parsed.hasSelection else {
            controller.setMarkdown(parsed.clean, async: false)
            controller.undoManager.removeAllActions()
            controller.closeHistoryGroup()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            return NSRange(location: 0, length: 0)
        }

        // 1. Compile the source with sentinels in the markers' places.
        let sentinelSource = Self.substituteSentinels(markedSource, markers: markers)
        controller.setMarkdown(sentinelSource, async: false)
        let withSentinels = controller.textStorage.string as NSString
        let caretAt = withSentinels.range(of: Self.caretSentinel)
        let startAt = withSentinels.range(of: Self.selectionStartSentinel)
        let endAt = withSentinels.range(of: Self.selectionEndSentinel)

        // 2. Where the sentinels landed, minus the sentinels before them.
        var selection: NSRange
        if caretAt.location != NSNotFound {
            selection = NSRange(location: caretAt.location, length: 0)
        } else if startAt.location != NSNotFound, endAt.location != NSNotFound {
            let start = startAt.location
            let end = endAt.location - startAt.length
            selection = NSRange(location: start, length: max(0, end - start))
        } else {
            throw Failure.markerMovedParsing(
                "marker did not survive the compile in \(EditOp.quote(markedSource)) — "
                + "place it inside content, or use `caret block/edge`"
            )
        }
        let stripped = Self.stripSentinels(withSentinels as String)

        // 3. Compile the clean source and check the two agree. If they
        //    don't, the marker changed how the document parsed and the
        //    offsets it produced are meaningless.
        controller.setMarkdown(parsed.clean, async: false)
        controller.undoManager.removeAllActions()
        controller.closeHistoryGroup()
        let clean = controller.textStorage.string
        guard clean == stripped else {
            throw Failure.markerMovedParsing("""
            marker changed parsing in \(EditOp.quote(markedSource)) — \
            place it inside content, or use `caret block/edge`
            \(StorageDump.diff(clean, stripped))
            """)
        }
        let clamped = NSRange(
            location: min(selection.location, (clean as NSString).length),
            length: min(selection.length, max(0, (clean as NSString).length - selection.location))
        )
        textView.setSelectedRange(clamped)
        return clamped
    }

    static func substituteSentinels(_ source: String, markers: Scenario.Markers) -> String {
        source
            .replacingOccurrences(of: markers.selectionStart, with: selectionStartSentinel)
            .replacingOccurrences(of: markers.selectionEnd, with: selectionEndSentinel)
            .replacingOccurrences(of: markers.caret, with: caretSentinel)
    }

    static func stripSentinels(_ text: String) -> String {
        text
            .replacingOccurrences(of: caretSentinel, with: "")
            .replacingOccurrences(of: selectionStartSentinel, with: "")
            .replacingOccurrences(of: selectionEndSentinel, with: "")
    }

    // MARK: - Running

    func run(_ scenario: Scenario) -> Result {
        let markers = scenario.effectiveMarkers
        var failures: [OracleFailure] = []
        var expectationFailure: String?

        // Deterministic history: with the delay effectively infinite,
        // grouping depends only on explicit `closeHistoryGroup` ops and on
        // whether an edit abuts a range the open burst already touched.
        controller.historyConfig = HistoryConfig(
            depth: scenario.config?.depth,
            newGroupDelay: scenario.config?.newGroupDelay ?? 1e9
        )
        controller.harnessAssertsOnDiagnostics = scenario.config?.assertsOnDiagnostics ?? true
        controller.useStructuredBulkInsert = scenario.config?.useStructuredBulkInsert ?? true

        let driver = EditDriver(controller: controller, textView: textView)
        driver.clearInputState()
        let oracles = Oracles(controller: controller, textView: textView, cadence: .everyOp)
        oracles.collectAll = true

        do {
            try load(markedSource: scenario.doc, markers: markers)
            oracles.baselineMarkdown = controller.markdown()
            driver.settle()
            // Loading is not the scenario; only what the ops do is.
            _ = oracles.check("diagnostics", at: -1)

            for (index, op) in scenario.ops.enumerated() {
                try driver.perform(op, at: index)
                driver.settle()
                if case .check(let ids) = op {
                    failures += try oracles.run(Oracles.expand(ids), at: index)
                } else {
                    failures += try oracles.run(Oracles.tier0, at: index)
                }
            }

            if let expectation = scenario.expect {
                try driver.check(expectation)
            }
            if !scenario.finally.isEmpty {
                failures += try oracles.run(Oracles.expand(scenario.finally), at: scenario.ops.count)
            }
        } catch let failure as EditDriver.Failure {
            if case .oracle(let oracleFailure) = failure {
                failures.append(oracleFailure)
            } else {
                expectationFailure = failure.description
            }
        } catch {
            expectationFailure = "\(error)"
        }

        return Result(
            scenario: scenario,
            failures: failures,
            expectationFailure: expectationFailure,
            opLog: scenario.ops,
            storageDump: StorageDump.dump(controller.textStorage),
            finalMarkdown: controller.markdown()
        )
    }

    /// Re-derive `expect.doc` from what the scenario actually produces —
    /// how the generated catalogue's expectations get filled in and
    /// reviewed rather than guessed.
    func record(_ scenario: Scenario) -> Scenario {
        var recorded = scenario
        _ = run(scenario)
        let markdown = controller.markdown()
        let selection = textView.selectedRange()
        recorded.expect = Expectation(
            doc: MarkedText.render(markdown, selection: selection, markers: scenario.effectiveMarkers)
        )
        return recorded
    }

    /// Every scenario's expected document must itself be a fixpoint —
    /// `roundTrip(expected) == expected` — or the expectation encodes a
    /// serializer bug rather than the behavior under test.
    func expectedDocIsFixpoint(_ scenario: Scenario) -> String? {
        guard scenario.crashes == nil else { return nil }
        guard let doc = scenario.expect?.doc else { return nil }
        guard let parsed = try? MarkedText.parse(doc, markers: scenario.effectiveMarkers) else {
            return "expect.doc has unbalanced markers"
        }
        let expected = EditDriver.trimOneTrailingNewline(parsed.clean)
        guard let fresh = try? EditorController(initialMarkdown: expected) else {
            return "could not compile expect.doc"
        }
        let again = fresh.markdown()
        guard again != expected else { return nil }
        return "expect.doc is not a fixpoint:\n" + StorageDump.diff(expected, again)
    }
}
#endif
