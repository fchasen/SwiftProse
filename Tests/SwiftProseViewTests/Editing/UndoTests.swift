#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite(.serialized)
@MainActor
struct UndoTests {
    @Test func characterMutationUndoRestoresOriginal() {
        let harness = EditorHarness(markdown: "hello world\n")
        let preString = harness.string
        harness.step { _ = harness.controller.replaceText(in: NSRange(location: 5, length: 0), with: " brave") }
        #expect(harness.string == "hello brave world")
        harness.undo()
        #expect(harness.string == preString)
        #expect(harness.markdown == "hello world\n")
        harness.redo()
        #expect(harness.string == "hello brave world")
        #expect(harness.markdown == "hello brave world")
    }

    @Test func attributeMutationUndoRestoresAttributes() {
        let harness = EditorHarness(markdown: "hello world\n")
        harness.select(NSRange(location: 0, length: 5))
        harness.step { harness.controller.perform(.bold) }
        #expect(harness.markdown == "**hello** world")
        harness.undo()
        #expect(harness.markdown == "hello world\n")
    }

    @Test func attributeMutationLeavesCharactersIntactAcrossUndo() {
        let harness = EditorHarness(markdown: "hello world\n")
        let preString = harness.string
        harness.select(NSRange(location: 0, length: 5))
        harness.step { harness.controller.perform(.strikethrough) }
        #expect(harness.markdown == "~~hello~~ world")
        harness.select(harness.storage.length)
        harness.type(" more")
        let withTail = harness.string

        harness.undo()
        #expect(harness.string == preString)
        #expect(withTail == preString + " more")
        #expect(harness.storage.markdownInlineIntent(at: 0).contains(.strikethrough))
        harness.undo()
        #expect(harness.string == preString)
        #expect(!harness.storage.markdownInlineIntent(at: 0).contains(.strikethrough))
        #expect(harness.markdown == "hello world\n")
    }

    @Test func attributeMutationRedoRestoresMutation() {
        let harness = EditorHarness(markdown: "hello world\n")
        harness.select(NSRange(location: 0, length: 5))
        harness.step { harness.controller.perform(.bold) }
        harness.undo()
        harness.redo()
        #expect(harness.markdown == "**hello** world")
    }

    @Test func twoStackedAttributeMutationsUndoOneAtATime() {
        let harness = EditorHarness(markdown: "hello world\n")
        harness.select(NSRange(location: 0, length: 5))
        harness.step { harness.controller.perform(.bold) }
        harness.select(NSRange(location: 6, length: 5))
        harness.step { harness.controller.perform(.bold) }
        #expect(harness.markdown == "**hello world**")
        #expect(harness.storage.markdownInlineIntent(at: 5).isEmpty)
        harness.undo()
        #expect(harness.markdown == "**hello** world")
        harness.undo()
        #expect(harness.markdown == "hello world\n")
    }

    @Test func characterMutationOverEmptyRangeInsertsAndUndoes() {
        let editor = HeadlessEditor(markdown: "hello\n")
        #expect(editor.controller.replaceText(in: NSRange(location: 5, length: 0), with: "!"))
        #expect(editor.controller.markdown() == "hello!")
        editor.controller.undoManager.undo()
        #expect(editor.controller.markdown() == "hello\n")
    }
}

@Suite(.serialized)
@MainActor
struct UnifiedHistoryTests {
    private struct Seeded: RandomNumberGenerator {
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

    @Test func nonAdjacentTypingOpensNewGroup() {
        let harness = EditorHarness(markdown: "hello world\n")
        harness.select(11)
        harness.type("X")
        harness.select(0)
        harness.type("Y")
        #expect(harness.string == "Yhello worldX")
        harness.undo()
        #expect(harness.string == "hello worldX")
    }

    @Test func commandOpensFreshGroup() {
        let harness = EditorHarness(markdown: "hello\n")
        harness.select(5)
        harness.type("a")
        harness.step { harness.controller.perform(.heading(level: 2)) }
        #expect(harness.block(at: 0)?.headingLevel == 2)
        harness.undo()
        #expect(harness.block(at: 0) == .paragraph)
        #expect(harness.string == "helloa")
    }

    @Test func undoRestoresSelectionBeforeAndRedoRestoresAfter() {
        let harness = EditorHarness(markdown: "hello world\n")
        harness.select(5)
        harness.type("X")
        #expect(harness.selection.location == 6)
        harness.undo()
        #expect(harness.selection.location == 5)
        harness.redo()
        #expect(harness.selection.location == 6)
    }

    @Test func tableCellEditIsUndoable() {
        let harness = EditorHarness(markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        let before = harness.markdown
        harness.select(TableFixture.cellRange(harness.storage, row: 1, column: 0))
        harness.type("EDITED")
        #expect(harness.markdown.contains("EDITED"))
        harness.undo()
        #expect(!harness.markdown.contains("EDITED"))
        #expect(harness.markdown == before)
    }

    @Test func compositionCommitIsOneUndoEntry() {
        let harness = EditorHarness(markdown: "hi \n")
        let original = harness.string
        harness.select(harness.storage.length)
        harness.setMarkedText("n")
        harness.setMarkedText("ni")
        harness.step {
            harness.textView.insertText("\u{4ECA}", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.string == original + "\u{4ECA}")
        harness.undo()
        #expect(!harness.string.contains("\u{4ECA}"))
        while harness.undoManager.canUndo { harness.undo() }
        #expect(harness.string == original)
    }

    @Test func randomizedUndoFidelity() {
        var rng = Seeded(seed: 0xBEEF)
        for iteration in 0..<40 {
            let harness = EditorHarness(markdown: "alpha beta\n\ngamma delta\n")
            let initial = harness.string
            var ops: [String] = []

            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                let length = harness.storage.length
                guard length > 1 else { break }
                let at = Int.random(in: 0...(length - 1), using: &rng)
                switch Int.random(in: 0...3, using: &rng) {
                case 0:
                    ops.append("type@\(at)")
                    harness.select(at)
                    harness.type("x")
                case 1:
                    ops.append("del@\(at)")
                    harness.select(at + 1)
                    harness.deleteBackward()
                case 2:
                    ops.append("insert@\(at)")
                    harness.select(at)
                    harness.step { _ = harness.controller.insertMarkdown("yz") }
                default:
                    ops.append("heading@\(at)")
                    harness.select(at)
                    harness.step { harness.controller.perform(.heading(level: 3)) }
                }
                harness.settle()
            }

            var guardCount = 0
            while harness.undoManager.canUndo, guardCount < 64 {
                harness.undo()
                guardCount += 1
            }
            #expect(
                harness.string == initial,
                "iteration \(iteration) [\(ops.joined(separator: " | "))]: \(harness.string.debugDescription)"
            )
        }
    }
}
#endif
