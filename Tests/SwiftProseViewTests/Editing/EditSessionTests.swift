import Foundation
import Testing
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("EditSession snapshot", .serialized)
struct EditSessionSnapshotTests {
    private func makeController(_ text: String) -> EditorController {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let controller = EditorController(undoManager: undoManager)
        let storage = NSAttributedString(string: text, attributes: [.markdownBlock: MarkdownBlock.paragraph])
        controller.textStorage.setAttributedString(storage)
        undoManager.removeAllActions()
        return controller
    }

    @Test func characterEditUndoesAndRedoesWithSelection() {
        let controller = makeController("hello world\nnext\n")
        let session = EditSession(controller: controller)
        controller.setSelection(NSRange(location: 6, length: 5))
        let ok = session.perform(actionName: "Upper", ranges: [NSRange(location: 6, length: 5)], replacements: ["WORLD!"]) { storage in
            storage.replaceCharacters(in: NSRange(location: 6, length: 5), with: "WORLD!")
        }
        controller.setSelection(NSRange(location: 12, length: 0))
        #expect(ok)
        #expect(controller.textStorage.string == "hello WORLD!\nnext\n")
        #expect(controller.undoManager.undoActionName == "Upper")

        controller.undoManager.undo()
        #expect(controller.textStorage.string == "hello world\nnext\n")
        #expect(controller.currentSelection == NSRange(location: 6, length: 5))

        controller.undoManager.redo()
        #expect(controller.textStorage.string == "hello WORLD!\nnext\n")
        #expect(controller.currentSelection == NSRange(location: 12, length: 0))

        controller.undoManager.undo()
        #expect(controller.textStorage.string == "hello world\nnext\n")
    }

    @Test func attributeOnlyEditRestoresBlock() {
        let controller = makeController("title\nbody\n")
        let session = EditSession(controller: controller)
        let heading = MarkdownBlock(leaf: .heading(level: 1))
        session.perform(actionName: "Heading", ranges: [NSRange(location: 0, length: 6)], replacements: nil) { storage in
            storage.addAttribute(.markdownBlock, value: heading, range: NSRange(location: 0, length: 6))
        }
        #expect(controller.textStorage.markdownBlock(at: 0) == heading)
        controller.undoManager.undo()
        #expect(controller.textStorage.markdownBlock(at: 0) == .paragraph)
        controller.undoManager.redo()
        #expect(controller.textStorage.markdownBlock(at: 0) == heading)
    }

    @Test func multipleRangesUndoAsOneStep() {
        let controller = makeController("a\nb\nc\n")
        let session = EditSession(controller: controller)
        session.perform(
            actionName: "Wrap",
            ranges: [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)],
            replacements: ["A", "C"]
        ) { storage in
            storage.replaceCharacters(in: NSRange(location: 4, length: 1), with: "C")
            storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "A")
        }
        #expect(controller.textStorage.string == "A\nb\nC\n")
        controller.undoManager.undo()
        #expect(controller.textStorage.string == "a\nb\nc\n")
        #expect(!controller.undoManager.canUndo)
    }

    @Test func sessionIsPerformingDuringBodyAndProcessEditing() {
        let controller = makeController("x\n")
        let session = EditSession(controller: controller)
        let probe = ProcessEditingProbe(session: session)
        controller.textStorage.delegate = probe
        var duringBody = false
        session.perform(actionName: "Probe", ranges: [NSRange(location: 0, length: 1)], replacements: ["y"]) { storage in
            duringBody = session.isPerforming
            #expect(session.currentActionName == "Probe")
            storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "y")
        }
        #expect(duringBody)
        #expect(probe.observed == [true])
        #expect(!session.isPerforming)
        controller.undoManager.undo()
        #expect(probe.observed == [true, true])
    }

    @Test func nestedPerformAppliesInsideOuterStep() {
        let controller = makeController("ab\n")
        let session = EditSession(controller: controller)
        session.perform(actionName: "Outer", ranges: [NSRange(location: 0, length: 2)], replacements: nil) { storage in
            storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "A")
            session.perform(actionName: "Inner", ranges: [NSRange(location: 1, length: 1)], replacements: ["B"]) { inner in
                inner.replaceCharacters(in: NSRange(location: 1, length: 1), with: "B")
            }
        }
        #expect(controller.textStorage.string == "AB\n")
        #expect(controller.undoManager.undoActionName == "Outer")
        controller.undoManager.undo()
        #expect(controller.textStorage.string == "ab\n")
    }

    @Test func refusesWhenNotEditable() {
        let controller = makeController("x\n")
        controller.isEditable = false
        let session = EditSession(controller: controller)
        let ok = session.perform(actionName: "Edit", ranges: [NSRange(location: 0, length: 1)], replacements: ["y"]) { storage in
            storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "y")
        }
        #expect(!ok)
        #expect(controller.textStorage.string == "x\n")
        let forced = session.perform(
            actionName: "Toggle",
            ranges: [NSRange(location: 0, length: 1)],
            replacements: nil,
            ignoringEditability: true
        ) { storage in
            storage.addAttribute(.markdownBlock, value: MarkdownBlock(task: .checked), range: NSRange(location: 0, length: 2))
        }
        #expect(forced)
    }

    @Test @MainActor func undoRestoresVocabularyNormalizedDuringSnapshotEdit() {
        let editor = HeadlessEditor(markdown: "- one\n- two\n\nafter\n\nlast")
        let controller = editor.controller
        let original = controller.markdown()
        let blocks = controller.textStorage.markdownParagraphRanges().filter { $0.length > 0 }
            .map { controller.textStorage.markdownBlock(at: $0.location) }
        controller.insertMarkdown("x\n\ny", replacing: NSRange(location: 2, length: 0))
        let pasted = controller.markdown()
        #expect(pasted != original)

        controller.undoManager.undo()
        #expect(controller.markdown() == original)
        let restored = controller.textStorage.markdownParagraphRanges().filter { $0.length > 0 }
            .map { controller.textStorage.markdownBlock(at: $0.location) }
        #expect(restored == blocks)

        controller.undoManager.redo()
        #expect(controller.markdown() == pasted)
        controller.undoManager.undo()
        #expect(controller.markdown() == original)
    }

    @Test func mismatchedReplacementCountIsRejected() {
        let controller = makeController("x\n")
        let session = EditSession(controller: controller)
        let ok = session.perform(actionName: "Bad", ranges: [NSRange(location: 0, length: 1)], replacements: []) { _ in }
        #expect(!ok)
    }
}

final class ProcessEditingProbe: NSObject, NSTextStorageDelegate {
    let session: EditSession
    private(set) var observed: [Bool] = []

    init(session: EditSession) {
        self.session = session
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: PlatformTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        observed.append(session.isPerforming)
    }
}

#if canImport(AppKit) && os(macOS)
@Suite("EditSession hosted (macOS, .serialized)")
@MainActor
struct EditSessionHostedTests {
    @Test func attributeEditThroughTextViewUndoes() {
        let harness = EditorHarness(markdown: "", pipeline: .normalizer)
        harness.load(StorageBuilder.build {
            $0.paragraph("title")
            $0.paragraph("body", separator: false)
        })
        let session = EditSession(controller: harness.controller)
        let heading = MarkdownBlock(leaf: .heading(level: 2))
        harness.step {
            session.perform(actionName: "Heading 2", ranges: [NSRange(location: 0, length: 6)], replacements: nil) { storage in
                storage.addAttribute(.markdownBlock, value: heading, range: NSRange(location: 0, length: 6))
            }
        }
        #expect(harness.block(at: 0) == heading)
        #expect(harness.undoManager.undoActionName == "Heading 2")
        let headingFont = harness.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(headingFont == harness.controller.theme.headingFont(level: 2))

        harness.undo()
        #expect(harness.block(at: 0) == .paragraph)
        harness.redo()
        #expect(harness.block(at: 0) == heading)
        #expect(harness.isTextKit2)
    }

    @Test func characterEditThroughTextViewUndoesSeparatelyFromTyping() {
        let harness = EditorHarness(markdown: "", pipeline: .normalizer)
        harness.load(StorageBuilder.build { $0.paragraph("hello", separator: false) })
        harness.select(5)
        harness.type(" there")
        let session = EditSession(controller: harness.controller)
        harness.step {
            session.perform(actionName: "Shout", ranges: [NSRange(location: 0, length: 5)], replacements: ["HELLO"]) { storage in
                storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
            }
        }
        harness.select(11)
        harness.type("!")
        #expect(harness.string == "HELLO there!")
        harness.undo()
        #expect(harness.string == "HELLO there")
        harness.undo()
        #expect(harness.string == "hello there")
        harness.undo()
        #expect(harness.string == "hello")
    }

    @Test func markedTextIsCommittedBeforeEditing() {
        let harness = EditorHarness(markdown: "", pipeline: .normalizer)
        harness.load(StorageBuilder.build { $0.paragraph("ab", separator: false) })
        harness.select(2)
        harness.setMarkedText("か")
        #expect(harness.textView.hasMarkedText())
        let session = EditSession(controller: harness.controller)
        harness.step {
            session.perform(actionName: "Bold", ranges: [NSRange(location: 0, length: 1)], replacements: nil) { storage in
                storage.addIntent(.stronglyEmphasized, NSRange(location: 0, length: 1))
            }
        }
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.string == "abか")
    }

    @Test func refusedWhenTextViewIsReadOnly() {
        let harness = EditorHarness(markdown: "", pipeline: .normalizer)
        harness.load(StorageBuilder.build { $0.paragraph("x", separator: false) })
        harness.textView.isEditable = false
        harness.controller.isEditable = false
        let session = EditSession(controller: harness.controller)
        let ok = session.perform(actionName: "Edit", ranges: [NSRange(location: 0, length: 1)], replacements: ["y"]) { storage in
            storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "y")
        }
        #expect(!ok)
        #expect(harness.string == "x")
    }
}
#endif
