import Testing
import Foundation
import Darwin
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Baseline measurements for the editing pipeline. Off by default — the
/// long-fence fixture alone takes seconds to compile. Run with:
///
///     SWIFTPROSE_BENCH=1 swift test --filter KeystrokeBenchmarkTests
///
/// Numbers land in `Benchmarks/BASELINE.md`.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTPROSE_BENCH"] != nil)
)
struct KeystrokeBenchmarkTests {

    // MARK: - measurement

    struct Sample {
        let name: String
        let medianMicros: Double
        let p90Micros: Double
        let blocksPerOp: Double
    }

    /// Live allocated blocks across every malloc zone. Coarse, but the
    /// delta over a few hundred iterations is a stable signal for "this
    /// path allocates an object graph per keystroke".
    static func liveBlocks() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.blocks_in_use)
    }

    static func measure(
        _ name: String,
        iterations: Int = 50,
        warmup: Int = 5,
        setup: () -> Void = {},
        teardown: () -> Void = {},
        _ body: (Int) -> Void
    ) -> Sample {
        for i in 0..<warmup { setup(); body(i); teardown() }
        var timings: [Double] = []
        timings.reserveCapacity(iterations)
        let clock = ContinuousClock()
        let blocksBefore = liveBlocks()
        for i in 0..<iterations {
            setup()
            let elapsed = clock.measure { body(i) }
            teardown()
            timings.append(Double(elapsed.components.attoseconds) / 1e12
                           + Double(elapsed.components.seconds) * 1e6)
        }
        let blocksAfter = liveBlocks()
        timings.sort()
        let median = timings[timings.count / 2]
        let p90 = timings[min(timings.count - 1, Int(Double(timings.count) * 0.9))]
        return Sample(
            name: name,
            medianMicros: median,
            p90Micros: p90,
            blocksPerOp: Double(blocksAfter - blocksBefore) / Double(iterations)
        )
    }

    static func report(_ title: String, _ samples: [Sample]) {
        var lines = ["", "### \(title)", "", "| case | median µs | p90 µs | live blocks/op |", "|---|---:|---:|---:|"]
        for s in samples {
            lines.append(String(
                format: "| %@ | %.1f | %.1f | %.1f |",
                s.name, s.medianMicros, s.p90Micros, s.blocksPerOp
            ))
        }
        print(lines.joined(separator: "\n"))
    }

    // MARK: - helpers

    /// One platform-style keystroke: exactly what `NSTextView` does when
    /// the user types a character.
    static func keystroke(_ controller: EditorController, at location: Int) {
        let storage = controller.textStorage
        let safe = max(0, min(location, storage.length))
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: safe, length: 0), with: "a")
        storage.endEditing()
    }

    static func undoKeystroke(_ controller: EditorController, at location: Int) {
        let storage = controller.textStorage
        let safe = max(0, min(location, storage.length - 1))
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: safe, length: 1), with: "")
        storage.endEditing()
    }

    /// Five probe offsets through the mixed document: start, mid
    /// paragraph, a nested list item, inside a fence, and the tail.
    static func probeOffsets(_ controller: EditorController) -> [(String, Int)] {
        let storage = controller.textStorage
        let total = storage.length
        var listOffset = total / 2
        var fenceOffset = total / 2
        storage.enumerateBlockSpecs { range, spec in
            if spec.isListItem, spec.listLevel >= 2, listOffset == total / 2 {
                listOffset = range.location + min(3, max(0, range.length - 1))
            }
            if spec.isCodeBlock, fenceOffset == total / 2 {
                fenceOffset = range.location + min(3, max(0, range.length - 1))
            }
        }
        return [
            ("doc start", 0),
            ("mid paragraph", total / 2),
            ("nested list item", listOffset),
            ("inside fence", fenceOffset),
            ("tail", max(0, total - 1))
        ]
    }

    // MARK: - cases

    @Test func mixedDocumentBaseline() throws {
        let markdown = BenchmarkFixtures.mixedDocument()
        let controller = try EditorController(initialMarkdown: markdown)
        controller.testSelection = NSRange(location: 0, length: 0)
        print("mixed fixture: \(markdown.utf16.count) utf16, storage \(controller.textStorage.length)")

        var samples: [Sample] = []

        // (a) platform-style keystroke at five positions.
        for (label, offset) in Self.probeOffsets(controller) {
            samples.append(Self.measure(
                "keystroke — \(label)",
                setup: { controller.testSelection = NSRange(location: offset, length: 0) },
                teardown: { Self.undoKeystroke(controller, at: offset) }
            ) { _ in
                Self.keystroke(controller, at: offset)
            })
        }

        // (a2) same keystroke with a subscriber that reads the tree —
        // the gate for incremental projection.
        do {
            var sink = 0
            let token = controller.addOnDocumentChange { change in
                sink &+= change.document.contentLength
            }
            let offset = controller.textStorage.length / 2
            samples.append(Self.measure(
                "keystroke — tree subscriber",
                iterations: 20,
                setup: { controller.testSelection = NSRange(location: offset, length: 0) },
                teardown: { Self.undoKeystroke(controller, at: offset) }
            ) { _ in
                Self.keystroke(controller, at: offset)
            })
            controller.removeObserver(token)
            precondition(sink >= 0)
        }

        // (c) command path.
        let mid = controller.textStorage.length / 2
        samples.append(Self.measure(
            "transaction — replaceText",
            setup: { controller.testSelection = NSRange(location: mid, length: 0) },
            teardown: {
                _ = controller.apply(Transaction(steps: [
                    .replaceText(range: NSRange(location: mid, length: 1),
                                 with: NSAttributedString(string: ""))
                ]))
            }
        ) { _ in
            _ = controller.apply(Transaction(steps: [
                .replaceText(range: NSRange(location: mid, length: 0),
                             with: NSAttributedString(string: "a"))
            ]))
        })

        // (d) markdown serialization.
        samples.append(Self.measure("markdown()", iterations: 20) { _ in
            _ = controller.markdown()
        })

        // (e) `document` on a cold cache.
        samples.append(Self.measure("document (cold)", iterations: 20, setup: {
            controller.invalidateDocumentCacheForBenchmark()
        }) { _ in
            _ = controller.document
        })

        Self.report("Mixed document (~1200 blocks)", samples)
    }

    @Test func longFenceBaseline() throws {
        let markdown = BenchmarkFixtures.longFenceDocument()
        let controller = try EditorController(initialMarkdown: markdown)
        print("long-fence fixture: \(markdown.utf16.count) utf16, storage \(controller.textStorage.length)")

        // (b) keystroke inside the 3000-line fence.
        let mid = controller.textStorage.length / 2
        let sample = Self.measure(
            "keystroke — inside 3000-line fence",
            iterations: 20,
            setup: { controller.testSelection = NSRange(location: mid, length: 0) },
            teardown: { Self.undoKeystroke(controller, at: mid) }
        ) { _ in
            Self.keystroke(controller, at: mid)
        }
        let mdSample = Self.measure("markdown()", iterations: 5) { _ in
            _ = controller.markdown()
        }
        let docSample = Self.measure("document (cold)", iterations: 5, setup: {
            controller.invalidateDocumentCacheForBenchmark()
        }) { _ in
            _ = controller.document
        }
        Self.report("Long fence (3000 lines)", [sample, mdSample, docSample])
    }
}
