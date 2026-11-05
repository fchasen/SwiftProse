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
struct SoftBreakTests {
    private func blockCount(_ harness: EditorHarness) -> Int {
        StorageReader().document(from: harness.storage).blocks.count
    }

    private func caret(_ harness: EditorHarness, before needle: String) -> Int {
        let location = (harness.string as NSString).range(of: needle).location
        precondition(location != NSNotFound, "no \(needle) in storage")
        return location
    }

    @Test func typingOnTheSecondLineKeepsOneParagraph() {
        let harness = EditorHarness(markdown: "one two\nthree four\n")
        #expect(blockCount(harness) == 1)
        harness.select(caret(harness, before: "four"))
        harness.type("x")
        #expect(harness.markdown == "one two\nthree xfour")
        #expect(blockCount(harness) == 1)
        #expect(harness.paragraphBlocks == [.paragraph])
    }

    @Test func typingOnTheSecondLineOfABlockquoteKeepsOneBlockquote() {
        let harness = EditorHarness(markdown: "> one two\n> three four\n> five six\n")
        harness.select(caret(harness, before: "four"))
        harness.type("x")
        #expect(harness.markdown == "> one two\n> three xfour\n> five six")
        #expect(blockCount(harness) == 1)
        #expect(harness.paragraphBlocks.count == 1)
    }

    @Test func writingALineBreakSplitsThereAndMovesTheWholeTail() {
        let harness = EditorHarness(markdown: "one two\nthree four\nfive six\n")
        harness.select(caret(harness, before: "four"))
        harness.insertNewline()
        #expect(harness.markdown == "one two\nthree \n\nfour\nfive six")
        #expect(blockCount(harness) == 2)
        #expect(harness.paragraphBlocks == [.paragraph, .paragraph])
    }

    @Test func typingPastTheEndOpensANewParagraph() {
        let harness = EditorHarness(markdown: "one two\n")
        harness.select(harness.storage.length)
        harness.insertNewline()
        harness.type("x")
        #expect(harness.markdown == "one two\n\nx")
        #expect(blockCount(harness) == 2)
    }

    @Test func aBlankLineStaysABlockBoundary() {
        let harness = EditorHarness(markdown: "one\n\ntwo\n")
        let before = blockCount(harness)
        harness.select(caret(harness, before: "two"))
        harness.type("x")
        #expect(harness.markdown == "one\n\nxtwo")
        #expect(blockCount(harness) == before)
    }

    @Test func aCodeFenceStaysOneBlockWhenTypedInto() {
        let harness = EditorHarness(markdown: "```swift\nlet a = 1\nlet b = 2\n```\n")
        harness.select(caret(harness, before: "let b"))
        harness.type("x")
        #expect(harness.markdown == "```swift\nlet a = 1\nxlet b = 2\n```")
        #expect(blockCount(harness) == 1)
        #expect(Set(harness.paragraphBlocks.compactMap { $0?.codeGroup }).count == 1)
    }

    @Test func aMultiLinePasteKeepsOneBlockPerPastedBlock() {
        let harness = EditorHarness(markdown: "")
        #expect(harness.controller.paste(PastePayload(plainText: "Intro.\n\nOne.\n\nTwo."), replacing: harness.selection))
        #expect(harness.markdown == "Intro.\n\nOne.\n\nTwo.")
        #expect(blockCount(harness) == 3)
    }
}
#endif
