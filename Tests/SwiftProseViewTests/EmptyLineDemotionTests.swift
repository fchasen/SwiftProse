import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// "Delete clears the formatting" — when the user empties a line, its
/// block spec resets to plain paragraph. These tests exercise the
/// `demoteEmptyStyledLines` path across every block kind. List items are
/// covered separately by `BackspaceDemotionTests` (different code path).
@Suite(.serialized) struct EmptyLineDemotionTests {

    // MARK: - block kinds that should demote

    @Test func emptyHeadingDemotesToParagraph() throws {
        let controller = try EditorController(initialMarkdown: "# Hello\n")
        emptyLine(at: 0, in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .paragraph)
        #expect(spec?.blockquoteDepth == 0)
    }

    @Test func emptyBlockquoteParagraphDropsQuoteDepth() throws {
        let controller = try EditorController(initialMarkdown: "> quoted\n")
        emptyLine(at: 0, in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .paragraph)
        #expect(spec?.blockquoteDepth == 0,
                "blockquote depth should clear when the line is emptied")
    }

    @Test func emptyHeadingInsideBlockquoteDropsBoth() throws {
        let controller = try EditorController(initialMarkdown: "> # Hello\n")
        emptyLine(at: 0, in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .paragraph)
        #expect(spec?.blockquoteDepth == 0)
    }

    @Test func emptyHorizontalRuleDemotes() throws {
        let controller = try EditorController(initialMarkdown: "---\n")
        emptyLine(at: 0, in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .paragraph)
    }

    // MARK: - block kinds that must NOT demote

    @Test func fencedCodeBodyLineKeepsSpecWhenEmptied() throws {
        // Open an empty fenced block, type a char, then delete it. Body
        // line spec must remain `.fencedCode` after the body goes empty
        // again so the leaf survives.
        let controller = try EditorController(initialMarkdown: "")
        type("```", in: controller)
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.insert(text: "x")
        let storage = controller.textStorage
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 1),
            with: ""
        )
        storage.endEditing()
        let bodySpec = storage.blockSpec(at: 0)
        if case .fencedCode = bodySpec?.kind {
            // ok
        } else {
            Issue.record("expected fenced code spec on empty body, got \(String(describing: bodySpec?.kind))")
        }
    }

    @Test func listItemDoesNotDemoteOnSelectAndDelete() throws {
        // Selecting just the body text of a bullet and pressing delete
        // leaves the marker; the line spec must remain a list item so
        // the user can keep typing into the bullet.
        let controller = try EditorController(initialMarkdown: "- apple\n")
        let storage = controller.textStorage
        // Find the body offset (after the marker run) and length.
        var bodyStart = -1
        storage.enumerateAttribute(.proseListMarker, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? Bool) == true {
                bodyStart = range.location + range.length
                stop.pointee = true
            }
        }
        #expect(bodyStart > 0)
        let ns = storage.string as NSString
        let line = ns.paragraphRange(for: NSRange(location: bodyStart, length: 0))
        let bodyRange = NSRange(
            location: bodyStart,
            length: line.location + line.length - bodyStart - 1 // keep newline
        )
        storage.beginEditing()
        storage.replaceCharacters(in: bodyRange, with: "")
        storage.endEditing()
        let spec = storage.blockSpec(at: 0)
        #expect(spec?.isListItem == true,
                "list item should keep its spec after deleting body text")
    }

    // MARK: - typingAttributes follow-through

    @Test func emptiedHeadingResetsTypingAttributesToPlain() throws {
        let controller = try EditorController(initialMarkdown: "# Hello\n")
        emptyLine(at: 0, in: controller)
        // After demote, a fresh keystroke should land as a plain paragraph.
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.insert(text: "x")
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .paragraph)
    }

    // MARK: - helpers

    /// Replace the entire line at `offset` with a bare newline so the
    /// line text becomes empty. Drives the storage observer just like a
    /// host text view delete would.
    private func emptyLine(at offset: Int, in controller: EditorController) {
        let ns = controller.textStorage.string as NSString
        let line = ns.paragraphRange(for: NSRange(location: offset, length: 0))
        controller.textStorage.beginEditing()
        controller.textStorage.replaceCharacters(in: line, with: "\n")
        controller.textStorage.endEditing()
    }

    private func type(_ chars: String, in controller: EditorController) {
        for char in chars {
            let selection = controller.testSelection ?? NSRange(location: 0, length: 0)
            let storage = controller.textStorage
            let str = String(char)
            let typedLength = (str as NSString).length
            let preLength = storage.length
            storage.beginEditing()
            storage.replaceCharacters(in: selection, with: str)
            controller.testSelection = NSRange(
                location: selection.location + typedLength,
                length: 0
            )
            storage.endEditing()
            let postLength = storage.length
            if postLength != preLength + typedLength {
                let ns = storage.string as NSString
                let cursorPos = postLength > 0 && ns.character(at: postLength - 1) == 0x0A
                    ? postLength - 1
                    : postLength
                controller.testSelection = NSRange(location: cursorPos, length: 0)
            }
        }
    }
}
