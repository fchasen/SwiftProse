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

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTPROSE_BENCH"] != nil)
)
@MainActor
struct KeystrokeBenchmarkTests {

    struct Sample {
        let name: String
        let medianMicros: Double
        let p90Micros: Double
        let blocksPerOp: Double
    }

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

    static func keystroke(_ controller: EditorController, at location: Int) {
        let storage = controller.textStorage
        let safe = max(0, min(location, storage.length))
        let range = NSRange(location: safe, length: 0)
        controller.setSelection(range)
        let attributes = controller.typingAttributes(at: safe)
        _ = controller.shouldChangeText(in: range, replacement: "a")
        storage.replaceCharacters(in: range, with: NSAttributedString(string: "a", attributes: attributes))
        controller.setSelection(NSRange(location: safe + 1, length: 0))
        controller.flushDocumentChanges()
        controller.drainDeferredEdits()
    }

    static func undoKeystroke(_ controller: EditorController, at location: Int) {
        let storage = controller.textStorage
        let safe = max(0, min(location, storage.length - 1))
        let range = NSRange(location: safe, length: 1)
        _ = controller.shouldChangeText(in: range, replacement: "")
        storage.replaceCharacters(in: range, with: "")
        controller.setSelection(NSRange(location: safe, length: 0))
        controller.flushDocumentChanges()
        controller.drainDeferredEdits()
    }

    static func probeOffsets(_ controller: EditorController) -> [(String, Int)] {
        let storage = controller.textStorage
        let total = storage.length
        var listOffset = total / 2
        var fenceOffset = total / 2
        for range in storage.markdownParagraphRanges() where range.length > 0 {
            guard let block = storage.markdownBlock(at: range.location) else { continue }
            if block.listDepth >= 3, listOffset == total / 2 {
                listOffset = range.location + min(3, max(0, range.length - 1))
            }
            if block.isCode, fenceOffset == total / 2 {
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

    static func controller(_ markdown: String) -> EditorController {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return EditorController(markdown: markdown, undoManager: undoManager)
    }

    @Test func mixedDocumentBaseline() {
        let markdown = BenchmarkFixtures.mixedDocument()
        let controller = Self.controller(markdown)
        print("mixed fixture: \(markdown.utf16.count) utf16, storage \(controller.textStorage.length)")

        var samples: [Sample] = []

        for (label, offset) in Self.probeOffsets(controller) {
            samples.append(Self.measure(
                "keystroke — \(label)",
                teardown: { Self.undoKeystroke(controller, at: offset) }
            ) { _ in
                Self.keystroke(controller, at: offset)
            })
        }

        do {
            var sink = 0
            let token = controller.addOnDocumentChange { change in
                sink &+= change.editedRange.length
            }
            let offset = controller.textStorage.length / 2
            samples.append(Self.measure(
                "keystroke — change subscriber",
                iterations: 20,
                teardown: { Self.undoKeystroke(controller, at: offset) }
            ) { _ in
                Self.keystroke(controller, at: offset)
            })
            controller.removeObserver(token)
            precondition(sink >= 0)
        }

        do {
            var pushes = 0
            controller.textSink = { _ in pushes += 1 }
            let offset = controller.textStorage.length / 2
            samples.append(Self.measure(
                "keystroke — bound sink, push deferred",
                teardown: { Self.undoKeystroke(controller, at: offset) }
            ) { _ in
                Self.keystroke(controller, at: offset)
            })
            controller.flushPendingBinding()
            samples.append(Self.measure(
                "keystroke + flushPendingBinding",
                iterations: 20,
                teardown: {
                    Self.undoKeystroke(controller, at: offset)
                    controller.flushPendingBinding()
                }
            ) { _ in
                Self.keystroke(controller, at: offset)
                controller.flushPendingBinding()
            })
            controller.textSink = nil
            controller.cancelBindingPush()
            precondition(pushes > 0)
        }

        let mid = controller.textStorage.length / 2
        samples.append(Self.measure(
            "insertMarkdown",
            setup: { controller.setSelection(NSRange(location: mid, length: 0)) },
            teardown: { controller.undoManager.undo() }
        ) { _ in
            _ = controller.insertMarkdown("a")
        })

        samples.append(Self.measure("markdown() — edited back to load", iterations: 20) { _ in
            _ = controller.markdown()
        })

        do {
            let offset = controller.textStorage.length / 2
            samples.append(Self.measure(
                "markdown() — edited",
                setup: { Self.keystroke(controller, at: offset) },
                teardown: { Self.undoKeystroke(controller, at: offset) }
            ) { _ in
                _ = controller.markdown()
            })
            samples.append(Self.measure(
                "serialize() — spliced after keystroke",
                setup: { Self.keystroke(controller, at: offset) },
                teardown: {
                    Self.undoKeystroke(controller, at: offset)
                    _ = controller.serialize()
                }
            ) { _ in
                _ = controller.serialize()
            })
        }

        do {
            let fresh = Self.controller(markdown)
            samples.append(Self.measure("markdown() — unedited", iterations: 20) { _ in
                _ = fresh.markdown()
            })
        }

        samples.append(Self.measure("MarkdownLoader.load", iterations: 10) { _ in
            _ = MarkdownLoader().load(markdown)
        })

        let loaded = MarkdownLoader().load(markdown)
        samples.append(Self.measure("MarkdownWriter.markdown(from:)", iterations: 20) { _ in
            _ = MarkdownWriter().markdown(from: loaded)
        })

        Self.report("Mixed document (~1200 blocks)", samples)
    }

    @Test func longFenceBaseline() {
        let markdown = BenchmarkFixtures.longFenceDocument()
        let controller = Self.controller(markdown)
        print("long-fence fixture: \(markdown.utf16.count) utf16, storage \(controller.textStorage.length)")

        let mid = controller.textStorage.length / 2
        let sample = Self.measure(
            "keystroke — inside 3000-line fence",
            iterations: 20,
            teardown: { Self.undoKeystroke(controller, at: mid) }
        ) { _ in
            Self.keystroke(controller, at: mid)
        }
        let mdSample = Self.measure("markdown()", iterations: 5) { _ in
            _ = controller.markdown()
        }
        let loadSample = Self.measure("MarkdownLoader.load", iterations: 5) { _ in
            _ = MarkdownLoader().load(markdown)
        }
        let loaded = MarkdownLoader().load(markdown)
        let writeSample = Self.measure("MarkdownWriter.markdown(from:)", iterations: 5) { _ in
            _ = MarkdownWriter().markdown(from: loaded)
        }
        Self.report("Long fence (3000 lines)", [sample, mdSample, loadSample, writeSample])
    }
}
