import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Commands")
@MainActor
struct CommandTests {
    private func editor(_ markdown: String, selecting range: NSRange) -> HeadlessEditor {
        let editor = HeadlessEditor(markdown: markdown)
        editor.controller.setSelection(range)
        return editor
    }

    private func toggledCodeBlock(_ markdown: String, at location: Int, length: Int = 0) -> String {
        let editor = editor(markdown, selecting: NSRange(location: location, length: length))
        editor.controller.perform(.codeBlock)
        return editor.controller.markdown()
    }

    @Test func registryDefaultsExposeEveryAction() {
        let editor = editor("hello\n", selecting: NSRange(location: 0, length: 0))
        let actions: [EditorAction] = [
            .bold, .italic, .strikethrough, .codeSpan,
            .heading(level: 1), .heading(level: 2), .heading(level: 3),
            .heading(level: 4), .heading(level: 5), .heading(level: 6),
            .unorderedList, .orderedList, .taskList,
            .blockquote, .codeBlock, .horizontalRule
        ]
        for action in actions {
            #expect(editor.controller.canPerform(action), "cannot perform \(action)")
        }
        let list = self.editor("- a\n  - b\n", selecting: NSRange(location: 2, length: 0))
        #expect(list.controller.canPerform(.indent))
        #expect(list.controller.canPerform(.outdent))
    }

    @Test func headingCommandProducesOneStepPerParagraph() {
        let editor = HeadlessEditor(markdown: "first\n\nsecond\n\nthird\n")
        editor.controller.setSelection(NSRange(location: 0, length: editor.controller.textStorage.length))
        editor.controller.perform(.heading(level: 2))
        #expect(editor.controller.markdown() == "## first\n\n## second\n\n## third")
    }

    @Test func outdentCanExecuteOnlyWhenNested() {
        let probe = NSRange(location: 0, length: 0)
        #expect(!editor("paragraph\n", selecting: probe).controller.canPerform(.outdent))
        #expect(!editor("> quoted\n", selecting: probe).controller.canPerform(.outdent))
        #expect(editor("- item\n", selecting: probe).controller.canPerform(.outdent))
    }

    @Test func emptyStorageBlockCommandStillProducesAStep() {
        let editor = editor("", selecting: NSRange(location: 0, length: 0))
        editor.controller.perform(.unorderedList)
        editor.type("x")
        #expect(editor.controller.markdown() == "- x")
    }

    @Test func toggleCodeBlockOnEmptyDocInsertsEmptyBlock() {
        let editor = editor("", selecting: NSRange(location: 0, length: 0))
        editor.controller.perform(.codeBlock)
        #expect(editor.controller.isActive(.codeBlock))
        editor.type("x")
        #expect(editor.controller.markdown() == "```\nx\n```")
    }

    @Test func toggleCodeBlockOnNonEmptyParagraphInsertsAfter() {
        let editor = editor("hello\n", selecting: NSRange(location: 0, length: 0))
        editor.controller.perform(.codeBlock)
        #expect(editor.controller.markdown() == "```\nhello\n```")
        #expect(editor.controller.textStorage.markdownBlock(at: 0)?.isCode == true)
    }

    @Test func toggleCodeBlockAtCursorEndOfContentInsertsAfter() {
        #expect(toggledCodeBlock("hello\n", at: 5) == "```\nhello\n```")
    }

    @Test(arguments: [0, 1, 3, 5])
    func toggleCodeBlockIsStableAcrossCursorColumns(cursor: Int) {
        #expect(toggledCodeBlock("hello\n", at: cursor) == "```\nhello\n```", "cursor=\(cursor)")
    }

    @Test func toggleCodeBlockOnSecondOfThreeParagraphsInsertsAfter() {
        #expect(toggledCodeBlock("first\n\nsecond\n\nthird\n", at: 8) == "first\n\n```\nsecond\n```\n\nthird")
    }

    @Test func toggleCodeBlockOnLastParagraphNoTrailingNewlineInsertsAfter() {
        #expect(toggledCodeBlock("first\n\nsecond", at: 9) == "first\n\n```\nsecond\n```")
    }

    @Test func toggleCodeBlockAtParagraphTerminatorInsertsAfter() {
        #expect(toggledCodeBlock("alpha\n\nbeta\n", at: 5) == "```\nalpha\n```\n\nbeta")
    }

    @Test func toggleCodeBlockAtStartOfSecondParagraphInsertsAfter() {
        #expect(toggledCodeBlock("alpha\n\nbeta\n", at: 6) == "alpha\n\n```\nbeta\n```")
    }

    @Test func toggleCodeBlockSelectionAcrossTwoParagraphs() {
        let md = toggledCodeBlock("alpha\nbeta\n", at: 1, length: 8)
        #expect(md == "```\nalpha\nbeta\n```")
    }

    @Test func toggleCodeBlockOnListItemKeepsItemBody() {
        #expect(toggledCodeBlock("- foo\n", at: 1) == "- ```\n  foo\n  ```")
    }

    @Test func toggleCodeBlockTogglesOffToParagraph() {
        #expect(toggledCodeBlock("```\nhello\n```\n", at: 1) == "hello")
    }

    @Test func toggleCodeBlockOffOnExistingFence() {
        #expect(toggledCodeBlock("```\nhello world\n```\n", at: 0) == "hello world")
    }

    @Test func toggleCodeBlockOnMiddleLineOfMultilineBlock() {
        let editor = HeadlessEditor(markdown: "```\nline1\nline2\nline3\n```\n")
        let cursor = (editor.string as NSString).range(of: "line2").location
        editor.controller.setSelection(NSRange(location: cursor, length: 0))
        editor.controller.perform(.codeBlock)
        #expect(editor.controller.markdown() == "```\nline1\n```\n\nline2\n\n```\nline3\n```")
    }

    @Test func toggleCodeBlockOnFirstLineOfMultilineBlock() {
        #expect(toggledCodeBlock("```\nline1\nline2\nline3\n```\n", at: 0) == "line1\n\n```\nline2\nline3\n```")
    }

    @Test func toggleCodeBlockOnBlockquoteInsertsAfter() {
        let md = toggledCodeBlock("> hello\n", at: 2)
        #expect(md == "> ```\n> hello\n> ```")
    }

    @Test(arguments: [
        (0, "first"),
        (3, "first"),
        (5, "first"),
        (6, "second"),
        (9, "second"),
        (12, "second"),
        (13, "third"),
        (15, "third"),
    ])
    func toggleCodeBlockTargetsCursorParagraph(cursor: Int, expected: String) {
        let editor = HeadlessEditor(markdown: "first\n\nsecond\n\nthird\n")
        editor.controller.setSelection(NSRange(location: cursor, length: 0))
        editor.controller.perform(.codeBlock)
        let md = editor.controller.markdown()
        #expect(md.contains("```\n\(expected)\n```"), "cursor=\(cursor) got \(String(reflecting: md))")
        for word in ["first", "second", "third"] where word != expected {
            #expect(!md.contains("```\n\(word)\n```"), "cursor=\(cursor) wrapped \(word)")
        }
    }
}
