import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

@Suite(.serialized) struct EnvelopeClassificationTests {

    /// Drive a platform edit with an explicit hint, the way a delegate does.
    @discardableResult
    private func edit(
        _ controller: EditorController,
        replacing range: NSRange,
        with text: String,
        hint: EditHint?,
        selectionBefore: NSRange? = nil,
        marked: Bool = false
    ) -> [EditorController.EditClass] {
        var classes: [EditorController.EditClass] = []
        let previous = controller.classificationProbe
        controller.classificationProbe = { classes.append($0) }
        defer { controller.classificationProbe = previous }

        controller.testSelection = selectionBefore ?? range
        controller.testMarkedText = marked
        controller.nextEditHint = hint
        let storage = controller.textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        controller.testSelection = NSRange(location: range.location + (text as NSString).length, length: 0)
        storage.endEditing()
        controller.drainPendingEnvelopes()
        return classes
    }

    @Test func singleCharAtCaretIsTyping() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let classes = edit(controller, replacing: NSRange(location: 5, length: 0), with: "!", hint: .typing)
        #expect(classes == [.typing])
    }

    @Test func multiCharIsBulk() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let classes = edit(controller, replacing: NSRange(location: 5, length: 0), with: " world", hint: .bulk)
        #expect(classes == [.bulk])
    }

    @Test func emptyReplacementIsDeletion() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let classes = edit(controller, replacing: NSRange(location: 4, length: 1), with: "", hint: .deletion)
        #expect(classes == [.deletion])
    }

    @Test func hintCorrectionClassifiesCorrection() throws {
        let controller = try EditorController(initialMarkdown: "teh cat\n")
        // Autocorrect rewrites "teh" while the caret sits after the space.
        let classes = edit(
            controller,
            replacing: NSRange(location: 0, length: 3),
            with: "the",
            hint: .correction,
            selectionBefore: NSRange(location: 4, length: 0)
        )
        #expect(classes == [.correction])
    }

    @Test func typingHintWithBiggerRecordFallsBackToBulk() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        // Storage is the truth: a stale `.typing` hint can't make a
        // three-character insert into a keystroke.
        let classes = edit(controller, replacing: NSRange(location: 5, length: 0), with: "abc", hint: .typing)
        #expect(classes == [.bulk])
    }

    @Test func unhintedSingleCharIsTyping() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let classes = edit(controller, replacing: NSRange(location: 5, length: 0), with: "!", hint: nil)
        #expect(classes == [.typing])
    }

    @Test func unhintedDeletionIsDeletion() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let classes = edit(controller, replacing: NSRange(location: 4, length: 1), with: "", hint: nil)
        #expect(classes == [.deletion])
    }

    @Test func markedInterimIsDroppedAndBaselineRecorded() throws {
        let controller = try EditorController(initialMarkdown: "hi \n")
        var published = 0
        controller.onDocumentChange = { _ in published += 1 }

        let classes = edit(
            controller,
            replacing: NSRange(location: 3, length: 0),
            with: "n",
            hint: .composition,
            marked: true
        )
        #expect(classes == [.compositionInterim])
        #expect(published == 0, "interim composition is not content")
        #expect(controller.compositionBaseline != nil)
        #expect(controller.compositionBaseline?.range == NSRange(location: 3, length: 0))
    }

    @Test func compositionCommitCollapsesToBaseline() throws {
        let controller = try EditorController(initialMarkdown: "hi \n")
        var steps: [Step] = []
        controller.onDocumentChange = { steps.append($0.step) }

        // Two interim marked-text passes, then the commit.
        edit(controller, replacing: NSRange(location: 3, length: 0), with: "n", hint: .composition, marked: true)
        edit(controller, replacing: NSRange(location: 3, length: 1), with: "ni", hint: .composition, marked: true)
        let classes = edit(controller, replacing: NSRange(location: 3, length: 2), with: "\u{4ECA}", hint: .composition, marked: false)

        #expect(classes == [.compositionCommit])
        #expect(steps.count == 1, "one publish for the whole composition, got \(steps.count)")
        guard case .replaceText(let range, let content) = steps[0] else {
            Issue.record("expected replaceText")
            return
        }
        #expect(range == NSRange(location: 3, length: 0), "the commit is measured against the pre-composition state")
        #expect(content.string == "\u{4ECA}")
        #expect(controller.compositionBaseline == nil)
    }

    @Test func cancelledCompositionPublishesNothing() throws {
        let controller = try EditorController(initialMarkdown: "hi \n")
        var published = 0
        controller.onDocumentChange = { _ in published += 1 }

        edit(controller, replacing: NSRange(location: 3, length: 0), with: "n", hint: .composition, marked: true)
        // Esc: the marked text goes away and the pre-image is back.
        edit(controller, replacing: NSRange(location: 3, length: 1), with: "", hint: .composition, marked: false)

        #expect(published == 0, "an escaped composition changed nothing")
        #expect(controller.compositionBaseline == nil)
    }

    @Test func multiCaptureRecordIsBulk() throws {
        let controller = try EditorController(initialMarkdown: "abcdef\n")
        var classes: [EditorController.EditClass] = []
        controller.classificationProbe = { classes.append($0) }
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.nextEditHint = .typing

        let storage = controller.textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 4, length: 2), with: "")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ef")
        storage.endEditing()
        controller.drainPendingEnvelopes()

        #expect(classes == [.bulk], "a drag-move is bulk however it was hinted")
    }

    @Test func undoingEditIsHistoryClass() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.undoManager.groupsByEvent = false
        controller.testSelection = NSRange(location: 5, length: 0)
        _ = controller.insert(text: "!")

        var classes: [EditorController.EditClass] = []
        controller.classificationProbe = { classes.append($0) }
        controller.undoManager.undo()
        controller.drainPendingEnvelopes()

        #expect(classes.allSatisfy { $0 == .history } || classes.isEmpty,
                "undo replay is never mistaken for typing, got \(classes)")
    }

    @Test func inputRulesRunOnlyForTypingClass() throws {
        // "# " typed one char at a time promotes to a heading.
        let typed = try EditorController(initialMarkdown: "\n")
        typed.testSelection = NSRange(location: 0, length: 0)
        for ch in "# " {
            let at = typed.testSelection ?? NSRange(location: 0, length: 0)
            typed.nextEditHint = .typing
            typed.textStorage.beginEditing()
            typed.textStorage.replaceCharacters(in: at, with: String(ch))
            typed.testSelection = NSRange(location: at.location + 1, length: 0)
            typed.textStorage.endEditing()
        }
        #expect(typed.textStorage.blockSpec(at: 0)?.kind == .heading(level: 1))

        // The same characters delivered as a correction must not fire it.
        let corrected = try EditorController(initialMarkdown: "x\n")
        corrected.testSelection = NSRange(location: 1, length: 0)
        corrected.nextEditHint = .correction
        corrected.textStorage.beginEditing()
        corrected.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "# ")
        corrected.testSelection = NSRange(location: 2, length: 0)
        corrected.textStorage.endEditing()
        corrected.drainPendingEnvelopes()
        #expect(corrected.textStorage.blockSpec(at: 0)?.kind == .paragraph,
                "autocorrect output must not be re-transformed by an input rule")
    }

    @Test func attributeOnlyHintIsDroppedButInvalidates() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        _ = controller.document
        var published = 0
        controller.onDocumentChange = { _ in published += 1 }
        controller.nextEditHint = .attributeOnly
        let storage = controller.textStorage
        storage.beginEditing()
        storage.addAttribute(.proseListMarker, value: true, range: NSRange(location: 0, length: 1))
        storage.endEditing()
        controller.drainPendingEnvelopes()
        #expect(published == 0)
    }

    #if canImport(AppKit) && os(macOS)
    @MainActor
    @Test func macBulkVetoIgnoresCorrections() throws {
        let controller = try EditorController(initialMarkdown: "teh cat\n")
        let view = ProseTextViewMac(controller: controller, text: .constant("teh cat\n"))
        let coordinator = view.makeCoordinator()
        let textView = NSTextView(frame: .zero, textContainer: controller.textContainer)
        controller.hostTextView = textView
        coordinator.textView = textView

        // Autocorrect: caret after the word, affected range is the word.
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        var paste = 0
        controller.register(plugin: CountingPastePlugin { paste += 1 })

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 3),
            replacementString: "the"
        )
        #expect(allowed, "a correction must be allowed through, not routed to paste")
        #expect(paste == 0)
        #expect(controller.nextEditHint == .correction)

        // A genuine bulk insert over the selection still routes.
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        let allowedBulk = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 3),
            replacementString: "one two"
        )
        #expect(!allowedBulk, "selection-replacing bulk text still goes through paste")
        #expect(paste == 1)
    }

    @MainActor
    @Test func macNilReplacementStampsAttributeOnly() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let view = ProseTextViewMac(controller: controller, text: .constant("hello\n"))
        let coordinator = view.makeCoordinator()
        let textView = NSTextView(frame: .zero, textContainer: controller.textContainer)
        controller.hostTextView = textView
        coordinator.textView = textView

        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 5),
            replacementString: nil
        )
        #expect(allowed)
        #expect(controller.nextEditHint == .attributeOnly)
    }
    #endif
}

#if canImport(AppKit) && os(macOS)
private final class CountingPastePlugin: EditorPlugin {
    let key = AnyPluginKey(name: "test.countingPaste")
    let onPaste: () -> Void
    init(onPaste: @escaping () -> Void) { self.onPaste = onPaste }
    var props: PluginProps {
        PluginProps(handlePaste: { [onPaste] _, _ in
            onPaste()
            return true
        })
    }
}
#endif
