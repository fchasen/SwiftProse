#if os(macOS)
import AppKit
import Foundation
@_spi(Harness) import SwiftProse

/// SplitMix64 — the same generator the package's randomized tests use, so
/// a seed means the same thing on both sides.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What kind of user a run is imitating. Weights are relative; the
/// generator draws an op kind proportionally.
struct FuzzProfile {
    var name: String
    var weights: [OpKind: Int]
    var cadenceOverride: Oracles.Cadence?

    enum OpKind: String, CaseIterable {
        case type, typeBurst, key, caret, select, action, undo, redo
        case paste, cut, copy, compose, correct, toggleCheckbox
        case closeHistoryGroup
    }

    static let typist = FuzzProfile(name: "typist", weights: [
        .type: 60, .key: 22, .caret: 10, .select: 3, .undo: 3, .redo: 2
    ])

    static let editor = FuzzProfile(name: "editor", weights: [
        .type: 24, .key: 14, .caret: 10, .select: 12, .action: 24,
        .undo: 8, .redo: 4, .closeHistoryGroup: 4
    ])

    static let destroyer = FuzzProfile(name: "destroyer", weights: [
        .select: 26, .key: 18, .cut: 10, .paste: 16, .undo: 14, .redo: 6,
        .type: 8, .caret: 2
    ])

    static let ime = FuzzProfile(name: "ime", weights: [
        .compose: 40, .correct: 18, .typeBurst: 18, .type: 12, .caret: 8,
        .key: 4
    ])

    static let structural = FuzzProfile(name: "structural", weights: [
        .type: 30, .key: 34, .action: 20, .caret: 10, .undo: 6
    ])

    static let mixed = FuzzProfile(name: "mixed", weights: [
        .type: 26, .key: 18, .caret: 8, .select: 8, .action: 12,
        .undo: 7, .redo: 4, .paste: 6, .cut: 3, .copy: 2, .typeBurst: 2,
        .compose: 2, .correct: 1, .toggleCheckbox: 1
    ])

    static let all: [FuzzProfile] = [typist, editor, destroyer, ime, structural, mixed]

    static func named(_ name: String) -> FuzzProfile {
        all.first { $0.name == name } ?? mixed
    }
}

/// A seeded random edit session over a real document, with a write-ahead
/// op log and a failure bundle.
@MainActor
final class FuzzEngine {

    struct Config {
        var seed: UInt64 = 1
        var steps: Int = 300
        var profile: FuzzProfile = .mixed
        var corpus: String = "kitchen-sink"
        var markdown: String = ""
        /// Directory the failure bundle is written to.
        var outputRoot: URL = FuzzEngine.fallbackOutputRoot
        /// Report every failure instead of stopping at the first.
        var collectAll = true
        /// Cap on how long one run may take, as a safety valve for a
        /// pathological document.
        var timeLimit: TimeInterval = 600
    }

    struct Outcome {
        var config: Config
        var bundle: URL
        var failures: [OracleFailure]
        var ops: [EditOp]
        var initialMarkdown: String
        var finalMarkdown: String
        var latency: String
        var classCoverage: [String: Int]

        var passed: Bool { failures.isEmpty }
        /// What the shrinker minimizes toward.
        var signature: String? { failures.first?.signature }
    }

    static var defaultOutputRoot: URL {
        if let override = HarnessLaunch.env("SWIFTPROSE_FUZZ_OUT") {
            return URL(fileURLWithPath: override)
        }
        return fallbackOutputRoot
    }

    /// Default for `Config.outputRoot`, which is initialized outside any
    /// actor. `defaultOutputRoot` layers the env override on top.
    nonisolated static let fallbackOutputRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("swiftprose-fuzz", isDirectory: true)

    let controller: EditorController
    let textView: NSTextView

    init(controller: EditorController, textView: NSTextView) {
        self.controller = controller
        self.textView = textView
    }

    // MARK: - Running

    func run(_ config: Config, progress: ((Int, EditOp) -> Void)? = nil) -> Outcome {
        let markdown = config.markdown.isEmpty
            ? (Fixtures.document(named: config.corpus) ?? Fixtures.builtIn[2].markdown)
            : config.markdown

        let bundle = config.outputRoot
            .appendingPathComponent("\(config.corpus)-\(config.profile.name)-\(config.seed)")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        // Printed before the first op: a crash still points at the log.
        print("harness: fuzz bundle \(bundle.path)")
        try? markdown.write(to: bundle.appendingPathComponent("initial.md"),
                            atomically: true, encoding: .utf8)
        let logURL = bundle.appendingPathComponent("ops.jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        defer { try? log?.close() }

        HarnessRegistry.shared.clearCollected()
        controller.historyConfig = HistoryConfig(newGroupDelay: 1e9)
        // One run should report many failures, not trap on the first.
        controller.harnessAssertsOnDiagnostics = false
        defer { controller.harnessAssertsOnDiagnostics = true }

        let driver = EditDriver(controller: controller, textView: textView)
        driver.clearInputState()
        let oracles = Oracles(
            controller: controller, textView: textView,
            cadence: config.profile.cadenceOverride ?? .scaled(forLength: (markdown as NSString).length)
        )
        oracles.collectAll = config.collectAll

        var generator = OpGenerator(
            seed: config.seed, profile: config.profile,
            controller: controller, textView: textView
        )

        var ops: [EditOp] = []
        let start = Date()
        do {
            try driver.perform(.load(markdown: markdown, keepHistory: false))
            driver.settle()
            oracles.baselineMarkdown = controller.markdown()

            for index in 0..<config.steps {
                guard Date().timeIntervalSince(start) < config.timeLimit else {
                    print("harness: fuzz hit the \(Int(config.timeLimit))s time limit at op \(index)")
                    break
                }
                let op = generator.next()
                ops.append(op)
                // Write-ahead: the log is on disk *before* the op runs, so
                // a crash leaves the offending op as the last line.
                if let line = try? OpLog.encode([op]), let data = line.data(using: .utf8) {
                    try? log?.write(contentsOf: data)
                    try? log?.synchronize()
                }
                HarnessLaunch.trace("op \(index): \(op.summary)")
                let opStart = Date()
                try driver.perform(op, at: index)
                driver.settle()
                oracles.record(duration: Date().timeIntervalSince(opStart))
                try oracles.checkCadenced(at: index, op: op)
                progress?(index, op)
            }
            // End-of-run tier: the expensive oracles, once.
            try oracles.run(
                ["markdownFixpoint", "pmJSON", "history", "layout", "offsets", "specFull", "schema", "projection"],
                at: ops.count
            )
        } catch let failure as EditDriver.Failure {
            if case .oracle = failure {
                // Already recorded on `oracles.failures`.
            } else {
                oracles.note(OracleFailure(
                    oracle: "driver", detail: failure.description, opIndex: ops.count - 1
                ))
            }
        } catch {
            oracles.note(OracleFailure(
                oracle: "driver", detail: "\(error)", opIndex: ops.count - 1
            ))
        }

        let outcome = Outcome(
            config: config,
            bundle: bundle,
            failures: oracles.failures,
            ops: ops,
            initialMarkdown: markdown,
            finalMarkdown: controller.markdown(),
            latency: oracles.latencyReport,
            classCoverage: HarnessRegistry.shared.classCoverage
        )
        writeBundle(outcome)
        return outcome
    }

    // MARK: - Failure bundle

    func writeBundle(_ outcome: Outcome) {
        let bundle = outcome.bundle
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        func write(_ text: String, _ name: String) {
            try? text.write(to: bundle.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        write(outcome.initialMarkdown, "before.md")
        write(outcome.finalMarkdown, "after.md")
        write(StorageDump.dump(controller.textStorage), "storage.txt")
        if let log = try? OpLog.encode(outcome.ops) { write(log, "ops.jsonl") }

        let failure: [String: Any] = [
            "seed": String(outcome.config.seed),
            "steps": outcome.config.steps,
            "profile": outcome.config.profile.name,
            "corpus": outcome.config.corpus,
            "signature": outcome.signature ?? "",
            "latency": outcome.latency,
            "classCoverage": outcome.classCoverage,
            "failures": outcome.failures.map {
                ["oracle": $0.oracle, "opIndex": $0.opIndex,
                 "signature": $0.signature, "detail": $0.detail]
            }
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: failure, options: [.prettyPrinted, .sortedKeys]
        ) {
            write(String(decoding: data, as: UTF8.self), "failure.json")
        }

        write("""
        #!/bin/sh
        # Replay this run. Add --stop-at N to pause just before an op, or
        # --shrink to minimize it.
        set -e
        APP="${SWIFTPROSE_DEMO_APP:-$(dirname "$0")/../../SwiftProseDemo.app}"
        exec "$APP/Contents/MacOS/SwiftProseDemo" --harness replay \\
          --bundle "$(cd "$(dirname "$0")" && pwd)" "$@"

        """, "repro.sh")
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundle.appendingPathComponent("repro.sh").path
        )
    }

    // MARK: - Replay

    /// Replay a recorded log. Used by the shrinker (in process) and by
    /// `--harness replay` (out of process, for crash signatures).
    func replay(initialMarkdown: String,
                ops: [EditOp],
                stopAt: Int? = nil,
                collectAll: Bool = true) -> [OracleFailure] {
        controller.historyConfig = HistoryConfig(newGroupDelay: 1e9)
        controller.harnessAssertsOnDiagnostics = false
        defer { controller.harnessAssertsOnDiagnostics = true }

        let driver = EditDriver(controller: controller, textView: textView)
        driver.clearInputState()
        let oracles = Oracles(
            controller: controller, textView: textView,
            cadence: .scaled(forLength: (initialMarkdown as NSString).length)
        )
        oracles.collectAll = collectAll
        do {
            HarnessLaunch.trace("replay: load \((initialMarkdown as NSString).length) chars")
            try driver.perform(.load(markdown: initialMarkdown, keepHistory: false))
            driver.settle()
            oracles.baselineMarkdown = controller.markdown()
            HarnessLaunch.trace("replay: loaded, \(ops.count) ops")
            for (index, op) in ops.enumerated() {
                if let stopAt, index >= stopAt { return oracles.failures }
                HarnessLaunch.trace("op \(index): \(op.summary)")
                try driver.perform(op, at: index)
                driver.settle()
                try oracles.checkCadenced(at: index, op: op)
            }
            try oracles.run(
                ["markdownFixpoint", "pmJSON", "history", "layout", "offsets", "specFull", "schema", "projection"],
                at: ops.count
            )
        } catch let failure as EditDriver.Failure {
            if case .oracle = failure {} else {
                oracles.note(OracleFailure(
                    oracle: "driver", detail: failure.description, opIndex: ops.count - 1
                ))
            }
        } catch {
            oracles.note(OracleFailure(
                oracle: "driver", detail: "\(error)", opIndex: ops.count - 1
            ))
        }
        return oracles.failures
    }
}

// MARK: - Generator

/// Draws ops from the live document: block boundaries, mark-run edges,
/// list-marker prefixes and attachment neighbours are where the
/// interesting bugs are, so they get drawn far more often than a uniform
/// offset would give.
@MainActor
struct OpGenerator {
    var rng: Seeded
    let profile: FuzzProfile
    let controller: EditorController
    let textView: NSTextView
    private let kinds: [FuzzProfile.OpKind]

    init(seed: UInt64, profile: FuzzProfile, controller: EditorController, textView: NSTextView) {
        self.rng = Seeded(seed: seed)
        self.profile = profile
        self.controller = controller
        self.textView = textView
        var expanded: [FuzzProfile.OpKind] = []
        for kind in FuzzProfile.OpKind.allCases {
            expanded += Array(repeating: kind, count: profile.weights[kind] ?? 0)
        }
        self.kinds = expanded.isEmpty ? [.type] : expanded
    }

    mutating func next() -> EditOp {
        switch kinds.randomElement(using: &rng)! {
        case .type: return .type(text: text())
        case .typeBurst: return .typeBurst(text: burst())
        case .key: return .key(key())
        case .caret: return .caret(anchor(at: position()))
        case .select:
            let a = position(), b = position()
            return .select(from: anchor(at: min(a, b)), to: anchor(at: max(a, b)))
        case .action:
            let id = EditDriver.actionIDs.randomElement(using: &rng)!
            return .action(id: id, url: nil, label: nil, rows: nil, columns: nil)
        case .undo: return .undo(n: Int.random(in: 1...3, using: &rng))
        case .redo: return .redo(n: Int.random(in: 1...2, using: &rng))
        case .paste: return .paste(text: burst(), html: nil, plain: Bool.random(using: &rng))
        case .cut: return .cut
        case .copy: return .copy
        case .compose:
            let target = Self.compositions.randomElement(using: &rng)!
            let cancel = Int.random(in: 0..<8, using: &rng) == 0
            return .compose(interims: target.interims, commit: cancel ? nil : target.commit)
        case .correct:
            guard let word = existingWord() else { return .type(text: text()) }
            return .correct(find: word, replace: word.uppercased() + "x")
        case .toggleCheckbox: return .toggleCheckbox(anchor(at: position()))
        case .closeHistoryGroup: return .closeHistoryGroup
        }
    }

    // MARK: positions

    /// Recorded as a number plus a content anchor, so a shrunk log stays
    /// meaningful once the ops that produced the offsets are gone.
    private mutating func anchor(at position: Int) -> Anchor {
        let string = textView.string as NSString
        let clamped = max(0, min(position, string.length))
        // 8–16 UTF-16 units of context before the position, disambiguated
        // by occurrence index.
        let span = Int.random(in: 8...16, using: &rng)
        let start = max(0, clamped - span)
        guard start < clamped else { return Anchor(at: clamped) }
        let needle = string.substring(with: NSRange(location: start, length: clamped - start))
        guard !needle.contains("\u{FFFC}") else { return Anchor(at: clamped) }
        var occurrence = 0
        var searchFrom = 0
        while searchFrom < start {
            let found = string.range(
                of: needle, options: [],
                range: NSRange(location: searchFrom, length: string.length - searchFrom)
            )
            if found.location == NSNotFound || found.location >= start { break }
            occurrence += 1
            searchFrom = found.location + max(1, found.length)
        }
        return Anchor(at: clamped, after: needle, n: occurrence)
    }

    private mutating func position() -> Int {
        var candidates = interestingPositions()
        let length = (textView.string as NSString).length
        guard length > 0 else { return 0 }
        // A third of the draws are uniform, so the interesting set can't
        // trap the fuzzer in one region of the document.
        if Int.random(in: 0..<3, using: &rng) == 0 || candidates.isEmpty {
            return Int.random(in: 0...length, using: &rng)
        }
        candidates.sort()
        return candidates.randomElement(using: &rng)!
    }

    private func interestingPositions() -> [Int] {
        let storage = controller.textStorage
        let string = storage.string as NSString
        guard string.length > 0 else { return [0] }
        var out: Set<Int> = [0, string.length, max(0, string.length - 1)]
        var i = 0
        var lines = 0
        while i < string.length, lines < 400 {
            let line = string.lineRange(for: NSRange(location: i, length: 0))
            out.insert(line.location)
            out.insert(max(line.location, line.location + line.length - 1))
            // Just past a list marker / checkbox prefix, where a spec
            // carries but the text doesn't.
            var probe = line.location
            while probe < line.location + line.length,
                  storage.safeAttribute(.proseListMarker, at: probe) as? Bool == true {
                probe += 1
            }
            if probe != line.location { out.insert(probe) }
            i = line.location + max(1, line.length)
            lines += 1
        }
        // Mark-run boundaries and attachment neighbours.
        var runs = 0
        storage.enumerateAttribute(
            .proseMarks, in: NSRange(location: 0, length: string.length), options: []
        ) { _, range, stop in
            out.insert(range.location)
            out.insert(range.location + range.length)
            runs += 1
            if runs > 400 { stop.pointee = true }
        }
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: string.length), options: []
        ) { value, range, _ in
            guard value != nil else { return }
            out.insert(max(0, range.location - 1))
            out.insert(range.location)
            out.insert(range.location + range.length)
        }
        return Array(out).filter { $0 >= 0 && $0 <= string.length }
    }

    private func existingWord() -> String? {
        let words = textView.string
            .split(whereSeparator: { !$0.isLetter })
            .filter { $0.count >= 3 }
        guard !words.isEmpty else { return nil }
        var copy = rng
        guard let picked = words.randomElement(using: &copy) else { return nil }
        return String(picked)
    }

    // MARK: payloads

    private mutating func text() -> String {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0...4: return String(Self.letters.randomElement(using: &rng)!)
        case 5, 6: return Self.markdownFragments.randomElement(using: &rng)!
        case 7: return Self.unicode.randomElement(using: &rng)!
        case 8: return documentWord() ?? "word"
        default: return Self.whitespace.randomElement(using: &rng)!
        }
    }

    private mutating func burst() -> String {
        let count = Int.random(in: 2...6, using: &rng)
        var parts: [String] = []
        for _ in 0..<count { parts.append(documentWord() ?? "lorem") }
        let joiner = Int.random(in: 0..<4, using: &rng) == 0 ? "\n\n" : " "
        return parts.joined(separator: joiner)
    }

    private mutating func documentWord() -> String? {
        let words = textView.string.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let picked = words.randomElement(using: &rng) else { return nil }
        return String(picked)
    }

    private mutating func key() -> String {
        Self.keys.randomElement(using: &rng)!
    }

    static let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,;:!?'\"-()[]{}")

    static let markdownFragments = [
        "**", "*", "~~", "`", "# ", "## ", "- ", "1. ", "> ", "```", "```swift\n",
        "[", "](", "![", "|", "---", "- [ ] ", "- [x] ", "> [!NOTE]\n", "<div>",
        "&amp;", "\\", "  ", "\t"
    ]

    static let unicode = [
        "é", "ü", "ñ", "日本語", "한국어", "العربية", "עברית", "🙂", "👍🏽",
        "👨‍👩‍👧‍👦", "🇯🇵", "e\u{301}", "a\u{0300}\u{0301}", "\u{00A0}", "\u{200B}",
        "\u{200D}", "\u{200C}", "\u{FEFF}", "“curly”", "‘quotes’", "—", "…",
        "\u{1F600}\u{FE0F}", "𝕊𝕨𝕚𝕗𝕥"
    ]

    static let whitespace = [" ", "  ", "\n", "\n\n", "\t", " \n"]

    /// Movement and editing keys only: command shortcuts go through
    /// `action` so the fuzzer doesn't depend on a keymap binding.
    static let keys = [
        "Enter", "Enter", "Enter", "Backspace", "Backspace", "Backspace",
        "Delete", "Tab", "Shift-Tab", "ArrowLeft", "ArrowRight", "ArrowUp",
        "ArrowDown", "Shift-ArrowLeft", "Shift-ArrowRight", "Shift-ArrowUp",
        "Shift-ArrowDown", "Alt-ArrowLeft", "Alt-ArrowRight", "Mod-ArrowLeft",
        "Mod-ArrowRight", "Alt-Backspace", "Shift-Enter", "Mod-Enter"
    ]

    /// Real IME shapes: a dead key, a Japanese candidate, Korean jamo
    /// composition, an emoji-picker insert.
    static let compositions: [(interims: [String], commit: String)] = [
        (["´"], "é"),
        (["k", "ka", "かk", "かき"], "書き"),
        (["ㅎ", "하", "한"], "한"),
        (["n", "ni", "にh", "にほ", "にほん"], "日本"),
        (["p", "py", "pyt"], "python"),
        ([":", ":s", ":sm"], "🙂")
    ]
}
#endif
