#if os(macOS)
import AppKit
import Foundation
@_spi(Harness) import SwiftProse

/// `SwiftProseDemo --harness fuzz|replay …` — the same engine the hosted
/// tests drive, without XCTest. Soak loops, out-of-process crash
/// shrinking, and watching a replay live all run through here.
///
/// ```
/// --harness fuzz   --seed 42 --steps 3000 --profile mixed --corpus readme
/// --harness replay --bundle build/fuzz/readme-mixed-42 [--stop-at 137]
/// --harness replay --bundle … --shrink
/// --harness replay --ops candidate.jsonl --doc initial.md --expect crash
/// ```
///
/// Exit codes: 0 clean, 1 an oracle failed, 2 a usage error. A crash
/// signature is a signal, not an exit code — which is exactly what the
/// out-of-process shrinker tests for.
@MainActor
enum HarnessCLI {

    static func scheduleRun(mode: HarnessLaunch.Mode) {
        // stdout is fully buffered when it isn't a TTY, and a soak run that
        // crashes would lose everything it printed.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Give the editor a chance to come up: the controller is published
        // from `onAppear` and the text view from `makeNSView`, one render
        // pass later.
        // A run-loop timer, not `DispatchQueue.main.asyncAfter`: the
        // driver settles by spinning the run loop, and libdispatch refuses
        // to drain the main queue re-entrantly, so work scheduled from
        // inside a main-queue block can never settle.
        schedule(after: 0.2) { waitForEditorThenRun(mode: mode) }
    }

    private static func waitForEditorThenRun(mode: HarnessLaunch.Mode, attempt: Int = 0) {
        guard let controller = HarnessRegistry.shared.controller,
              let textView = controller.hostTextView as? NSTextView,
              textView.window != nil else {
            guard attempt < 200 else {
                FileHandle.standardError.write(Data("harness: editor never came up\n".utf8))
                exit(2)
            }
            schedule(after: 0.05) { waitForEditorThenRun(mode: mode, attempt: attempt + 1) }
            return
        }
        HarnessLaunch.trace("editor ready after \(attempt) polls")
        NSApp.activate(ignoringOtherApps: true)
        textView.window?.makeKeyAndOrderFront(nil)
        textView.window?.makeFirstResponder(textView)
        switch mode {
        case .fuzz: runFuzz(controller: controller, textView: textView)
        case .replay: runReplay(controller: controller, textView: textView)
        default: break
        }
    }

    // MARK: - fuzz

    private static func runFuzz(controller: EditorController, textView: NSTextView) {
        let engine = FuzzEngine(controller: controller, textView: textView)
        let seeds = parseSeeds(HarnessLaunch.value("--seeds"))
            ?? [UInt64(HarnessLaunch.intValue("--seed") ?? 1)]
        let steps = HarnessLaunch.intValue("--steps") ?? 300
        let profile = FuzzProfile.named(HarnessLaunch.value("--profile") ?? "mixed")
        let corpora = HarnessLaunch.value("--corpus").map { [$0] }
            ?? Fixtures.corpus().map(\.name)
        var failed = 0

        for corpus in corpora {
            for seed in seeds {
                var config = FuzzEngine.Config()
                config.seed = seed
                config.steps = steps
                config.profile = profile
                config.corpus = corpus
                if let out = HarnessLaunch.value("--out") {
                    config.outputRoot = URL(fileURLWithPath: out)
                }
                HarnessRegistry.shared.status = "fuzz \(corpus) \(profile.name) seed \(seed)"
                let outcome = engine.run(config) { index, _ in
                    HarnessRegistry.shared.progress = index
                }
                print("harness: \(corpus)/\(profile.name)/\(seed) "
                      + "\(outcome.passed ? "clean" : "FAILED") — \(outcome.latency)")
                for failure in outcome.failures.prefix(5) { print("  \(failure)") }
                if !outcome.passed {
                    failed += 1
                    print("  bundle: \(outcome.bundle.path)")
                }
            }
        }
        exit(failed == 0 ? 0 : 1)
    }

    /// Fire `body` from the main run loop itself. Timers are serviced by
    /// a nested `RunLoop.run`; main-queue blocks are not.
    private static func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func parseSeeds(_ text: String?) -> [UInt64]? {
        guard let text else { return nil }
        if let dash = text.firstIndex(of: "-") {
            let lo = UInt64(text[text.startIndex..<dash]) ?? 1
            let hi = UInt64(text[text.index(after: dash)...]) ?? lo
            return Array(lo...max(lo, hi))
        }
        let parts = text.split(separator: ",").compactMap { UInt64($0) }
        return parts.isEmpty ? nil : parts
    }

    // MARK: - replay

    private static func runReplay(controller: EditorController, textView: NSTextView) {
        guard let (markdown, ops) = loadReplayInput() else {
            FileHandle.standardError.write(Data("harness: --bundle or --ops/--doc required\n".utf8))
            exit(2)
        }
        let engine = FuzzEngine(controller: controller, textView: textView)

        if let stopAt = HarnessLaunch.intValue("--stop-at") {
            HarnessRegistry.shared.status = "replay paused before op \(stopAt)"
            _ = engine.replay(initialMarkdown: markdown, ops: ops, stopAt: stopAt)
            HarnessRegistry.shared.paused = true
            HarnessRegistry.shared.progress = stopAt
            print("harness: stopped before op \(stopAt): \(ops[min(stopAt, ops.count - 1)].summary)")
            print("harness: window left open — single-step from here")
            return   // deliberately does not exit: the window stays up
        }

        if HarnessLaunch.has("--shrink") {
            shrink(engine: engine, controller: controller, textView: textView,
                   markdown: markdown, ops: ops)
            return
        }

        let failures = engine.replay(initialMarkdown: markdown, ops: ops)
        for failure in failures { print(failure) }
        // Reaching here means the replay finished without trapping. The
        // out-of-process shrinker reads the *presence* of this file as
        // "survived": an exit status can't tell a trap apart from the
        // window server killing a duplicate instance.
        if let done = HarnessLaunch.value("--done-file") {
            try? Data().write(to: URL(fileURLWithPath: done))
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func loadReplayInput() -> (String, [EditOp])? {
        if let bundle = HarnessLaunch.value("--bundle") {
            let root = URL(fileURLWithPath: bundle)
            let markdown = (try? String(contentsOf: root.appendingPathComponent("initial.md"),
                                        encoding: .utf8)) ?? ""
            guard let log = try? String(contentsOf: root.appendingPathComponent("ops.jsonl"),
                                        encoding: .utf8),
                  let ops = try? OpLog.decode(log) else { return nil }
            return (markdown, ops)
        }
        guard let opsPath = HarnessLaunch.value("--ops"),
              let log = try? String(contentsOf: URL(fileURLWithPath: opsPath), encoding: .utf8),
              let ops = try? OpLog.decode(log) else { return nil }
        let markdown = HarnessLaunch.value("--doc")
            .flatMap { try? String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) } ?? ""
        return (markdown, ops)
    }

    private static func shrink(engine: FuzzEngine,
                               controller: EditorController,
                               textView: NSTextView,
                               markdown: String,
                               ops: [EditOp]) {
        guard let signature = HarnessLaunch.value("--signature")
                ?? engine.replay(initialMarkdown: markdown, ops: ops, collectAll: false)
                    .first?.signature else {
            print("harness: the recorded log does not fail — nothing to shrink")
            exit(0)
        }
        let expectCrash = HarnessLaunch.value("--expect") == "crash"
        let judge: Shrinker.Judge = expectCrash
            ? Self.outOfProcessJudge(signature: signature)
            : Shrinker.inProcess(controller: controller, textView: textView)

        let shrinker = Shrinker(judge: judge)
        shrinker.onProgress = { print("harness: \($0)") }
        let output = shrinker.shrink(
            Shrinker.Input(initialMarkdown: markdown, ops: ops, signature: signature)
        )
        guard output.reproduced else {
            print("harness: nondeterministic — the signature did not recur")
            exit(1)
        }
        print("harness: shrank \(ops.count) ops → \(output.ops.count) in \(output.attempts) replays")
        for note in output.notes { print("  \(note)") }

        let root = HarnessLaunch.value("--bundle").map { URL(fileURLWithPath: $0) }
            ?? FuzzEngine.defaultOutputRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let log = try? OpLog.encode(output.ops) {
            try? log.write(to: root.appendingPathComponent("ops.min.jsonl"),
                           atomically: true, encoding: .utf8)
        }
        try? output.initialMarkdown.write(to: root.appendingPathComponent("initial.min.md"),
                                          atomically: true, encoding: .utf8)
        let seed = UInt64(HarnessLaunch.intValue("--seed") ?? 0)
        let scenario = Shrinker.scenario(
            from: output, seed: seed,
            profile: HarnessLaunch.value("--profile") ?? "mixed"
        )
        if let data = try? ScenarioCodec.encode(scenario) {
            let url = root.appendingPathComponent("regression.json")
            try? data.write(to: url)
            print("harness: wrote \(url.path)")
            print("harness: promote it to Fixtures/scenarios/regressions/")
        }
        exit(0)
    }

    /// Crash signatures can't be judged in process — the judge would take
    /// the trap with the candidate. Spawn a replay per candidate and see
    /// whether it reached the end.
    private static func outOfProcessJudge(signature: String) -> Shrinker.Judge {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        return { markdown, ops in
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftprose-shrink-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let docURL = scratch.appendingPathComponent("initial.md")
            let opsURL = scratch.appendingPathComponent("ops.jsonl")
            try? markdown.write(to: docURL, atomically: true, encoding: .utf8)
            guard let log = try? OpLog.encode(ops) else { return nil }
            try? log.write(to: opsURL, atomically: true, encoding: .utf8)

            let doneURL = scratch.appendingPathComponent("done")
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "--harness", "replay",
                "--ops", opsURL.path, "--doc", docURL.path,
                "--expect", "crash", "--done-file", doneURL.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            // The candidate reproduces iff the replay never reached the end.
            let survived = FileManager.default.fileExists(atPath: doneURL.path)
            return survived ? nil : signature
        }
    }
}
#endif
