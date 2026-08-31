#if os(macOS)
import AppKit
import Foundation
@_spi(Harness) import SwiftProse

/// Minimizes a failing op log toward the smallest thing that still fails
/// the same way.
///
/// Order matters: ops first (the biggest win), then the initial document,
/// then payload sizes. Every candidate is judged by *signature*, not by
/// "still fails" — otherwise a candidate that trips a different bug looks
/// like progress and the result explains nothing.
@MainActor
final class Shrinker {

    struct Input {
        var initialMarkdown: String
        var ops: [EditOp]
        var signature: String
    }

    struct Output {
        var initialMarkdown: String
        var ops: [EditOp]
        var signature: String
        var reproduced: Bool
        var attempts: Int
        var notes: [String]
    }

    /// Judges a candidate. In process for oracle failures; the CLI swaps in
    /// an out-of-process runner for crash signatures, where the only way to
    /// observe the failure is a non-zero exit code.
    typealias Judge = @MainActor (_ markdown: String, _ ops: [EditOp]) -> String?

    let judge: Judge
    /// Safety valve: a pathological log shouldn't shrink forever.
    var maxAttempts = 3_000
    var onProgress: ((String) -> Void)?

    init(judge: @escaping Judge) {
        self.judge = judge
    }

    /// In-process judge over a live editor.
    static func inProcess(controller: EditorController, textView: NSTextView) -> Judge {
        let engine = FuzzEngine(controller: controller, textView: textView)
        return { markdown, ops in
            engine.replay(initialMarkdown: markdown, ops: ops, collectAll: false)
                .first?.signature
        }
    }

    func shrink(_ input: Input) -> Output {
        var attempts = 0
        var notes: [String] = []

        // 1. Reproduce first. A signature that doesn't recur is a
        //    nondeterminism report, not a shrink target.
        attempts += 1
        guard judge(input.initialMarkdown, input.ops) == input.signature else {
            return Output(
                initialMarkdown: input.initialMarkdown, ops: input.ops,
                signature: input.signature, reproduced: false, attempts: attempts,
                notes: ["nondeterministic: the recorded signature did not recur on replay"]
            )
        }

        func fails(_ markdown: String, _ ops: [EditOp]) -> Bool {
            guard attempts < maxAttempts else { return false }
            attempts += 1
            return judge(markdown, ops) == input.signature
        }

        // 2. ddmin over the op list.
        var ops = ddmin(input.ops) { fails(input.initialMarkdown, $0) }
        onProgress?("ops \(input.ops.count) → \(ops.count)")
        notes.append("ops \(input.ops.count) → \(ops.count)")

        // 3. ddmin the initial document over blank-line-separated blocks.
        var markdown = input.initialMarkdown
        let blocks = Self.blocks(of: markdown)
        if blocks.count > 1 {
            let keptBlocks = ddmin(blocks) { fails(Self.join($0), ops) }
            let candidate = Self.join(keptBlocks)
            if fails(candidate, ops) {
                notes.append("doc blocks \(blocks.count) → \(keptBlocks.count)")
                markdown = candidate
            }
        }

        // 4. Halve `type` / `paste` payloads.
        ops = shrinkPayloads(ops) { fails(markdown, $0) }

        // 5. Re-anchor. Content anchors recorded against the original
        //    document usually don't occur in the shrunk one, so they fall
        //    back to raw offsets — but that rewrite changes what the log
        //    *does*, so it only stands if the signature survives it.
        let reanchored = reanchor(ops: ops)
        if reanchored != ops {
            if fails(markdown, reanchored) {
                ops = reanchored
                notes.append("re-anchored to plain offsets")
            } else {
                notes.append("kept content anchors — the plain-offset rewrite "
                             + "no longer reproduces")
            }
        }

        // Reproduce once more from exactly what is being handed back. A
        // minimized log that doesn't fail is worse than no minimization.
        if !fails(markdown, ops) {
            return Output(
                initialMarkdown: input.initialMarkdown, ops: input.ops,
                signature: input.signature, reproduced: true, attempts: attempts,
                notes: notes + ["minimization did not survive its own check — "
                                + "returning the original log"]
            )
        }

        return Output(
            initialMarkdown: markdown, ops: ops, signature: input.signature,
            reproduced: true, attempts: attempts, notes: notes
        )
    }

    // MARK: - ddmin

    /// Classic delta-debugging: try to drop half, then quarters, and so on;
    /// keep a drop only when the same signature still fails.
    func ddmin<T>(_ items: [T], stillFails: ([T]) -> Bool) -> [T] {
        var current = items
        var granularity = 2
        while current.count >= 2 {
            let chunkSize = max(1, current.count / granularity)
            var reduced = false
            var start = 0
            while start < current.count {
                let end = min(current.count, start + chunkSize)
                var candidate = current
                candidate.removeSubrange(start..<end)
                if !candidate.isEmpty || items.isEmpty {
                    if stillFails(candidate) {
                        current = candidate
                        granularity = max(2, granularity - 1)
                        reduced = true
                        break
                    }
                }
                start = end
            }
            if !reduced {
                if granularity >= current.count { break }
                granularity = min(current.count, granularity * 2)
            }
        }
        return current
    }

    /// Halve `type` / `typeBurst` / `paste` payloads while the signature
    /// holds. A 40-character insert that only needed two characters is the
    /// difference between a readable repro and an unreadable one.
    private func shrinkPayloads(_ ops: [EditOp], stillFails: ([EditOp]) -> Bool) -> [EditOp] {
        var current = ops
        for index in current.indices {
            var payload: String
            switch current[index] {
            case .type(let t), .typeBurst(let t): payload = t
            case .paste(let t, _, _): payload = t
            default: continue
            }
            while payload.count > 1 {
                let half = String(payload.prefix(max(1, payload.count / 2)))
                var candidate = current
                candidate[index] = Self.withPayload(current[index], half)
                if stillFails(candidate) {
                    current = candidate
                    payload = half
                } else {
                    break
                }
            }
        }
        return current
    }

    private static func withPayload(_ op: EditOp, _ text: String) -> EditOp {
        switch op {
        case .type: return .type(text: text)
        case .typeBurst: return .typeBurst(text: text)
        case .paste(_, let html, let plain): return .paste(text: text, html: html, plain: plain)
        default: return op
        }
    }

    /// Drop content anchors in favour of the raw offsets they were
    /// recorded with, so the committed scenario reads against the shrunk
    /// document rather than text that is no longer in it. The caller
    /// re-judges the result — this rewrite is a proposal, not a fact.
    private func reanchor(ops: [EditOp]) -> [EditOp] {
        var out: [EditOp] = []
        for op in ops {
            switch op {
            case .caret(let a):
                out.append(.caret(Self.plain(a)))
            case .select(let from, let to):
                out.append(.select(from: Self.plain(from), to: Self.plain(to)))
            case .toggleCheckbox(let a):
                out.append(.toggleCheckbox(Self.plain(a)))
            default:
                out.append(op)
            }
        }
        return out
    }

    /// Drop the content anchor, keep the offset. The offset is what still
    /// means something after the document shrank.
    private static func plain(_ anchor: Anchor) -> Anchor {
        guard anchor.at != nil else { return anchor }
        return Anchor(at: anchor.at)
    }

    // MARK: - Document blocks

    static func blocks(of markdown: String) -> [String] {
        markdown.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }

    static func join(_ blocks: [String]) -> String {
        blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Promotion

    /// A ready-to-commit regression scenario for the shrunk log. `xfail`
    /// carries the signature so a fix trips the xfail rather than passing
    /// silently.
    static func scenario(from output: Output,
                         seed: UInt64,
                         profile: String) -> Scenario {
        let slug = output.signature
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
            .prefix(60)
        return Scenario(
            name: "regressions/\(slug)-\(seed)",
            tags: ["regression", "fuzz", profile],
            config: Scenario.Config(newGroupDelay: 1e9),
            doc: output.initialMarkdown,
            ops: output.ops,
            expect: nil,
            finally: ["tier0", "projection", "markdownFixpoint"],
            xfail: output.signature
        )
    }
}
#endif
