#if os(macOS)
import AppKit
import Foundation
@_spi(Harness) import SwiftProse

/// Runs one `Scenario` against a live editor.
///
/// The interesting part is the marker mapping. `<|>` sits in *source*
/// markdown; loading that source removes delimiters and list markers,
/// renders escapes, collapses atoms to U+FFFC and tab-joins table cells.
/// So the marker's source offset is not the storage offset. Recovering the
/// real one is a sentinel load: swap the markers for private-use scalars,
/// load, read where they landed, then load the clean source and assert the
/// two strings agree.
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

    /// Private-use scalars: never produced by the loader, never
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

        guard !parsed.clean.isEmpty, parsed.caret != nil || parsed.hasSelection else {
            install(parsed.clean)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            return NSRange(location: 0, length: 0)
        }

        // 1. Compile the source with sentinels in the markers' places.
        let sentinelSource = Self.substituteSentinels(markedSource, markers: markers)
        controller.setMarkdown(sentinelSource)
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
                "marker did not survive the load in \(EditOp.quote(markedSource)) — "
                + "place it inside content, or use `caret block/edge`"
            )
        }
        let stripped = Self.stripSentinels(withSentinels as String)

        // 3. Compile the clean source and check the two agree. If they
        //    don't, the marker changed how the document parsed and the
        //    offsets it produced are meaningless.
        install(parsed.clean)
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

    private func install(_ markdown: String) {
        controller.setMarkdown(markdown)
        controller.activeUndoManagerForHarness.removeAllActions()
        controller.breakUndoCoalescingForHarness()
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

        let driver = EditDriver(controller: controller, textView: textView)
        driver.clearInputState()
        let oracles = Oracles(controller: controller, textView: textView, cadence: .everyOp)
        oracles.collectAll = true

        do {
            try load(markedSource: scenario.doc, markers: markers)
            oracles.baselineMarkdown = controller.markdown()
            driver.settle()

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
        recorded.expect = Expectation(doc: EditDriver.trimOneTrailingNewline(controller.markdown()))
        return recorded
    }

    /// Every scenario's expected document must itself be a fixpoint —
    /// writing what loading it produces gives it back — or the expectation
    /// encodes a writer bug rather than the behavior under test.
    func expectedDocIsFixpoint(_ scenario: Scenario) -> String? {
        guard scenario.crashes == nil else { return nil }
        guard let doc = scenario.expect?.doc else { return nil }
        guard let parsed = try? MarkedText.parse(doc, markers: scenario.effectiveMarkers) else {
            return "expect.doc has unbalanced markers"
        }
        let expected = EditDriver.trimOneTrailingNewline(parsed.clean)
        let again = Oracles.roundTrip(expected)
        guard !Oracles.sameMarkdown(again, expected) else { return nil }
        return "expect.doc is not a fixpoint:\n" + StorageDump.diff(expected, again)
    }
}
#endif
