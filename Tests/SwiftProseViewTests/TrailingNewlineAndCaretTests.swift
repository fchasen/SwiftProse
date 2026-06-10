import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

/// Regressions for two real-use bugs: markdown() force-appending a trailing
/// newline, and setMarkdown / recompile resetting the caret to the doc end.
@Suite("Trailing newline & caret preservation")
struct TrailingNewlineAndCaretTests {

    @Test
    func markdownHasNoTrailingNewlineForParagraph() throws {
        let controller = try EditorController(initialMarkdown: "hello")
        #expect(controller.markdown() == "hello")
    }

    @Test
    func markdownHasNoTrailingNewlineWhenInputHadOne() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        #expect(controller.markdown() == "hello")
    }

    @Test
    func markdownHasNoTrailingNewlineForCodeBlock() throws {
        let controller = try EditorController(initialMarkdown: "para\n\n```\ncode\n```\n")
        #expect(controller.markdown() == "para\n\n```\ncode\n```")
    }

    @Test
    func markdownKeepsInteriorBlankLines() throws {
        let controller = try EditorController(initialMarkdown: "a\n\nb\n")
        #expect(controller.markdown() == "a\n\nb")
    }

    @Test
    func emptyDocumentSerializesEmpty() throws {
        let controller = try EditorController(initialMarkdown: "")
        #expect(controller.markdown() == "")
    }

    #if canImport(AppKit) && os(macOS)
    @MainActor
    @Test
    func setMarkdownPreservesCaret() throws {
        let controller = try EditorController(initialMarkdown: "one two three four\n")
        let tv = NSTextView(frame: .zero, textContainer: controller.textContainer)
        controller.hostTextView = tv
        tv.setSelectedRange(NSRange(location: 8, length: 0))

        controller.setMarkdown("one two three four five\n", async: false)

        #expect(controller.currentSelection.location == 8,
                "caret should survive a setMarkdown that appends content")
    }

    @MainActor
    @Test
    func setMarkdownClampsCaretWhenDocumentShrinks() throws {
        let controller = try EditorController(initialMarkdown: "a long first line here\n")
        let tv = NSTextView(frame: .zero, textContainer: controller.textContainer)
        controller.hostTextView = tv
        tv.setSelectedRange(NSRange(location: 18, length: 0))

        controller.setMarkdown("short\n", async: false)

        let total = controller.textStorage.length
        #expect(controller.currentSelection.location <= total,
                "caret must stay in bounds after the document shrinks")
    }
    #endif
}
