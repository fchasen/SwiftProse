import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct UndoTests {

    private func makeController(_ initial: String = "") throws -> EditorController {
        let c = try EditorController(initialMarkdown: initial)
        c.undoManager.groupsByEvent = false
        return c
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        AttributedMarkdownSerializer().serialize(storage)
    }

    @Test func characterMutationUndoRestoresOriginal() throws {
        let c = try makeController("hello world\n")
        let preString = c.textStorage.string
        c.withCharacterMutation(range: NSRange(location: 5, length: 0)) {
            c.textStorage.beginEditing()
            c.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " brave")
            c.textStorage.endEditing()
        }
        #expect(c.textStorage.string == "hello brave world\n")
        c.undoManager.undo()
        #expect(c.textStorage.string == preString)
        c.undoManager.redo()
        #expect(c.textStorage.string == "hello brave world\n")
    }

    /// Raw storage writes are the platform's typing path, so they are
    /// undoable in their own right now. Two edits, two undos, innermost
    /// first — the earlier mutation is untouched until its own undo.
    @Test func characterMutationAndLaterEditUndoIndependently() throws {
        let c = try makeController("hello world\n")
        c.withCharacterMutation(range: NSRange(location: 0, length: 5)) {
            c.textStorage.beginEditing()
            c.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
            c.textStorage.endEditing()
        }
        c.testSelection = NSRange(location: c.textStorage.length, length: 0)
        c.textStorage.beginEditing()
        c.textStorage.replaceCharacters(
            in: NSRange(location: c.textStorage.length, length: 0),
            with: "tail"
        )
        c.textStorage.endEditing()
        #expect(c.textStorage.string == "HELLO world\ntail")

        c.undoManager.undo()
        #expect(c.textStorage.string == "HELLO world\n",
                "the later edit undoes first, leaving the earlier one alone")
        c.undoManager.undo()
        #expect(c.textStorage.string == "hello world\n")
    }

    @Test func attributeMutationUndoRestoresAttributes() throws {
        let c = try makeController("hello world\n")
        c.withAttributeMutation(range: NSRange(location: 0, length: 5)) {
            _ = Operations.toggleBold(in: c.textStorage, range: NSRange(location: 0, length: 5), theme: .default)
        }
        #expect(serialize(c.textStorage) == "**hello** world\n")
        c.undoManager.undo()
        #expect(serialize(c.textStorage) == "hello world\n")
    }

    @Test func attributeMutationLeavesCharactersIntactAcrossUndo() throws {
        let c = try makeController("hello world\n")
        let preString = c.textStorage.string
        c.withAttributeMutation(range: NSRange(location: 0, length: 5)) {
            _ = Operations.toggleStrikethrough(in: c.textStorage, range: NSRange(location: 0, length: 5), theme: .default)
        }
        c.testSelection = NSRange(location: c.textStorage.length, length: 0)
        c.textStorage.beginEditing()
        c.textStorage.replaceCharacters(in: NSRange(location: c.textStorage.length, length: 0), with: " more")
        c.textStorage.endEditing()
        let withTail = c.textStorage.string

        // The tail is its own unit now; undo it first.
        c.undoManager.undo()
        #expect(c.textStorage.string == preString)
        #expect(withTail == preString + " more")
        // Now the attribute mutation, which leaves the characters alone.
        c.undoManager.undo()
        #expect(c.textStorage.string == preString,
                "attribute-only undo must not change character contents")
        let attrs = c.textStorage.attributes(at: 0, effectiveRange: nil)
        #expect(attrs[.strikethroughStyle] == nil)
    }

    @Test func attributeMutationRedoRestoresMutation() throws {
        let c = try makeController("hello world\n")
        c.withAttributeMutation(range: NSRange(location: 0, length: 5)) {
            _ = Operations.toggleBold(in: c.textStorage, range: NSRange(location: 0, length: 5), theme: .default)
        }
        c.undoManager.undo()
        c.undoManager.redo()
        #expect(serialize(c.textStorage) == "**hello** world\n")
    }

    @Test func twoStackedAttributeMutationsUndoOneAtATime() throws {
        let c = try makeController("hello world\n")
        c.withAttributeMutation(range: NSRange(location: 0, length: 5)) {
            _ = Operations.toggleBold(in: c.textStorage, range: NSRange(location: 0, length: 5), theme: .default)
        }
        c.withAttributeMutation(range: NSRange(location: 6, length: 5)) {
            _ = Operations.toggleBold(in: c.textStorage, range: NSRange(location: 6, length: 5), theme: .default)
        }
        #expect(serialize(c.textStorage) == "**hello** **world**\n")
        c.undoManager.undo()
        #expect(serialize(c.textStorage) == "**hello** world\n")
        c.undoManager.undo()
        #expect(serialize(c.textStorage) == "hello world\n")
    }

    @Test func characterMutationOverEmptyRangeInsertsAndUndoes() throws {
        let c = try makeController("hello\n")
        c.withCharacterMutation(range: NSRange(location: 5, length: 0)) {
            c.textStorage.beginEditing()
            c.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
            c.textStorage.endEditing()
        }
        #expect(c.textStorage.string == "hello!\n")
        c.undoManager.undo()
        #expect(c.textStorage.string == "hello\n")
    }
}

// MARK: - unified history (Stage 3.4)

@Suite(.serialized) struct UnifiedHistoryTests {

    private func makeController(_ initial: String = "") throws -> EditorController {
        let c = try EditorController(initialMarkdown: initial)
        var now: TimeInterval = 1000
        c.historyClock = { now }
        c.testClockAdvance = { now += $0 }
        return c
    }

    /// One platform keystroke.
    private func type(_ c: EditorController, _ text: String, at location: Int, hint: EditHint? = .typing) {
        let storage = c.textStorage
        c.testSelection = NSRange(location: location, length: 0)
        c.nextEditHint = hint
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: text)
        c.testSelection = NSRange(location: location + (text as NSString).length, length: 0)
        storage.endEditing()
    }

    private func delete(_ c: EditorController, range: NSRange) {
        let storage = c.textStorage
        c.testSelection = NSRange(location: range.location + range.length, length: 0)
        c.nextEditHint = .deletion
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: "")
        c.testSelection = NSRange(location: range.location, length: 0)
        storage.endEditing()
    }

    @Test func typingCoalescesWithinNewGroupDelay() throws {
        let c = try makeController("hello\n")
        for (i, ch) in "abc".enumerated() {
            type(c, String(ch), at: 5 + i)
            c.testClockAdvance?(0.05)
        }
        #expect(c.textStorage.string.hasPrefix("helloabc"))
        c.undoManager.undo()
        #expect(c.textStorage.string.hasPrefix("hello\n"),
                "one undo removes the whole burst, got \(c.textStorage.string.debugDescription)")
    }

    @Test func typingSplitsAfterNewGroupDelay() throws {
        let c = try makeController("hello\n")
        type(c, "a", at: 5)
        c.testClockAdvance?(0.05)
        type(c, "b", at: 6)
        c.testClockAdvance?(5.0)   // well past newGroupDelay
        type(c, "c", at: 7)
        #expect(c.textStorage.string.hasPrefix("helloabc"))
        c.undoManager.undo()
        #expect(c.textStorage.string.hasPrefix("helloab"),
                "the pause started a new group, got \(c.textStorage.string.debugDescription)")
        c.undoManager.undo()
        #expect(c.textStorage.string.hasPrefix("hello\n"))
    }

    @Test func nonAdjacentTypingOpensNewGroup() throws {
        let c = try makeController("hello world\n")
        type(c, "X", at: 11)      // after "world"
        c.testClockAdvance?(0.05)
        type(c, "Y", at: 0)       // jump to the start — not adjacent
        #expect(c.textStorage.string.hasPrefix("Yhello worldX"))
        c.undoManager.undo()
        #expect(c.textStorage.string.hasPrefix("hello worldX"),
                "a jump starts a new group however fast you type")
    }

    @Test func backspaceJoinsTypingGroup() throws {
        let c = try makeController("hello\n")
        type(c, "a", at: 5)
        c.testClockAdvance?(0.05)
        type(c, "b", at: 6)
        c.testClockAdvance?(0.05)
        delete(c, range: NSRange(location: 6, length: 1))
        #expect(c.textStorage.string.hasPrefix("helloa"))
        c.undoManager.undo()
        #expect(c.textStorage.string.hasPrefix("hello\n"),
                "the deletion joined the burst, got \(c.textStorage.string.debugDescription)")
    }

    @Test func correctionJoinsTypingGroup() throws {
        let c = try makeController("\n")
        for (i, ch) in "teh".enumerated() { type(c, String(ch), at: i); c.testClockAdvance?(0.05) }
        // Autocorrect rewrites the word while the caret sits after it.
        c.testSelection = NSRange(location: 3, length: 0)
        c.nextEditHint = .correction
        c.textStorage.beginEditing()
        c.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "the")
        c.textStorage.endEditing()
        #expect(c.textStorage.string.hasPrefix("the"))
        c.undoManager.undo()
        #expect(c.textStorage.string.hasPrefix("\n") || c.textStorage.string.isEmpty,
                "one undo reverts the whole word, got \(c.textStorage.string.debugDescription)")
    }

    @Test func commandOpensFreshGroup() throws {
        let c = try makeController("hello\n")
        type(c, "a", at: 5)
        c.testClockAdvance?(0.05)
        let line = (c.textStorage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        _ = c.apply(Transaction(steps: [.setSpec(lineRange: line, BlockSpec(kind: .heading(level: 2)))]))
        #expect(c.textStorage.blockSpec(at: 0)?.kind == .heading(level: 2))
        c.undoManager.undo()
        #expect(c.textStorage.blockSpec(at: 0)?.kind == .paragraph,
                "the command is its own group")
        #expect(c.textStorage.string.hasPrefix("helloa"), "the typing survives")
    }

    @Test func closeHistoryGroupSplitsTyping() throws {
        let c = try makeController("hello\n")
        type(c, "a", at: 5)
        c.closeHistoryGroup()
        type(c, "b", at: 6)
        c.undoManager.undo()
        #expect(c.textStorage.string.hasPrefix("helloa"),
                "closeHistoryGroup ends the burst")
    }

    @Test func undoRestoresSelectionBeforeAndRedoRestoresAfter() throws {
        let c = try makeController("hello world\n")
        c.testSelection = NSRange(location: 5, length: 0)
        type(c, "X", at: 5)
        #expect(c.currentSelection.location == 6)
        c.undoManager.undo()
        #expect(c.currentSelection.location == 5, "undo puts the caret back where the edit started")
        c.undoManager.redo()
        #expect(c.currentSelection.location == 6, "redo puts it back after the edit")
    }

    @Test func transactionUndoPreservesNodeIDs() throws {
        let c = try makeController("hello\n\nworld\n")
        let before = c.document
        guard case .structural(_, let kidsBefore) = before.root else {
            Issue.record("expected structural root"); return
        }
        let idsBefore = kidsBefore.compactMap { $0.node?.id }

        c.testSelection = NSRange(location: 0, length: 0)
        _ = c.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 0, length: 5),
                         with: NSAttributedString(string: "HELLO"))
        ]))
        c.undoManager.undo()

        guard case .structural(_, let kidsAfter) = c.document.root else {
            Issue.record("expected structural root"); return
        }
        let idsAfter = kidsAfter.compactMap { $0.node?.id }
        #expect(idsBefore == idsAfter, "the pre-image restores node identity, not just text")
        #expect(c.textStorage.string.hasPrefix("hello"))
    }

    @Test func tableCellEditIsUndoable() throws {
        let c = try makeController("| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        let before = c.markdown()
        #expect(before.contains("1"))

        var tableRange: NSRange?
        c.textStorage.enumerateNodePaths { range, path in
            if tableRange == nil, path.leaf?.type == "table" { tableRange = range }
        }
        let range = try #require(tableRange)
        _ = c.applyTableCellEdit(tableRange: range, row: 1, column: 0, text: "EDITED")
        #expect(c.markdown().contains("EDITED"), "the cell edit landed")

        c.undoManager.undo()
        #expect(!c.markdown().contains("EDITED"),
                "table-cell undo used to be a no-op; got \(c.markdown().debugDescription)")
        #expect(c.markdown() == before)
    }

    @Test func multiStepTransactionInverseAppliesSequentially() throws {
        // The `[insert @10, insert @0]` case: mapping the second inverse
        // through the first would delete the wrong two characters.
        let c = try makeController("0123456789abcdef\n")
        let original = c.textStorage.string
        c.testSelection = NSRange(location: 0, length: 0)
        _ = c.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 10, length: 0),
                         with: NSAttributedString(string: "AB")),
            .replaceText(range: NSRange(location: 0, length: 0),
                         with: NSAttributedString(string: "C"))
        ]))
        #expect(c.textStorage.string.hasPrefix("C0123456789AB"))
        c.undoManager.undo()
        #expect(c.textStorage.string == original,
                "sequential replay, got \(c.textStorage.string.debugDescription)")
    }

    @Test func compositionCommitIsOneUndoEntry() throws {
        let c = try makeController("hi \n")
        let original = c.textStorage.string

        func compose(_ replacing: NSRange, _ text: String, marked: Bool) {
            c.testSelection = NSRange(location: replacing.location, length: 0)
            c.testMarkedText = marked
            c.nextEditHint = .composition
            c.textStorage.beginEditing()
            c.textStorage.replaceCharacters(in: replacing, with: text)
            c.testSelection = NSRange(location: replacing.location + (text as NSString).length, length: 0)
            c.textStorage.endEditing()
        }
        compose(NSRange(location: 3, length: 0), "n", marked: true)
        compose(NSRange(location: 3, length: 1), "ni", marked: true)
        compose(NSRange(location: 3, length: 2), "\u{4ECA}", marked: false)

        #expect(c.textStorage.string.hasPrefix("hi \u{4ECA}"))
        c.undoManager.undo()
        #expect(c.textStorage.string == original,
                "one undo for the whole composition, got \(c.textStorage.string.debugDescription)")
    }

    @Test func undoInputRuleLeavesTypedSource() throws {
        let c = try makeController("")
        for (i, ch) in "# ".enumerated() {
            type(c, String(ch), at: i)
            c.testClockAdvance?(0.05)
        }
        #expect(c.textStorage.blockSpec(at: 0)?.kind == .heading(level: 1))
        #expect(c.undoInputRule(), "backspace right after the rule undoes the rule")
        #expect(c.textStorage.blockSpec(at: 0)?.kind == .paragraph,
                "the typed '# ' survives as a paragraph")
    }

    @Test func randomizedUndoFidelity() throws {
        var rng = PositionSpaceTests.Seeded(seed: 0xBEEF)
        for iteration in 0..<40 {
            let c = try makeController("alpha beta\n\ngamma delta\n")
            let initial = c.textStorage.attributedSubstring(
                from: NSRange(location: 0, length: c.textStorage.length))
            var undos = 0
            var ops: [String] = []

            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                let len = c.textStorage.length
                guard len > 1 else { break }
                switch Int.random(in: 0...3, using: &rng) {
                case 0:
                    let at = Int.random(in: 0...(len - 1), using: &rng)
                    ops.append("type@\(at)")
                    type(c, "x", at: at)
                case 1:
                    let at = Int.random(in: 0...(len - 1), using: &rng)
                    ops.append("del@\(at)")
                    delete(c, range: NSRange(location: at, length: 1))
                case 2:
                    let at = Int.random(in: 0...(len - 1), using: &rng)
                    ops.append("insert@\(at)")
                    c.testSelection = NSRange(location: at, length: 0)
                    _ = c.insert(text: "yz")
                default:
                    let at = Int.random(in: 0...(len - 1), using: &rng)
                    let line = (c.textStorage.string as NSString)
                        .paragraphRange(for: NSRange(location: at, length: 0))
                    ops.append("setSpec@\(at)")
                    c.testSelection = NSRange(location: at, length: 0)
                    _ = c.apply(Transaction(steps: [
                        .setSpec(lineRange: line, BlockSpec(kind: .heading(level: 3)))
                    ]))
                }
                c.testClockAdvance?(5.0)   // every step is its own group
                undos += 1
            }

            var guardCount = 0
            while c.undoManager.canUndo, guardCount < 64 {
                c.undoManager.undo()
                guardCount += 1
            }
            let final = c.textStorage.attributedSubstring(
                from: NSRange(location: 0, length: c.textStorage.length))
            let detail = "iteration \(iteration), \(undos) edits [\(ops.joined(separator: " | "))]: "
                + "\(final.string.debugDescription) != \(initial.string.debugDescription)"
            #expect(final.string == initial.string, "\(detail)")
        }
    }
}
