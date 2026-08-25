import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct EnvelopeValidationTests {

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

    @Test func insertedCharsInheritCaretParagraphSpec() throws {
        let c = try EditorController(initialMarkdown: "# Title\n\nbody\n")
        let ns = c.textStorage.string as NSString
        let at = ns.range(of: "Title").location + 2
        edit(c, replacing: NSRange(location: at, length: 0), with: "X", hint: .typing)
        #expect(c.textStorage.blockSpec(at: at)?.kind == .heading(level: 1),
                "a character typed into a heading is part of that heading")
        #expect(c.markdown().hasPrefix("# TiXtle"), "got \(c.markdown().debugDescription)")
    }

    @Test func multiLineInsertStampsEveryLine() throws {
        let c = try EditorController(initialMarkdown: "start\n")
        edit(c, replacing: NSRange(location: 5, length: 0), with: "\nsecond\nthird", hint: .bulk)
        for i in 0..<c.textStorage.length {
            #expect(c.textStorage.nodePath(at: i) != nil, "character \(i) has no structure")
        }
        #expect(c.markdown() == "start\n\nsecond\n\nthird",
                "each inserted line is its own paragraph; got \(c.markdown().debugDescription)")
    }

    @Test func insertedLinesGetDistinctNodes() throws {
        let c = try EditorController(initialMarkdown: "start\n")
        edit(c, replacing: NSRange(location: 5, length: 0), with: "\nsecond\nthird", hint: .bulk)
        var ids: [NodeID] = []
        c.textStorage.enumerateNodePaths { _, path in
            if let leaf = path.leaf { ids.append(leaf.id) }
        }
        #expect(ids.count == Set(ids).count,
                "a node must not span two blocks; got \(ids.count) runs, \(Set(ids).count) distinct")
    }

    @Test func demotionIsUndoneWithTheKeystroke() throws {
        // Emptying a heading demotes it to a paragraph. Undoing the
        // deletion must bring the heading back, not leave a plain line.
        let c = try EditorController(initialMarkdown: "# Title\n\nbody\n")
        let ns = c.textStorage.string as NSString
        let title = ns.range(of: "Title")
        edit(c, replacing: title, with: "", hint: .deletion)
        #expect(c.textStorage.blockSpec(at: 0)?.kind == .paragraph, "emptied heading demotes")

        c.undoManager.undo()
        #expect(c.markdown().hasPrefix("# Title"),
                "one undo restores the text and the heading; got \(c.markdown().debugDescription)")
    }

    @Test func trailingParagraphReinsertedAndUndone() throws {
        let c = try EditorController(initialMarkdown: "para\n")
        let before = c.textStorage.length
        // Type at the tail of a document ending in a code fence so the
        // trailing-paragraph rule fires.
        let c2 = try EditorController(initialMarkdown: "```\ncode\n```\n")
        let lengthBefore = c2.textStorage.length
        edit(c2, replacing: NSRange(location: max(0, lengthBefore - 1), length: 0), with: "x", hint: .typing)
        #expect(c2.textStorage.length > lengthBefore)
        c2.undoManager.undo()
        #expect(c2.textStorage.length == lengthBefore,
                "the keystroke and the trailing paragraph it caused undo together")
        #expect(before == c.textStorage.length)
    }

    @Test func transactionCorruptionEmitsDiagnosticWithoutRepair() throws {
        let c = try EditorController(initialMarkdown: "alpha\nbeta\n")
        c.assertsOnDiagnostics = false
        var captured: [SpecDiagnostic] = []
        c.onDiagnostic = { captured.append($0) }

        let corrupted = NSMutableAttributedString(string: "gamma\n")
        corrupted.setNodePath(NodePath.fromBlockSpec(BlockSpec(kind: .heading(level: 2))),
                              in: NSRange(location: 0, length: 3))
        corrupted.setNodePath(NodePath.fromBlockSpec(BlockSpec(kind: .paragraph)),
                              in: NSRange(location: 3, length: 3))
        c.testSelection = NSRange(location: 0, length: 0)
        _ = c.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 0, length: 6), with: corrupted)
        ]))

        #expect(!captured.isEmpty, "the validator reports it")
        // And does not silently rewrite the buffer.
        #expect(c.textStorage.string.hasPrefix("gamma"))
    }

    @Test func noDiagnosticsAcrossOrdinaryEditing() throws {
        let c = try EditorController(initialMarkdown: "# Title\n\n- one\n- two\n\n> quote\n\npara\n")
        var captured: [SpecDiagnostic] = []
        c.onDiagnostic = { captured.append($0) }

        // Type, delete, and run a command across the document.
        edit(c, replacing: NSRange(location: 3, length: 0), with: "X", hint: .typing)
        edit(c, replacing: NSRange(location: 3, length: 1), with: "", hint: .deletion)
        let tail = c.textStorage.length
        edit(c, replacing: NSRange(location: max(0, tail - 1), length: 0), with: "!", hint: .typing)
        c.testSelection = NSRange(location: 0, length: 0)
        let line = (c.textStorage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        _ = c.apply(Transaction(steps: [.setSpec(lineRange: line, BlockSpec(kind: .heading(level: 3)))]))

        #expect(captured.isEmpty, "the validator stays silent on ordinary editing; got \(captured)")
    }
}
