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

/// Regressions for audit findings: blank-line normalization between blocks,
/// the `.all` selection resolution, and the trailing landing paragraph.
@Suite("Serializer & selection fixes")
struct SerializerAndSelectionFixTests {

    // Fix 1: blocks are separated by exactly one blank line — never three+
    // consecutive newlines.
    @Test
    func blocksAreSeparatedBySingleBlankLine() throws {
        let controller = try EditorController(initialMarkdown: "# H\n\npara\n\n> quote\n")
        let md = controller.markdown()
        #expect(!md.contains("\n\n\n"))
    }

    // Fix 2: `.all` resolves to the whole document; the length-agnostic
    // property still reports empty, and other cases pass through.
    @Test
    func allSelectionResolvesToFullDocument() {
        #expect(Selection.all.resolvedRange(documentLength: 10) == NSRange(location: 0, length: 10))
        #expect(Selection.all.selectedRange == NSRange(location: 0, length: 0))
        #expect(Selection.cursor(at: 3).resolvedRange(documentLength: 10) == NSRange(location: 3, length: 0))
        #expect(Selection.textRange(NSRange(location: 2, length: 4)).resolvedRange(documentLength: 10)
                == NSRange(location: 2, length: 4))
    }

    // Fix 3: a doc ending in an atomic block keeps a plain trailing paragraph
    // as a landing spot (the invariant the per-keystroke guard must preserve).
    @Test
    func atomicTerminatedDocKeepsTrailingLandingParagraph() throws {
        let controller = try EditorController(initialMarkdown: "```\ncode\n```\n")
        let last = controller.textStorage.length - 1
        #expect(controller.textStorage.blockSpec(at: last)?.isCodeBlock == false)
    }
}
