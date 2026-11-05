#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Editor controller integration (macOS)", .serialized)
@MainActor
struct EditorControllerIntegrationTests {
    private func deleteForward(_ harness: EditorHarness) {
        harness.step { harness.textView.doCommand(by: #selector(NSResponder.deleteForward(_:))) }
    }

    @Test func performBoldOnSelectionPreservesSelection() {
        let harness = EditorHarness(markdown: "alpha beta\n")
        let selection = NSRange(location: 0, length: 5)
        harness.select(selection)
        harness.step { harness.controller.perform(.bold) }
        #expect(harness.controller.markdown() == "**alpha** beta")
        #expect(harness.selection == selection)
    }

    @Test func performHeadingPreservesInlineMarks() {
        let harness = EditorHarness(markdown: "**title** here\n")
        harness.select(0)
        harness.step { harness.controller.perform(.heading(level: 2)) }
        #expect(harness.controller.markdown() == "## **title** here")
    }

    @Test func exitCodeBlockFromNonEmptyBlockAddsParagraphAfter() {
        let harness = EditorHarness(markdown: "```\nlet x = 1\n```\n")
        harness.select(9)
        var exited = false
        harness.step { exited = harness.controller.exitCodeBlock() }
        #expect(exited)
        harness.type("after")
        #expect(harness.controller.markdown() == "```\nlet x = 1\n```\n\nafter")
    }

    @Test func exitCodeBlockFromEmptyBlockReplacesWithParagraph() {
        let harness = EditorHarness(markdown: "```\n```\n")
        harness.select(0)
        var exited = false
        harness.step { exited = harness.controller.exitCodeBlock() }
        #expect(exited)
        #expect(harness.controller.markdown() == "```\n```")
    }

    @Test func exitCodeBlockOutsideCodeReturnsFalse() {
        let harness = EditorHarness(markdown: "hello\n")
        harness.select(0)
        #expect(harness.controller.exitCodeBlock() == false)
        #expect(harness.controller.markdown() == "hello\n")
    }

    @Test func loadingPlainParagraphDocDoesNotAddTrailing() {
        let harness = EditorHarness(markdown: "hello\n")
        #expect(harness.string == "hello")
    }

    @Test func loadingHorizontalRuleEnsuresTrailingParagraph() {
        let harness = EditorHarness(markdown: "---\n")
        harness.select(harness.storage.length)
        harness.type("after")
        #expect(harness.controller.markdown() == "---\n\nafter")
    }

    @Test func backspaceAtStartOfEmptyCodeBlockDeletesBlock() {
        let harness = EditorHarness(markdown: "hello\n\n```\n\n```\n")
        harness.select(6)
        #expect(harness.block(at: 6)?.isCode == true)
        harness.deleteBackward()
        #expect(harness.controller.markdown() == "hello")
    }

    @Test func forwardDeleteAtEmptyCodeBlockDeletesBlock() {
        let harness = EditorHarness(markdown: "hello\n\n```\n\n```\n")
        harness.select(6)
        deleteForward(harness)
        #expect(harness.controller.markdown() == "hello")
    }

    @Test func backspaceAfterToolbarInsertOnEmptyDocument() {
        let harness = EditorHarness(markdown: "")
        harness.step { harness.controller.perform(.codeBlock) }
        #expect(harness.controller.isActive(.codeBlock))
        harness.deleteBackward()
        #expect(!harness.controller.isActive(.codeBlock))
        #expect(harness.controller.markdown() == "")
    }

    @Test func backspaceAfterToolbarInsertOnNonEmptyParagraph() {
        let harness = EditorHarness(markdown: "hello\n")
        harness.select(0)
        harness.step { harness.controller.perform(.codeBlock) }
        #expect(harness.block(at: 0)?.isCode == true)
        harness.deleteBackward()
        #expect(harness.block(at: 0)?.isCode == false)
        #expect(harness.controller.markdown() == "hello\n")
    }
}
#endif
