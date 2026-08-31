import XCTest
import AppKit
import ObjectiveC
@testable import SwiftProseDemo
@_spi(Harness) import SwiftProse

/// The harness testing itself: if these fail, every other hosted test is
/// asserting about a driver that isn't driving anything.
@MainActor
final class DriverCanaryTests: HarnessTestCase {

    func testTypingReachesStorageThroughAppKit() throws {
        reset(doc: "")
        try driver.perform(.type(text: "hello"))
        driver.settle()
        XCTAssertEqual(controller.textStorage.string, "hello")
        XCTAssertEqual(controller.markdown(), "hello")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testSynthesizedKeyEventsMoveTheCaret() throws {
        XCTAssertTrue(driver.synthesizedKeyEventsWork,
                      "synthesized keyDown did not move the caret — every keyDown-routed op "
                      + "would be a silent no-op")
    }

    func testHostTextViewIsThePackageClass() throws {
        // `type(of:)` on an implicitly-unwrapped optional reports the
        // static type; the dynamic class is what matters here.
        // `NSStringFromClass` is module-qualified for a Swift class.
        XCTAssertTrue(NSStringFromClass(object_getClass(textView)!).hasSuffix("ProseNSTextView"),
                      NSStringFromClass(object_getClass(textView)!))
        XCTAssertTrue(textView.responds(to: NSSelectorFromString("undo:")))
        XCTAssertTrue(textView.responds(to: NSSelectorFromString("redo:")))
    }

    func testEnterSplitsThroughTheDelegateRoute() throws {
        reset(doc: "one two")
        try driver.perform(.caret(Anchor(at: 3)))
        try driver.perform(.key("Enter"))
        driver.settle()
        XCTAssertEqual(controller.markdown(), "one\n\n two")
    }

    func testUndoGoesThroughTheMenuAction() throws {
        reset(doc: "")
        try driver.perform(.type(text: "abc"))
        driver.settle()
        XCTAssertEqual(controller.markdown(), "abc")
        try driver.perform(.undo(n: 1))
        driver.settle()
        XCTAssertEqual(controller.markdown(), "")
        try driver.perform(.redo(n: 1))
        driver.settle()
        XCTAssertEqual(controller.markdown(), "abc")
    }

    /// A burst goes in as one `insertText`, which the delegate's veto
    /// reroutes to the paste pipeline. That is a different code path from
    /// `type`, and the point of having both.
    func testTypeBurstIsNotTheSamePathAsType() throws {
        reset(doc: "")
        HarnessRegistry.shared.clearCollected()
        try driver.perform(.type(text: "ab"))
        driver.settle()
        let afterTyping = HarnessRegistry.shared.classCoverage
        XCTAssertEqual(afterTyping["typing"], 2, "per-character insert should classify as typing")

        HarnessRegistry.shared.clearCollected()
        try driver.perform(.typeBurst(text: "one two"))
        driver.settle()
        XCTAssertNil(HarnessRegistry.shared.classCoverage["typing"],
                     "a whitespace-bearing burst should not arrive as typing")
        XCTAssertEqual(controller.markdown(), "abone two")
    }

    func testAnchorsResolveAgainstTheLiveDocument() throws {
        reset(doc: "alpha beta gamma")
        try driver.perform(.caret(Anchor(after: "alpha")))
        XCTAssertEqual(textView.selectedRange().location, 5)
        try driver.perform(.caret(Anchor(before: "gamma")))
        XCTAssertEqual(textView.selectedRange().location, 11)
        try driver.perform(.select(from: Anchor(before: "beta"), to: Anchor(after: "beta")))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 4))
    }

    func testPasteRoutesThroughTheClipboardPipeline() throws {
        reset(doc: "")
        let saved = EditDriver.snapshotGeneralPasteboard()
        defer { EditDriver.restoreGeneralPasteboard(saved) }
        try driver.perform(.paste(text: "one\n\ntwo", html: nil, plain: true))
        driver.settle()
        XCTAssertEqual(controller.markdown(), "one\n\ntwo")
    }

    /// Compositions must not reach the document until they commit.
    func testCompositionInterimsAreNotContent() throws {
        reset(doc: "")
        try driver.perform(.compose(interims: ["k", "ka"], commit: nil))
        driver.settle()
        XCTAssertEqual(controller.markdown(), "", "a cancelled composition left content behind")
        try driver.perform(.compose(interims: ["n", "ni"], commit: "日本"))
        driver.settle()
        XCTAssertEqual(controller.markdown(), "日本")
    }

    func testMarkerMappingSurvivesPresentationPrefixes() throws {
        let runner = ScenarioRunner(controller: controller, textView: textView)
        // "1. " is a presentation prefix: the marker's source offset and
        // its storage offset differ by exactly its width.
        let selection = try runner.load(markedSource: "1. it<|>em\n",
                                        markers: Scenario.defaultMarkers)
        XCTAssertEqual(controller.markdown(), "1. item")
        let string = controller.textStorage.string as NSString
        XCTAssertEqual(string.substring(with: NSRange(location: selection.location, length: 2)), "em")
    }

    func testMarkerMappingRejectsAMarkerThatChangesParsing() throws {
        let runner = ScenarioRunner(controller: controller, textView: textView)
        // A caret between the two dashes of a setext-ish rule changes how
        // the line parses; the runner has to say so rather than hand back
        // a meaningless offset.
        XCTAssertThrowsError(try runner.load(markedSource: "-<|>--\n",
                                             markers: Scenario.defaultMarkers))
    }

    /// `currentSelection` prefers the internal `testSelection` seam over
    /// the host text view. Writing that seam while a host is attached pins
    /// the selection permanently — every later command then reads a stale
    /// range, which is how a whole category of scenarios silently stopped
    /// applying marks.
    func testSelectionFollowsTheTextViewAfterAnUndo() throws {
        reset(doc: "alpha beta")
        try driver.perform(.caret(Anchor(at: 10)))
        try driver.perform(.type(text: "!"))
        driver.settle()
        try driver.perform(.undo(n: 1))
        driver.settle()

        textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(controller.currentSelection, NSRange(location: 0, length: 5),
                       "currentSelection stopped tracking the text view after an undo")
        _ = controller.perform(.bold)
        driver.settle()
        XCTAssertEqual(controller.markdown(), "**alpha** beta")
    }

    /// Every corpus document, loaded and checked against every oracle.
    ///
    /// Real-world markdown does not yet come through the editor losslessly,
    /// and the documents that fail are recorded in a checked-in ledger
    /// rather than hidden behind a disabled oracle. The test fails when the
    /// ledger is wrong in *either* direction: a document that used to pass
    /// an oracle stopped, or one that is listed now passes and should come
    /// off. Each distinct finding is also pinned by a minimal xfail
    /// scenario under `Fixtures/scenarios/regressions/`.
    ///
    /// Regenerate with `TEST_RUNNER_SWIFTPROSE_UPDATE_LEDGER=1`; the ledger
    /// is written to the source tree, not to the copy in the app bundle.
    private static let corpusOracles = [
        "diagnostics", "length", "coverage", "specFull", "schema",
        "projection", "offsets", "markdownFixpoint", "pmJSON"
    ]

    func testCorpusLedgerIsAccurate() throws {
        var observed: [String: [String]] = [:]
        var detail: [String] = []
        for entry in Fixtures.corpus() {
            reset(doc: entry.markdown)
            let oracles = Oracles(controller: controller, textView: textView, cadence: .everyOp)
            oracles.collectAll = true
            let failures = try oracles.run(Self.corpusOracles, at: -1)
            guard !failures.isEmpty else { continue }
            observed[entry.name] = Array(Set(failures.map(\.oracle))).sorted()
            for failure in failures {
                detail.append("\(entry.name): \(failure.description)")
            }
        }
        attach(detail.joined(separator: "\n\n"), name: "corpus-failures.txt")

        let ledgerURL = Fixtures.corpusRoot?.appendingPathComponent("corpus-ledger.json")
        if HarnessLaunch.env("SWIFTPROSE_UPDATE_LEDGER") != nil {
            guard let source = Fixtures.sourceRoot?
                .appendingPathComponent("corpus/corpus-ledger.json") else {
                XCTFail("no source Fixtures tree to write the ledger into")
                return
            }
            let data = try JSONSerialization.data(
                withJSONObject: observed, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: source)
            try? detail.joined(separator: "\n\n").write(
                to: source.deletingLastPathComponent().appendingPathComponent("corpus-ledger.txt"),
                atomically: true, encoding: .utf8
            )
            print("harness: wrote \(source.path) with \(observed.count) entries")
            return
        }

        guard let ledgerURL,
              let data = try? Data(contentsOf: ledgerURL),
              let ledger = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String]]
        else {
            throw XCTSkip("no corpus-ledger.json — run with SWIFTPROSE_UPDATE_LEDGER=1")
        }

        var problems: [String] = []
        for (name, oracles) in observed.sorted(by: { $0.key < $1.key }) {
            let newlyFailing = Set(oracles).subtracting(ledger[name] ?? [])
            if !newlyFailing.isEmpty {
                problems.append("\(name) newly fails \(newlyFailing.sorted().joined(separator: ", "))")
            }
        }
        for (name, oracles) in ledger.sorted(by: { $0.key < $1.key }) {
            let fixed = Set(oracles).subtracting(Set(observed[name] ?? []))
            if !fixed.isEmpty {
                problems.append("\(name) now passes \(fixed.sorted().joined(separator: ", "))"
                                + " — take it off the ledger")
            }
        }
        if !problems.isEmpty {
            XCTFail("corpus ledger is out of date:\n" + problems.joined(separator: "\n")
                    + "\n\nSee the attached corpus-failures.txt, then regenerate with "
                    + "TEST_RUNNER_SWIFTPROSE_UPDATE_LEDGER=1.")
        }
    }
}
