import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct EnvelopeQueueTests {

    /// A platform-style keystroke: exactly what the text view does.
    private func type(_ controller: EditorController, _ text: String, at location: Int) {
        let storage = controller.textStorage
        controller.testSelection = NSRange(location: location, length: 0)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: text)
        storage.endEditing()
    }

    @Test func headlessEditClosesBeforeEndEditingReturns() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var published: [Step] = []
        controller.onDocumentChange = { published.append($0.step) }

        type(controller, "!", at: 5)

        #expect(controller.pendingEnvelopes.isEmpty,
                "no host attached — the envelope closes synchronously")
        #expect(published.count == 1)
        guard case .replaceText(let range, let content) = published[0] else {
            Issue.record("expected replaceText, got \(published[0])")
            return
        }
        #expect(range == NSRange(location: 5, length: 0))
        #expect(content.string == "!")
    }

    @Test func markdownReadForcesDrain() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var published = 0
        controller.onDocumentChange = { _ in published += 1 }
        type(controller, " there", at: 5)
        #expect(controller.markdown().hasPrefix("hello there"))
        #expect(published == 1)
        #expect(controller.pendingEnvelopes.isEmpty)
    }

    @Test func documentReadForcesDrain() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        type(controller, "!", at: 5)
        #expect(controller.document.contentLength == controller.textStorage.length)
        #expect(controller.pendingEnvelopes.isEmpty)
    }

    @Test func bracketedMultiEditPublishesOnce() throws {
        let controller = try EditorController(initialMarkdown: "abcdef\n")
        var published: [Step] = []
        controller.onDocumentChange = { published.append($0.step) }
        controller.testSelection = NSRange(location: 0, length: 0)

        let storage = controller.textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 4, length: 2), with: "")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ef")
        storage.endEditing()

        #expect(published.count == 1, "one bracket, one publish")
    }

    @Test func multiStepTransactionPublishesOnce() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var published: [Step] = []
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.onDocumentChange = { published.append($0.step) }
        _ = controller.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 5, length: 0),
                         with: NSAttributedString(string: "A")),
            .replaceText(range: NSRange(location: 0, length: 0),
                         with: NSAttributedString(string: "B"))
        ]))
        #expect(published.count == 1,
                "an N-step transaction is one edit group, got \(published.count)")
    }

    @Test func applyForcesDrainBeforeRunning() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var order: [String] = []
        controller.onDocumentChange = { change in
            if case .replaceText(_, let content) = change.step {
                order.append(content.string)
            }
        }
        type(controller, "!", at: 5)
        _ = controller.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 0, length: 0),
                         with: NSAttributedString(string: "Z"))
        ]))
        #expect(order.first == "!", "the pending keystroke closes before the transaction, got \(order)")
    }

    @Test func normalizeEditsDoNotPublishSeparately() throws {
        // Typing at the tail triggers `ensureTrailingParagraph` only after
        // an atomic block; use a code fence so normalization definitely runs.
        let controller = try EditorController(initialMarkdown: "```\ncode\n```\n")
        var published = 0
        controller.onDocumentChange = { _ in published += 1 }
        let tail = controller.textStorage.length
        type(controller, "x", at: max(0, tail - 1))
        #expect(published == 1, "normalization is a side effect, not its own change")
    }

    @Test func attributeOnlyEditPublishesNothingButInvalidates() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        _ = controller.document
        var published = 0
        controller.onDocumentChange = { _ in published += 1 }
        let before = controller.document.root.node?.id

        let storage = controller.textStorage
        storage.beginEditing()
        storage.addAttribute(.proseListMarker, value: true, range: NSRange(location: 0, length: 1))
        storage.endEditing()

        #expect(published == 0, "attribute-only edits have no clean replaceText mapping")
        #expect(controller.document.root.node?.id != before, "but the cache still invalidates")
    }

    @Test func loadPublishesWholeDocumentChange() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var published: [Step] = []
        controller.onDocumentChange = { published.append($0.step) }
        controller.setMarkdown("goodbye\n", async: false)
        #expect(published.count == 1)
        guard case .replaceText(_, let content) = published[0] else {
            Issue.record("expected replaceText")
            return
        }
        #expect(content.string.hasPrefix("goodbye"))
    }

    @Test func inputRulesStillFireFromTheEnvelope() throws {
        let controller = try EditorController(initialMarkdown: "\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        let storage = controller.textStorage
        // A host moves the caret before `endEditing`, which is when the
        // headless drain closes the envelope.
        for ch in "# " {
            let at = controller.testSelection ?? NSRange(location: 0, length: 0)
            storage.beginEditing()
            storage.replaceCharacters(in: at, with: String(ch))
            controller.testSelection = NSRange(location: at.location + 1, length: 0)
            storage.endEditing()
        }
        #expect(controller.textStorage.blockSpec(at: 0)?.kind == .heading(level: 1),
                "the '# ' input rule fires from the envelope close")
    }

    @Test func drainIsIdempotent() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var published = 0
        controller.onDocumentChange = { _ in published += 1 }
        type(controller, "!", at: 5)
        controller.drainPendingEnvelopes()
        controller.drainPendingEnvelopes()
        #expect(published == 1)
    }
}
