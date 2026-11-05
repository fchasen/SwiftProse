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
struct InputRuleTests {
    @Test func typingTripleHashSpaceProducesHeading3() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("### ")
        harness.settle()
        harness.type("T")
        #expect(harness.block(at: 0)?.headingLevel == 3)
        #expect(harness.markdown == "### T")
    }

    @Test func typingGreaterThanSpaceProducesSingleLine() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("> ")
        harness.settle()
        #expect(!harness.string.contains("\n"), "\(String(reflecting: harness.string))")
        harness.type("h")
        #expect(harness.string == "h")
        #expect(harness.paragraphBlocks.count == 1)
        #expect(harness.block(at: 0)?.containers.count == 1)
        #expect(harness.markdown == "> h")
    }

    @Test func blockquoteRuleLandsCursorAtStartOfBlockquoteLine() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("> ")
        harness.settle()
        #expect(harness.selection == NSRange(location: 0, length: 0))
    }

    @Test func blockquoteRuleAfterExistingContentProducesAdjacentLine() {
        let harness = EditorHarness(markdown: "Hello")
        harness.select(5)
        harness.insertNewline()
        harness.typeEach("> ")
        harness.settle()
        harness.type("q")
        #expect(harness.paragraphTexts == ["Hello", "q"])
        #expect(harness.block(at: 0) == .paragraph)
        #expect(harness.block(at: 6)?.containers.count == 1)
        #expect(harness.markdown == "Hello\n\n> q")
    }

    @Test func typingTaskListShorthandProducesTaskItem() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("- [ ] ")
        harness.settle()
        harness.type("todo")
        #expect(harness.block(at: 0)?.task?.isChecked == false)
        #expect(harness.markdown == "- [ ] todo")
    }

    @Test func typingCheckedTaskListShorthandProducesCheckedTaskItem() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("- [x] ")
        harness.settle()
        harness.type("done")
        #expect(harness.block(at: 0)?.task?.isChecked == true)
        #expect(harness.markdown == "- [x] done")
    }

    @Test func completingInlineCodeDoesNotAppendANewLine() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("`code`")
        harness.settle()
        #expect(harness.string == "code")
        #expect(harness.selection == NSRange(location: 4, length: 0))
        #expect(harness.markdown == "`code`")
    }

    @Test func completingInlineCodeBeforeFollowingLineKeepsExistingLineBreak() {
        let harness = EditorHarness(markdown: "hello \nnext")
        #expect(harness.string == "hello\u{2028}next")
        harness.select(5)
        harness.typeEach(" `code`")
        harness.settle()
        #expect(harness.string == "hello code\u{2028}next")
        #expect(harness.paragraphBlocks.count == 1)
        #expect(harness.markdown == "hello `code`\nnext")
    }

    @Test func typingOpeningBacktickDoesNotCreateAnotherLine() {
        let harness = EditorHarness(markdown: "hello")
        harness.select(5)
        harness.typeEach(" `")
        harness.settle()
        #expect(harness.string == "hello `")
        #expect(harness.block(at: 0) == .paragraph)
    }

    @Test func typingOpeningBacktickBeforeFollowingLineDoesNotInsertBlankLine() {
        let harness = EditorHarness(markdown: "hello\nnext")
        harness.select(5)
        harness.typeEach(" `")
        harness.settle()
        #expect(harness.string == "hello `\u{2028}next")
        #expect(harness.paragraphBlocks.count == 1)
        #expect(harness.markdown == "hello `\nnext")
    }

    @Test func roundTrippingOpeningBacktickDoesNotCreateAnotherLine() {
        let harness = EditorHarness(markdown: "hello")
        harness.select(5)
        harness.typeEach(" `")
        harness.settle()
        let markdown = harness.markdown
        #expect(markdown == "hello `")
        harness.controller.setMarkdown(markdown)
        #expect(harness.string == "hello `")
        #expect(!harness.string.contains("\n"))
    }

    @Test func inlineRulesMidLineLeaveAMarkdownFixpoint() {
        for trigger in ["**x**", "*x*", "~~x~~", "`x`"] {
            let harness = EditorHarness(markdown: "alpha beta gamma")
            harness.select(6)
            harness.typeEach(trigger)
            harness.settle()
            let markdown = harness.markdown
            let reloaded = EditorController(markdown: markdown)
            #expect(reloaded.serialize() == markdown, "\(trigger)")
        }
    }

    @Test func inlineRuleKeepsALiteralQuoteMarkerOnTheLine() {
        let harness = EditorHarness(markdown: "\\> alpha beta")
        #expect(harness.string == "> alpha beta")
        #expect(harness.block(at: 0) == .paragraph)
        harness.select(8)
        harness.typeEach("`x`")
        harness.settle()
        #expect(harness.string == "> alpha xbeta")
        #expect(harness.block(at: 0) == .paragraph)
        #expect(harness.markdown == "\\> alpha `x`beta")
    }

    @Test func inlineRuleOnASoftBrokenParagraphKeepsOneBlock() {
        let harness = EditorHarness(markdown: "one two\nthree four")
        let four = (harness.string as NSString).range(of: "four").location
        harness.select(four)
        harness.typeEach("`x`")
        harness.settle()
        #expect(harness.storage.markdownInlineIntent(at: four).contains(.code))
        #expect(harness.paragraphBlocks.count == 1)
        #expect(harness.markdown == "one two\nthree `x`four")
    }

    @Test func codeSpanRuleOverAStrongSpanExcludesStrong() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("**bold**")
        harness.settle()
        #expect(harness.storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
        harness.select(0)
        harness.typeEach("`")
        harness.select(harness.storage.length)
        harness.typeEach("`")
        harness.settle()
        #expect(harness.string == "bold")
        #expect(harness.storage.markdownInlineIntent(at: 0) == [.stronglyEmphasized, .code])
        #expect(harness.markdown == "**`bold`**")
    }

    @Test func inlineRuleInsideANestedListItemAppliesTheMark() {
        let harness = EditorHarness(markdown: "- alpha\n  - beta gamma")
        let gamma = (harness.string as NSString).range(of: "gamma").location
        #expect(harness.block(at: gamma)?.listDepth == 2)
        harness.select(gamma)
        harness.typeEach("`x`")
        harness.settle()
        #expect(harness.string == "alpha\nbeta xgamma")
        #expect(harness.storage.markdownInlineIntent(at: gamma) == .code)
        #expect(harness.block(at: gamma)?.listDepth == 2)
        #expect(harness.markdown == "- alpha\n  - beta `x`gamma")
    }

    @Test func undoAfterAnInlineRuleRestoresAMarkTheNewOneExcluded() {
        let harness = EditorHarness(markdown: "hello **bold** world")
        #expect(harness.storage.markdownInlineIntent(at: 6) == .stronglyEmphasized)
        wrapInBackticks("bold", in: harness)
        #expect(harness.storage.markdownInlineIntent(at: 6) == [.stronglyEmphasized, .code])
        #expect(harness.markdown == "hello **`bold`** world")
        undoToTheBottom(harness)
        #expect(harness.string == "hello bold world")
        #expect(harness.storage.markdownInlineIntent(at: 6) == .stronglyEmphasized)
        #expect(harness.markdown == "hello **bold** world")
    }

    @Test func undoAfterAnInlineRuleRestoresALinkWithItsHref() {
        let harness = EditorHarness(markdown: "[lbl](https://e.com)")
        #expect(harness.storage.markdownLink(at: 0) == "https://e.com")
        wrapInBackticks("lbl", in: harness)
        #expect(harness.storage.markdownInlineIntent(at: 0).contains(.code))
        undoToTheBottom(harness)
        #expect(!harness.storage.markdownInlineIntent(at: 0).contains(.code))
        #expect(harness.storage.markdownLink(at: 0) == "https://e.com")
        #expect(harness.markdown == "[lbl](https://e.com)")
    }

    @Test func aMarkTheNewOneExcludedLeavesNoRenderingAttribute() {
        let struck = EditorHarness(markdown: "~~s~~ tail")
        #expect(struck.storage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil)
        wrapInBackticks("s", in: struck)
        #expect(struck.storage.markdownInlineIntent(at: 0).contains(.code))
        #expect(struck.storage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil)
        #expect(struck.markdown == "~~`s`~~ tail")

        let linked = EditorHarness(markdown: "[lbl](https://e.com)")
        #expect(linked.storage.markdownLink(at: 0) != nil)
        wrapInBackticks("lbl", in: linked)
        #expect(linked.storage.markdownInlineIntent(at: 0).contains(.code))
        #expect(linked.storage.markdownLink(at: 0) == "https://e.com")
        #expect(linked.markdown == "[`lbl`](https://e.com)")
    }

    @Test func inlineRuleFlankingMatchesTheCompiler() {
        for trigger in ["** **", "**  **", "**x **", "** x **", "*  *", "~~x ~~"] {
            let harness = EditorHarness(markdown: "alpha beta gamma")
            harness.select(6)
            harness.typeEach(trigger)
            harness.settle()
            #expect(harness.string == "alpha \(trigger)beta gamma", "\(trigger)")
            #expect(intents(in: harness) == [], "\(trigger)")
        }
        for (trigger, storage, marked, written) in [
            ("` x `", "alpha  x beta gamma", NSRange(location: 6, length: 3), "`  x  `"),
            ("` `", "alpha  beta gamma", NSRange(location: 6, length: 1), "` `"),
        ] {
            let harness = EditorHarness(markdown: "alpha beta gamma")
            harness.select(6)
            harness.typeEach(trigger)
            harness.settle()
            #expect(harness.string == storage, "\(trigger)")
            #expect(intents(in: harness) == ["code@\(marked.location),\(marked.length)"], "\(trigger)")
            #expect(harness.markdown == "alpha \(written)beta gamma", "\(trigger)")
        }
    }

    @Test func typingTripleBacktickThenEnterOpensEmptyFencedBlock() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("```")
        harness.settle()
        harness.insertNewline()
        let block = harness.controller.paragraphInfo(at: harness.selection.location).block
        #expect(block.isCode)
        #expect(block.codeLanguage == nil)
        harness.type("x")
        #expect(harness.markdown == "```\nx\n```")
    }

    @Test func typingTripleBacktickAloneStaysParagraph() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("```")
        harness.settle()
        #expect(harness.string == "```")
        #expect(harness.block(at: 0) == .paragraph)
    }

    @Test func fencedCodeRuleBailsWhenLineAlreadyFenced() {
        let harness = EditorHarness(markdown: "```swift\nx\n```")
        harness.select(1)
        harness.insertNewline()
        harness.type("```")
        harness.insertNewline()
        #expect(harness.paragraphBlocks.allSatisfy { $0?.codeLanguage == "swift" })
        #expect(Set(harness.paragraphBlocks.compactMap { $0?.codeGroup }).count == 1)
    }

    @Test func enterOnPlainParagraphDoesNotOpenFencedBlock() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("hello")
        harness.settle()
        harness.insertNewline()
        #expect(harness.block(at: 0) == .paragraph)
        #expect(!harness.controller.paragraphInfo(at: harness.selection.location).block.isCode)
    }

    @Test func setMarkdownDoesNotFireInputRules() {
        let harness = EditorHarness(markdown: "")
        harness.controller.setMarkdown("# heading\n")
        harness.settle()
        #expect(harness.string == "heading")
        #expect(harness.block(at: 0)?.headingLevel == 1)
        #expect(harness.controller.serialize() == "# heading")
    }

    @Test func multiCharacterPasteDoesNotFireInputRules() {
        let harness = EditorHarness(markdown: "")
        harness.type("# pasted")
        harness.settle()
        #expect(harness.string == "# pasted")
        #expect(harness.block(at: 0) == .paragraph)
    }

    @Test func typedCodeSpanInAHeadingKeepsTheHeadingFont() throws {
        let harness = EditorHarness(markdown: "# Title code end")
        wrapInBackticks("code", in: harness)
        let at = (harness.string as NSString).range(of: "code").location
        let font = try #require(harness.storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace), "\(font.fontName)")
        let compiled = EditorHarness(markdown: "# Title `code` end")
        let compiledAt = (compiled.string as NSString).range(of: "code").location
        let compiledFont = try #require(compiled.storage.attribute(.font, at: compiledAt, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == compiledFont.pointSize)
        #expect(font.fontName == compiledFont.fontName)
    }

    @Test func undoOfACodeSpanInAHeadingRestoresTheHeadingFont() throws {
        let harness = EditorHarness(markdown: "# Title code end")
        let before = try #require(
            harness.storage.attribute(.font, at: (harness.string as NSString).range(of: "code").location, effectiveRange: nil) as? NSFont
        )
        wrapInBackticks("code", in: harness)
        undoToTheBottom(harness)
        let at = (harness.string as NSString).range(of: "code").location
        let after = try #require(harness.storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        #expect(harness.string == "Title code end")
        #expect(after.pointSize == before.pointSize)
        #expect(after.fontName == before.fontName)
    }

    private func intents(in harness: EditorHarness) -> [String] {
        let storage = harness.storage
        var found: [String] = []
        storage.enumerateAttribute(.markdownInlineIntent, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let intent = MarkdownInlineIntent(attributeValue: value) ?? []
            if intent.contains(.code) { found.append("code@\(range.location),\(range.length)") }
            if intent.contains(.stronglyEmphasized) { found.append("strong@\(range.location),\(range.length)") }
            if intent.contains(.emphasized) { found.append("em@\(range.location),\(range.length)") }
            if intent.contains(.strikethrough) { found.append("strike@\(range.location),\(range.length)") }
        }
        return found
    }

    private func wrapInBackticks(_ substring: String, in harness: EditorHarness) {
        let opening = (harness.string as NSString).range(of: substring)
        harness.select(opening.location)
        harness.typeEach("`")
        let closing = (harness.string as NSString).range(of: substring)
        harness.select(NSMaxRange(closing))
        harness.typeEach("`")
        harness.settle()
    }

    private func undoToTheBottom(_ harness: EditorHarness, limit: Int = 16) {
        var steps = 0
        while harness.undoManager.canUndo, steps < limit {
            harness.undo()
            harness.settle()
            steps += 1
        }
    }
}
#endif
