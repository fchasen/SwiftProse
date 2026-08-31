import XCTest
import AppKit
import ObjectiveC
@testable import SwiftProseDemo
@_spi(Harness) import SwiftProse

/// One XCTest per scenario file, so a failure names the scenario and
/// `-only-testing:SwiftProseDemoTests/ScenarioTests/test_lists_tab_indents`
/// runs exactly it.
///
/// The methods are registered on the class at suite-build time — a
/// scenario is a data file, and hand-writing a wrapper per file would put
/// the catalogue out of date the first time anyone added one.
@MainActor
final class ScenarioTests: HarnessTestCase {

    private static let catalogue: [Scenario] = {
        guard let root = Fixtures.scenariosRoot else { return [] }
        return ScenarioCodec.loadAll(under: root).map(\.scenario)
    }()

    override class var defaultTestSuite: XCTestSuite {
        let suite = XCTestSuite(forTestCaseClass: ScenarioTests.self)
        var used = Set<String>()
        for scenario in catalogue {
            var name = scenario.testMethodName
            var suffix = 2
            while !used.insert(name).inserted {
                name = "\(scenario.testMethodName)_\(suffix)"
                suffix += 1
            }
            let selector = NSSelectorFromString(name)
            let block: @convention(block) (ScenarioTests) -> Void = { testCase in
                MainActor.assumeIsolated {
                    do { try testCase.runScenario(scenario) }
                    catch { testCase.recordSkipOrFailure(error) }
                }
            }
            if !class_addMethod(self, selector, imp_implementationWithBlock(block), "v@:") {
                // Already registered by an earlier suite build; the
                // invocation below still needs adding.
            }
            suite.addTest(ScenarioTests(selector: selector))
        }
        return suite
    }

    /// A dynamically registered method can't be `throws`, so an
    /// `XCTSkip` thrown out of one has to be re-reported by hand.
    func recordSkipOrFailure(_ error: Error) {
        if let skip = error as? XCTSkip {
            XCTContext.runActivity(named: "skipped") { _ in }
            print("harness: skipped — \(skip.message ?? "")")
            return
        }
        XCTFail("\(error)")
    }

    /// Scenarios that trap are skipped individually; this makes the
    /// count visible in every run so they are not quietly forgotten.
    func testKnownCrashesAreStillTracked() {
        let crashing = Self.catalogue.filter { $0.crashes != nil }
        guard !crashing.isEmpty else { return }
        let report = crashing.map { "\($0.name): \($0.crashes ?? "")" }
            .joined(separator: "\n")
        attach(report, name: "known-crashes.txt")
        print("harness: \(crashing.count) scenario(s) currently trap:\n\(report)")
    }

    /// Guards against an empty catalogue reading as a green run.
    func testScenarioCatalogueIsPresent() {
        XCTAssertFalse(
            Self.catalogue.isEmpty,
            "no scenarios found under \(Fixtures.scenariosRoot?.path ?? "‹no Fixtures folder›") "
            + "— the Fixtures folder reference is probably missing from the app's Resources phase"
        )
    }

    /// Every scenario's expected document must itself be a fixpoint, or
    /// the expectation is pinning a serializer bug rather than the
    /// behavior under test.
    func testEveryExpectedDocumentIsAFixpoint() {
        let runner = ScenarioRunner(controller: controller, textView: textView)
        var problems: [String] = []
        for scenario in Self.catalogue {
            if let problem = runner.expectedDocIsFixpoint(scenario) {
                problems.append("\(scenario.name): \(problem)")
            }
        }
        if !problems.isEmpty {
            XCTFail(problems.joined(separator: "\n\n"))
        }
    }

    // MARK: - Recording

    /// Runs every scenario and writes a copy with the *observed* result in
    /// `expect`, next to the author's belief. Off unless asked for:
    ///
    /// ```sh
    /// TEST_RUNNER_SWIFTPROSE_RECORD=1 \
    /// TEST_RUNNER_SWIFTPROSE_RECORD_OUT=/tmp/recorded xcodebuild test … \
    ///   -only-testing:SwiftProseDemoTests/ScenarioTests/testRecordScenarios
    /// ```
    ///
    /// A disagreement is the interesting output: either the scenario's
    /// expectation was wrong, or the editor is. It is never resolved by
    /// overwriting the file automatically.
    func testRecordScenarios() throws {
        guard HarnessLaunch.env("SWIFTPROSE_RECORD") != nil else {
            throw XCTSkip("set SWIFTPROSE_RECORD=1 to record scenario expectations")
        }
        let out = URL(fileURLWithPath:
            HarnessLaunch.env("SWIFTPROSE_RECORD_OUT")
            ?? NSTemporaryDirectory() + "swiftprose-recorded")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var agree: [String] = []
        var disagree: [String] = []
        var errored: [String] = []

        // A scenario that traps takes the recorder down with it, so the
        // name of the one being run is on disk before it starts: after a
        // trap, `current.txt` names the scenario to mark `crashes` and the
        // run picks up from there.
        let currentURL = out.appendingPathComponent("current.txt")
        for scenario in Self.catalogue {
            if let crash = scenario.crashes {
                errored.append("\(scenario.name): SKIPPED, traps — \(crash)")
                continue
            }
            try? scenario.name.write(to: currentURL, atomically: true, encoding: .utf8)
            reset(doc: "")
            let runner = ScenarioRunner(controller: controller, textView: textView)
            let result = runner.run(scenario)
            let observed = MarkedText.render(
                controller.markdown(),
                selection: textView.selectedRange(),
                markers: scenario.effectiveMarkers
            )
            var recorded = scenario
            recorded.expect = Expectation(doc: observed)
            recorded.xfail = nil
            let path = out.appendingPathComponent(scenario.name + ".json")
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let data = try? ScenarioCodec.encode(recorded) { try? data.write(to: path) }

            if let failure = result.expectationFailure, result.failures.isEmpty {
                // The ops ran but the belief did not hold.
                disagree.append("""
                \(scenario.name)
                  intent:   \(scenario.intent ?? "‹none›")
                  expected: \(EditOp.quote(scenario.expect?.doc ?? "‹none›"))
                  observed: \(EditOp.quote(observed))
                  \(failure.split(separator: "\n").first.map(String.init) ?? "")
                """)
            } else if !result.failures.isEmpty {
                errored.append("\(scenario.name): "
                    + result.failures.map(\.description).joined(separator: "; "))
            } else {
                agree.append(scenario.name)
            }
        }

        let report = """
        recorded \(Self.catalogue.count) scenarios into \(out.path)

        agree:    \(agree.count)
        disagree: \(disagree.count)
        oracle failures: \(errored.count)

        === DISAGREEMENTS ===
        \(disagree.joined(separator: "\n\n"))

        === ORACLE FAILURES ===
        \(errored.joined(separator: "\n"))
        """
        attach(report, name: "record-report.txt")
        try? report.write(to: out.appendingPathComponent("report.txt"),
                          atomically: true, encoding: .utf8)
        print(report)
    }

    // MARK: - Running one

    func runScenario(_ scenario: Scenario) throws {
        if let crash = scenario.crashes {
            // Running this in process would take the whole suite down
            // with it. The repro stays in the catalogue; replay it out
            // of process to work on it.
            throw XCTSkip("\(scenario.name) traps: \(crash) — replay it with `--harness replay --ops <ops.jsonl> --doc <initial.md>`")
        }
        reset(doc: "")
        let runner = ScenarioRunner(controller: controller, textView: textView)
        let result = runner.run(scenario)

        if let expected = scenario.xfail {
            // A known-failing scenario: assert it still fails the same way.
            // A fix trips the xfail instead of passing silently.
            // `xfail` is a substring of what the scenario reports when it
            // fails — an oracle signature, an oracle id, or the expectation
            // diff. Signatures normalize numbers, so pinning one verbatim
            // would break on an unrelated offset change.
            let signatures = result.failures.map(\.signature)
            let reported = (signatures + result.failures.map(\.oracle)
                            + [result.expectationFailure ?? ""]).joined(separator: "\n")
            let matched = reported.contains(expected)
            if result.passed || !matched {
                report("""
                xfail scenario \(scenario.name) no longer reproduces \(expected).
                Remove the `xfail` field and pin the correct expectation.
                observed: \(signatures.isEmpty ? "‹passed›" : signatures.joined(separator: ", "))
                """, ops: scenario.ops, repro: Self.repro(scenario))
            }
            return
        }

        guard !result.passed else { return }
        var body = "scenario \(scenario.name) failed"
        if let expectationFailure = result.expectationFailure {
            body += "\n\n" + expectationFailure
        }
        for failure in result.failures {
            body += "\n\n" + failure.description
        }
        body += "\n\nactual: " + EditOp.quote(
            MarkedText.render(result.finalMarkdown,
                              selection: textView.selectedRange(),
                              markers: scenario.effectiveMarkers)
        )
        report(body, ops: scenario.ops, repro: Self.repro(scenario))
    }

    static func repro(_ scenario: Scenario) -> String {
        """
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
        -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj -scheme SwiftProseDemo \
        -destination 'platform=macOS' \
        -only-testing:SwiftProseDemoTests/ScenarioTests/\(scenario.testMethodName)
        """
    }
}
