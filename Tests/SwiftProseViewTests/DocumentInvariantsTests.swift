import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

/// Structural rules that span a run of blocks, not one line — the class of
/// bug a line-local repair pass is blind to.
@Suite(.serialized) struct DocumentInvariantsTests {

    /// A platform edit: raw storage write with a caret, exactly what the
    /// text view does.
    private func edit(
        _ c: EditorController,
        replacing range: NSRange,
        with text: String,
        hint: EditHint? = nil
    ) {
        let storage = c.textStorage
        c.testSelection = NSRange(location: range.location, length: 0)
        c.nextEditHint = hint
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        c.testSelection = NSRange(location: range.location + (text as NSString).length, length: 0)
        storage.endEditing()
        c.drainPendingEnvelopes()
    }

    private func lineRange(_ c: EditorController, containing location: Int) -> NSRange {
        (c.textStorage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
    }

    // MARK: - ordered list renumbering

    @Test func orderedListRenumbersAfterDeleteFirstItem() throws {
        let c = try EditorController(initialMarkdown: "1. one\n2. two\n3. three\n")
        edit(c, replacing: lineRange(c, containing: 0), with: "", hint: .deletion)
        #expect(c.markdown() == "1. two\n2. three",
                "got \(c.markdown().debugDescription)")
    }

    @Test func orderedListRenumbersAfterDeleteMiddleItem() throws {
        let c = try EditorController(initialMarkdown: "1. one\n2. two\n3. three\n")
        let second = (c.textStorage.string as NSString).range(of: "two")
        edit(c, replacing: lineRange(c, containing: second.location), with: "", hint: .deletion)
        #expect(c.markdown() == "1. one\n2. three",
                "got \(c.markdown().debugDescription)")
    }

    @Test func orderedListRenumbersAfterSplit() throws {
        let c = try EditorController(initialMarkdown: "1. one\n2. two\n3. three\n")
        let ns = c.textStorage.string as NSString
        let target = ns.range(of: "two")
        c.testSelection = NSRange(location: target.location + target.length, length: 0)
        _ = c.handleNewline()
        let md = c.markdown()
        #expect(md.contains("1. one"))
        #expect(md.contains("2. two"))
        #expect(md.contains("4. three"), "the split renumbered the tail; got \(md.debugDescription)")
    }

    @Test func orderedListRenumbersAcrossMultiParagraphSelectionDelete() throws {
        let c = try EditorController(initialMarkdown: "1. one\n2. two\n3. three\n4. four\n")
        // Select and delete items 1 and 2 in one edit.
        let start = lineRange(c, containing: 0).location
        let secondLine = lineRange(c, containing: lineRange(c, containing: 0).length)
        let span = NSRange(location: start, length: secondLine.location + secondLine.length - start)
        edit(c, replacing: span, with: "", hint: .deletion)
        #expect(c.markdown() == "1. three\n2. four",
                "got \(c.markdown().debugDescription)")
    }

    @Test func nestedOrderedListsRenumberIndependently() throws {
        let c = try EditorController(initialMarkdown:
            "1. one\n   1. inner a\n   2. inner b\n2. two\n")
        let inner = (c.textStorage.string as NSString).range(of: "inner a")
        edit(c, replacing: lineRange(c, containing: inner.location), with: "", hint: .deletion)
        let md = c.markdown()
        #expect(md.contains("1. one"), "got \(md.debugDescription)")
        #expect(md.contains("1. inner b"), "the nested list renumbers on its own; got \(md.debugDescription)")
        #expect(md.contains("2. two"), "the outer list is untouched; got \(md.debugDescription)")
    }

    @Test func bulletListInterruptsOrderedNumbering() throws {
        let c = try EditorController(initialMarkdown: "1. one\n2. two\n")
        // Typing in the list must not renumber it into something else.
        let two = (c.textStorage.string as NSString).range(of: "two")
        edit(c, replacing: NSRange(location: two.location + two.length, length: 0), with: "!", hint: .typing)
        #expect(c.markdown() == "1. one\n2. two!", "got \(c.markdown().debugDescription)")
    }

    // MARK: - level and depth clamping

    @Test func listLevelNeverJumpsByMoreThanOne() throws {
        let c = try EditorController(initialMarkdown: "- one\n- two\n")
        let ns = c.textStorage.string as NSString
        let two = ns.range(of: "two")
        let line = lineRange(c, containing: two.location)
        // Force an orphaned level-3 item directly into storage.
        c.proseStorage.withOrigin(.load) {
            c.textStorage.setBlockSpec(
                BlockSpec(kind: .unorderedListItem, blockquoteDepth: 0, listLevel: 3),
                in: line
            )
        }
        #expect(c.textStorage.blockSpec(at: line.location)?.listLevel == 3)

        // Any edit in the run brings it back in line.
        edit(c, replacing: NSRange(location: two.location + two.length, length: 0), with: "x", hint: .typing)
        let after = c.textStorage.blockSpec(at: lineRange(c, containing: two.location).location)
        #expect(after?.listLevel == 1,
                "a level-3 item after a level-0 item is an orphan; got \(String(describing: after))")
    }

    @Test func blockquoteDepthStaysContinuous() throws {
        let c = try EditorController(initialMarkdown: "> one\n> two\n")
        let ns = c.textStorage.string as NSString
        let two = ns.range(of: "two")
        let line = lineRange(c, containing: two.location)
        c.proseStorage.withOrigin(.load) {
            c.textStorage.setBlockSpec(
                BlockSpec(kind: .paragraph, blockquoteDepth: 4),
                in: line
            )
        }
        edit(c, replacing: NSRange(location: two.location + two.length, length: 0), with: "x", hint: .typing)
        let after = c.textStorage.blockSpec(at: lineRange(c, containing: two.location).location)
        #expect(after?.blockquoteDepth == 2,
                "depth may exceed the line above by one, no more; got \(String(describing: after))")
    }

    @Test func documentMayOpenAtDepthTwo() throws {
        let c = try EditorController(initialMarkdown: "> > deep\n")
        #expect(c.textStorage.blockSpec(at: 0)?.blockquoteDepth == 2)
        edit(c, replacing: NSRange(location: c.textStorage.length - 1, length: 0), with: "x", hint: .typing)
        #expect(c.textStorage.blockSpec(at: 0)?.blockquoteDepth == 2,
                "the first line of a run establishes its own depth")
    }

    // MARK: - undo

    @Test func invariantsJoinTheTriggeringUndoGroup() throws {
        let c = try EditorController(initialMarkdown: "1. one\n2. two\n3. three\n")
        let before = c.markdown()
        edit(c, replacing: lineRange(c, containing: 0), with: "", hint: .deletion)
        #expect(c.markdown() == "1. two\n2. three")

        c.undoManager.undo()
        #expect(c.markdown() == before,
                "one undo takes back the deletion and the renumbering; got \(c.markdown().debugDescription)")
    }

    // MARK: - run discovery

    @Test func structuralRunStopsAtAPlainParagraph() throws {
        let c = try EditorController(initialMarkdown: "1. a\n1. b\n\nbreak\n\n1. c\n1. d\n")
        // Both lists number from 1 independently — the paragraph between
        // them ends the run.
        let md = c.markdown()
        let firstList = md.range(of: "1. a")
        #expect(firstList != nil, "got \(md.debugDescription)")
        #expect(md.contains("2. b"), "got \(md.debugDescription)")
        #expect(md.contains("1. c"), "the second list restarts; got \(md.debugDescription)")
        #expect(md.contains("2. d"), "got \(md.debugDescription)")
    }
}
