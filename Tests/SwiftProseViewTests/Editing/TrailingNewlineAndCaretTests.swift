import Foundation
import Testing
#if canImport(AppKit) && os(macOS)
import AppKit
#endif
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Trailing newline & caret preservation", .serialized)
@MainActor
struct TrailingNewlineAndCaretTests {
    @Test func markdownHasNoTrailingNewlineForParagraph() {
        let controller = EditorController(markdown: "hello")
        #expect(controller.markdown() == "hello")
        #expect(controller.serialize() == "hello")
    }

    @Test func markdownHasNoTrailingNewlineWhenInputHadOne() {
        let controller = EditorController(markdown: "hello\n")
        #expect(controller.serialize() == "hello")
    }

    @Test func markdownHasNoTrailingNewlineForCodeBlock() {
        let controller = EditorController(markdown: "para\n\n```\ncode\n```\n")
        #expect(controller.serialize() == "para\n\n```\ncode\n```")
    }

    @Test func markdownKeepsInteriorBlankLines() {
        let controller = EditorController(markdown: "a\n\nb\n")
        #expect(controller.serialize() == "a\n\nb")
    }

    @Test func emptyDocumentSerializesEmpty() {
        let controller = EditorController(markdown: "")
        #expect(controller.markdown() == "")
        #expect(controller.serialize() == "")
    }

    #if canImport(AppKit) && os(macOS)
    @Test(.disabled("setMarkdown on a hosted controller moves the caret to the document end"))
    func setMarkdownPreservesCaret() {
        let harness = EditorHarness(markdown: "one two three four\n")
        harness.select(8)
        harness.controller.setMarkdown("one two three four five\n")
        #expect(harness.controller.currentSelection.location == 8)
    }

    @Test func setMarkdownClampsCaretWhenDocumentShrinks() {
        let harness = EditorHarness(markdown: "a long first line here\n")
        harness.select(18)
        harness.controller.setMarkdown("short\n")
        #expect(harness.controller.currentSelection.location <= harness.storage.length)
    }
    #endif
}

@Suite("Serializer & selection fixes", .serialized)
@MainActor
struct SerializerAndSelectionFixTests {
    @Test func blocksAreSeparatedBySingleBlankLine() {
        let controller = EditorController(markdown: "# H\n\n\n\npara\n\n\n> quote\n")
        #expect(!controller.serialize().contains("\n\n\n"))
        #expect(controller.serialize() == "# H\n\npara\n\n> quote")
    }

    #if canImport(AppKit) && os(macOS)
    @Test func atomicTerminatedDocKeepsTrailingLandingParagraph() {
        let harness = EditorHarness(markdown: "para\n\n---\n")
        #expect(harness.paragraphBlocks.last == MarkdownBlock(leaf: .thematicBreak))
        harness.select(harness.storage.length)
        harness.type("x")
        harness.settle()
        #expect(harness.block(at: harness.storage.length - 1) == .paragraph)
        #expect(harness.markdown == "para\n\n---\n\nx")
    }
    #endif
}
