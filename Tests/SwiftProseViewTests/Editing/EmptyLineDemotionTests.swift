#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite(.serialized)
@MainActor
struct EmptyLineDemotionTests {
    private func emptyLine(at offset: Int, in harness: EditorHarness) {
        let info = harness.controller.paragraphInfo(at: offset)
        harness.select(info.content)
        harness.deleteBackward()
    }

    private func typedBlock(_ harness: EditorHarness) -> MarkdownBlock? {
        harness.type("x")
        return harness.block(at: harness.selection.location - 1)
    }

    @Test func emptyHeadingDemotesToParagraph() {
        let harness = EditorHarness(markdown: "# Hello\n")
        emptyLine(at: 0, in: harness)
        #expect(harness.controller.paragraphInfo(at: 0).block.headingLevel == 1)
        harness.deleteBackward()
        let block = typedBlock(harness)
        #expect(block?.headingLevel == nil)
        #expect(block?.isInQuote == false)
        #expect(harness.markdown == "x")
    }

    @Test func emptyBlockquoteParagraphDropsQuoteDepth() {
        let harness = EditorHarness(markdown: "> quoted\n")
        emptyLine(at: 0, in: harness)
        #expect(harness.controller.paragraphInfo(at: 0).block.isInQuote)
        harness.deleteBackward()
        let block = typedBlock(harness)
        #expect(block?.quoteTokens.isEmpty == true)
        #expect(harness.markdown == "x")
    }

    @Test func emptyHeadingInsideBlockquoteDropsBoth() {
        let harness = EditorHarness(markdown: "> # Hello\n")
        emptyLine(at: 0, in: harness)
        harness.deleteBackward()
        #expect(harness.controller.paragraphInfo(at: 0).block.headingLevel == nil)
        #expect(harness.controller.paragraphInfo(at: 0).block.isInQuote)
        harness.deleteBackward()
        let block = typedBlock(harness)
        #expect(block?.headingLevel == nil)
        #expect(block?.quoteTokens.isEmpty == true)
        #expect(harness.markdown == "x")
    }

    @Test func emptyHorizontalRuleDemotes() {
        let harness = EditorHarness(markdown: "---\n")
        harness.select(1)
        harness.deleteBackward()
        #expect(harness.storage.length == 0)
        let block = typedBlock(harness)
        #expect(block == .paragraph)
        #expect(harness.markdown == "x")
    }

    @Test func fencedCodeBodyLineKeepsSpecWhenEmptied() {
        let harness = EditorHarness(markdown: "")
        harness.type("```")
        harness.insertNewline()
        harness.type("x")
        harness.deleteBackward()
        #expect(harness.controller.paragraphInfo(at: harness.selection.location).block.isCode)
        harness.type("y")
        #expect(harness.markdown == "```\ny\n```")
    }

    @Test(.disabled("deleting all of the last list item's text drops the item: typing attributes keep the list block but lose its NSTextList"))
    func listItemDoesNotDemoteOnSelectAndDelete() {
        let harness = EditorHarness(markdown: "- apple\n")
        emptyLine(at: 0, in: harness)
        #expect(harness.controller.paragraphInfo(at: harness.selection.location).block.isListItemStart)
        harness.type("x")
        #expect(harness.block(at: 0)?.isListItemStart == true)
        #expect(harness.markdown == "- x")
    }

    @Test func emptiedHeadingResetsTypingAttributesToPlain() {
        let harness = EditorHarness(markdown: "# Hello\n")
        emptyLine(at: 0, in: harness)
        harness.deleteBackward()
        harness.type("x")
        #expect(harness.block(at: 0) == .paragraph)
        #expect(harness.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == harness.controller.theme.bodyFont)
    }
}
#endif
