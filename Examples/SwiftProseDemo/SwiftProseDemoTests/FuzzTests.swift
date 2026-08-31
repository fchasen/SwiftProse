import XCTest
import AppKit
@testable import SwiftProseDemo
@_spi(Harness) import SwiftProse

/// Seeded fuzz smoke. Small by default so it belongs in a normal test run;
/// the same code takes a longer budget from the environment, and
/// `Scripts/fuzz.sh` loops seeds through it without rebuilding.
///
/// ```sh
/// TEST_RUNNER_SWIFTPROSE_FUZZ_SEED=42 \
/// TEST_RUNNER_SWIFTPROSE_FUZZ_STEPS=5000 \
/// TEST_RUNNER_SWIFTPROSE_FUZZ_PROFILE=destroyer \
///   xcodebuild test … -only-testing:SwiftProseDemoTests/FuzzTests
/// ```
@MainActor
final class FuzzTests: HarnessTestCase {

    private var engine: FuzzEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try Self.requireNoOpenCrash()
        engine = FuzzEngine(controller: controller, textView: textView)
    }

    /// An Objective-C exception cannot be caught in Swift, so a fuzz run
    /// that rediscovers an already-known trap takes the process down and
    /// every test after it reports nonsense. While the catalogue still
    /// carries a `crashes` scenario, the smoke stands down and names it —
    /// delete that field when the crash is fixed and the smoke turns
    /// itself back on. `SWIFTPROSE_FUZZ_ANYWAY=1` overrides, and
    /// `Scripts/fuzz.sh --app` runs regardless, in its own process.
    static func requireNoOpenCrash() throws {
        guard HarnessLaunch.env("SWIFTPROSE_FUZZ_ANYWAY") == nil else { return }
        guard let root = Fixtures.scenariosRoot else { return }
        let open = ScenarioCodec.loadAll(under: root)
            .map(\.scenario)
            .filter { $0.crashes != nil }
        guard !open.isEmpty else { return }
        let names = open.map { "  · \($0.name)" }.joined(separator: "\n")
        throw XCTSkip(
            "\(open.count) known crash(es) are still open, and a fuzz run that hits one "
            + "takes the process down with it:\n\(names)\n"
            + "Fix them, or set SWIFTPROSE_FUZZ_ANYWAY=1, to re-enable the smoke."
        )
    }

    /// Three seeds over the built-in fixtures — enough to catch a broken
    /// driver or a regressed invariant without slowing an ordinary run.
    func testSmokeOverBuiltInFixtures() throws {
        let steps = HarnessLaunch.envInt("SWIFTPROSE_FUZZ_STEPS") ?? 300
        let seeds = Self.requestedSeeds ?? [1, 2, 3]
        let profile = FuzzProfile.named(
            HarnessLaunch.env("SWIFTPROSE_FUZZ_PROFILE") ?? "mixed"
        )
        let corpus = HarnessLaunch.env("SWIFTPROSE_FUZZ_CORPUS")
        let documents = corpus.map { name in
            Fixtures.corpus().filter { $0.name == name }
        } ?? Fixtures.builtIn.filter { !$0.markdown.isEmpty }

        XCTAssertFalse(documents.isEmpty, "no corpus document matched")

        for document in documents {
            for seed in seeds {
                try runOne(document: document, seed: seed, steps: steps, profile: profile)
            }
        }
    }

    /// One profile per seed, so a single ordinary run touches every input
    /// route: typing, structure, IME, destruction.
    func testEachProfileGetsOneShortRun() throws {
        guard Self.requestedSeeds == nil else {
            throw XCTSkip("an explicit seed was requested; the profile sweep is skipped")
        }
        let document = Fixtures.builtIn[2]
        for (index, profile) in FuzzProfile.all.enumerated() {
            try runOne(document: (document.name, document.markdown),
                       seed: UInt64(100 + index), steps: 120, profile: profile)
        }
    }

    private static var requestedSeeds: [UInt64]? {
        if let seeds = HarnessLaunch.env("SWIFTPROSE_FUZZ_SEEDS") {
            return HarnessCLI.parseSeeds(seeds)
        }
        if let seed = HarnessLaunch.envInt("SWIFTPROSE_FUZZ_SEED") {
            return [UInt64(seed)]
        }
        return nil
    }

    private func runOne(document: (name: String, markdown: String),
                        seed: UInt64,
                        steps: Int,
                        profile: FuzzProfile) throws {
        reset(doc: "")
        var config = FuzzEngine.Config()
        config.seed = seed
        config.steps = steps
        config.profile = profile
        config.corpus = document.name
        config.markdown = document.markdown
        if let out = HarnessLaunch.env("SWIFTPROSE_FUZZ_OUT") {
            config.outputRoot = URL(fileURLWithPath: out)
        }

        let outcome = engine.run(config)
        attach(outcome.latency, name: "latency-\(document.name)-\(profile.name)-\(seed).txt")

        guard !outcome.passed else { return }

        // Shrink before reporting: a 3000-op log says nothing, a 6-op one
        // says everything.
        var body = """
        fuzz \(document.name)/\(profile.name)/seed \(seed) failed after \(outcome.ops.count) ops
        bundle: \(outcome.bundle.path)
        latency: \(outcome.latency)

        """
        for failure in outcome.failures.prefix(8) { body += "\n\(failure)" }

        if let signature = outcome.signature {
            let shrinker = Shrinker(judge: Shrinker.inProcess(controller: controller, textView: textView))
            shrinker.maxAttempts = HarnessLaunch.envInt("SWIFTPROSE_SHRINK_BUDGET") ?? 400
            let shrunk = shrinker.shrink(Shrinker.Input(
                initialMarkdown: outcome.initialMarkdown,
                ops: outcome.ops,
                signature: signature
            ))
            if shrunk.reproduced {
                body += "\n\nshrank to \(shrunk.ops.count) op(s) over "
                    + "\(Shrinker.blocks(of: shrunk.initialMarkdown).count) block(s):"
                body += "\n" + ((try? OpLog.encode(shrunk.ops)) ?? "")
                body += "\ninitial:\n" + shrunk.initialMarkdown
                let regression = Shrinker.scenario(from: shrunk, seed: seed, profile: profile.name)
                if let data = try? ScenarioCodec.encode(regression) {
                    attach(String(decoding: data, as: UTF8.self), name: "regression.json")
                    body += "\n\nPromote the attached regression.json to "
                        + "Fixtures/scenarios/regressions/."
                }
            } else {
                body += "\n\nnondeterministic: the failure did not reproduce on replay"
            }
        }

        body += "\n\nreplay: SwiftProseDemo.app/Contents/MacOS/SwiftProseDemo "
            + "--harness replay --bundle \(outcome.bundle.path) --stop-at "
            + "\((outcome.failures.first?.opIndex).map(String.init) ?? "0")"

        report(body, ops: outcome.ops)
    }
}
