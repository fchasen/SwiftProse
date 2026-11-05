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
struct InlineContentTests {
    private static let navPattern = #"\{nav(?:\s+|\s*,\s*)icon=([A-Za-z0-9_\-]+)\s*,\s*name=([^}\n]*)\}"#

    nonisolated private static func navRule() -> InlineContentRule {
        InlineContentRule(id: "nav", pattern: navPattern) { match in
            guard let icon = match.capture(1), let name = match.capture(2) else { return nil }
            return .custom(kind: "navLabel", label: name, systemImage: icon)
        }
    }

    private static let provider: ProseInlineContentProvider = { ChipAttachment.make(for: $0) }

    private func load(
        _ markdown: String,
        rules: [InlineContentRule]? = nil,
        provider: ProseInlineContentProvider? = nil
    ) -> NSMutableAttributedString {
        MarkdownLoader(inlineContentRules: rules ?? [Self.navRule()], inlineContentProvider: provider ?? Self.provider).load(markdown)
    }

    private func roundTrip(_ markdown: String) -> String {
        MarkdownWriter().markdown(from: load(markdown))
    }

    private func controller(_ markdown: String) -> EditorController {
        EditorController(
            markdown: markdown,
            inlineContentRules: [Self.navRule()],
            inlineContentProvider: Self.provider
        )
    }

    private func harness(_ markdown: String) -> EditorHarness {
        let harness = EditorHarness(markdown: markdown)
        harness.controller.setInlineContent(rules: [Self.navRule()], provider: Self.provider)
        harness.undoManager.removeAllActions()
        harness.clearPushes()
        return harness
    }

    @Test func theSurroundingTextKeepsTheParagraphPath() throws {
        let out = load("{nav, icon=comment, name=thought:} ok\n")
        #expect(out.proseSourceAttachment(at: 0) != nil)
        #expect(out.markdownBlock(at: 2) == .paragraph)
        #expect(out.markdownBlock(at: 0) == out.markdownBlock(at: 2))
        #expect(out.markdownParagraphRanges().filter { $0.length > 0 }.count == 1)
    }

    @Test func aMatchMidParagraphSplicesInPlace() throws {
        let out = load("see {nav, icon=bug, name=issue:} here\n")
        #expect(out.string == "see \u{FFFC} here")
        #expect(out.proseSourceAttachment(at: 4)?.contentKind == "navLabel")
    }

    @Test func aRuleReturningNilLeavesTheSourceVisible() {
        let rule = InlineContentRule(id: "nav", pattern: Self.navPattern) { _ in nil }
        let out = load("{nav, icon=bug, name=issue:} x\n", rules: [rule])
        #expect(out.string == "{nav, icon=bug, name=issue:} x")
    }

    @Test func aMatchInsideALinkLabelIsSkipped() {
        let source = "[{nav, icon=bug, name=issue:}](https://example.com)"
        let out = load(source)
        #expect(out.string == "{nav, icon=bug, name=issue:}")
        #expect(roundTrip(source) == source)
    }

    @Test func theSourceRoundTripsByteForByte() {
        let source = "{nav,  icon=sticky-note, name=note:} looks good"
        #expect(roundTrip(source) == source)
    }

    @Test func theSingleSpaceSpellingRoundTripsToo() {
        let source = "{nav, icon=sticky-note, name=note:} looks good"
        #expect(roundTrip(source) == source)
    }

    @Test func theSpaceSeparatedSpellingRoundTrips() {
        let source = "{nav icon=sticky-note, name=note:} looks good"
        #expect(roundTrip(source) == source)
    }

    @Test func aMidSentenceTokenRoundTrips() {
        let source = "see {nav, icon=bug, name=issue:} here"
        #expect(roundTrip(source) == source)
    }

    @Test func aTokenBesideOtherInlineMarkupRoundTrips() {
        let source = "{nav, icon=bug, name=issue:} **bold** and `code`"
        #expect(roundTrip(source) == source)
    }

    @Test func aTokenInAListItemRoundTrips() {
        let source = "- {nav, icon=bug, name=issue:} item"
        #expect(roundTrip(source) == source)
    }

    @Test func aTokenInACodeSpanRoundTripsAsLiteralSource() {
        let source = "`{nav, icon=bug, name=issue:}` x"
        #expect(roundTrip(source) == source)
    }

    @Test func aRecompilePreservesTheToken() {
        let controller = controller("{nav,  icon=sticky-note, name=note:} looks good\n")
        for _ in 0..<3 {
            controller.setMarkdown(controller.markdown())
        }
        #expect(controller.textStorage.string == "\u{FFFC} looks good")
        #expect(controller.markdown() == "{nav,  icon=sticky-note, name=note:} looks good\n")
    }

    @Test func typingImmediatelyBeforeTheIconKeepsTheToken() {
        let harness = harness("{nav, icon=bug, name=issue:} ok\n")
        harness.select(0)
        harness.type("x")
        harness.settle()
        #expect(harness.markdown == "x{nav, icon=bug, name=issue:} ok")
    }

    @Test func deletingTheRestOfTheLineLeavesTheTokenAlone() {
        let harness = harness("{nav, icon=bug, name=issue:} ok\n")
        harness.select(NSRange(location: 1, length: 3))
        harness.deleteBackward()
        harness.settle()
        #expect(harness.string == "\u{FFFC}")
        #expect(harness.markdown == "{nav, icon=bug, name=issue:}")
    }

    @Test func insertMarkdownCollapsesTheTokenImmediately() {
        let controller = controller("looks good\n")
        controller.setSelection(NSRange(location: 0, length: 0))
        #expect(controller.insertMarkdown("{nav, icon=sticky-note, name=note:} "))
        #expect(controller.textStorage.string.hasPrefix("\u{FFFC} looks good"))
        #expect(controller.markdown() == "{nav, icon=sticky-note, name=note:} looks good")
    }

    @Test func insertMarkdownMergesIntoTheParagraphItLandsIn() {
        let controller = controller("first\n\nsecond\n")
        let paragraphTwo = (controller.textStorage.string as NSString).range(of: "second").location
        controller.setSelection(NSRange(location: paragraphTwo, length: 0))
        #expect(controller.insertMarkdown("{nav, icon=bug, name=issue:} "))
        #expect(controller.markdown() == "first\n\n{nav, icon=bug, name=issue:} second")
    }

    @Test func insertMarkdownReplacesASelectedLabel() {
        let controller = controller("{nav, icon=bug, name=issue:} ok\n")
        controller.setSelection(NSRange(location: 0, length: 2))
        #expect(controller.insertMarkdown("{nav, icon=sticky-note, name=note:} "))
        #expect(controller.markdown() == "{nav, icon=sticky-note, name=note:} ok")
    }

    @Test func aMatchOverlappingItsOwnInlineDelimitersIsDeclined() {
        let rule = InlineContentRule(id: "strike", pattern: "~~DONE~~") { _ in
            .custom(kind: "done", label: "done", systemImage: "checkmark")
        }
        let source = "a ~~DONE~~ b"
        let out = load(source, rules: [rule])
        #expect(!out.string.contains("\u{FFFC}"))
        #expect(MarkdownWriter().markdown(from: out) == source)
    }

    @Test func aMatchReachingIntoABlockMarkerIsDeclined() {
        let rule = InlineContentRule(id: "nav", pattern: #"\s?\{nav[^}\n]*\}"#) { _ in
            .custom(kind: "navLabel", label: "note:", systemImage: "note")
        }
        for source in [
            "- {nav, icon=bug, name=issue:} item",
            "# {nav, icon=bug, name=issue:} title",
            "> {nav, icon=bug, name=issue:} quoted",
        ] {
            #expect(
                MarkdownWriter().markdown(from: load(source, rules: [rule])) == source,
                "lost the token in \(source.debugDescription)"
            )
        }
    }

    @Test func anIconAloneOnALineKeepsItsSource() {
        let harness = harness("{nav, icon=bug, name=issue:}\n")
        #expect(harness.markdown == "{nav, icon=bug, name=issue:}")
        harness.select(1)
        harness.type("x")
        harness.settle()
        harness.deleteBackward()
        harness.settle()
        #expect(harness.markdown == "{nav, icon=bug, name=issue:}")
    }

    @Test func anIconDoesNotSplitItsParagraphInTwo() {
        let harness = harness("{nav, icon=bug, name=issue:} ok\n")
        harness.select(harness.storage.length)
        harness.type("!")
        harness.settle()
        #expect(harness.paragraphBlocks == [.paragraph])
        #expect(harness.markdown == "{nav, icon=bug, name=issue:} ok!")
    }

    @Test func blockTogglesKeepTheIconOnOneLine() {
        for action in [EditorAction.blockquote, .heading(level: 2), .unorderedList] {
            let controller = controller("{nav, icon=bug, name=issue:} ok\n")
            controller.setSelection(NSRange(location: 2, length: 0))
            controller.perform(action)
            let markdown = controller.markdown()
            #expect(markdown.contains("{nav, icon=bug, name=issue:} ok"), "\(action) produced \(markdown.debugDescription)")
            #expect(markdown.components(separatedBy: "\n").count <= 2, "\(action) split the line")
            #expect(controller.textStorage.markdownParagraphRanges().filter { $0.length > 0 }.count == 1)
        }
    }

    @Test func aBlockToggleRoundTripsBackToThePlainParagraph() {
        let controller = controller("{nav, icon=bug, name=issue:} ok\n")
        controller.setSelection(NSRange(location: 2, length: 0))
        controller.perform(.blockquote)
        #expect(controller.markdown() == "> {nav, icon=bug, name=issue:} ok")
        controller.perform(.blockquote)
        #expect(controller.markdown() == "{nav, icon=bug, name=issue:} ok\n")
    }

    @Test func aSoftWrappedParagraphKeepsItsLineBreak() {
        let source = "line one\n{nav, icon=bug, name=issue:} line two"
        #expect(roundTrip(source) == source)
    }

    @Test func aHeadingLeadingWithAnIconStillReadsAsAHeading() {
        let controller = controller("## {nav, icon=bug, name=issue:} title\n")
        #expect(controller.textStorage.proseSourceAttachment(at: 0) != nil)
        #expect(controller.textStorage.markdownBlock(at: 0)?.headingLevel == 2)
    }

    @Test func inlineMarksOnTheLeafSurviveSerialization() {
        let source = "**{nav, icon=bug, name=issue:}** ok"
        let out = load(source)
        #expect(out.string == "\u{FFFC} ok")
        #expect(roundTrip(source) == source)
    }

    @Test func aClipboardRoundTripPreservesTheExactSource() {
        let controller = controller("{nav,  icon=sticky-note, name=note:} looks good\n")
        let copied = controller.markdownForCopy(range: NSRange(location: 0, length: controller.textStorage.length))
        #expect(copied.components(separatedBy: "{nav,  icon=sticky-note, name=note:}").count == 2)
        let target = self.controller("")
        #expect(target.insertMarkdown(copied))
        #expect(target.textStorage.string == "\u{FFFC} looks good")
        #expect(target.markdown() == "{nav,  icon=sticky-note, name=note:} looks good")
    }

    @Test func plainTextCopyEmitsTheSource() {
        let controller = controller("{nav, icon=bug, name=issue:} ok\n")
        let copied = controller.markdownForCopy(range: NSRange(location: 0, length: controller.textStorage.length))
        #expect(copied == "{nav, icon=bug, name=issue:} ok")
    }
}
#endif
