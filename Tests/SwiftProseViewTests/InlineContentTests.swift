import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView

#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct InlineContentTests {

    /// The Mozilla `phab-conventional-comments` token, double space and all.
    private static let navPattern = #"\{nav(?:\s+|\s*,\s*)icon=([A-Za-z0-9_\-]+)\s*,\s*name=([^}\n]*)\}"#

    private static func navRule() -> InlineContentRule {
        InlineContentRule(id: "nav", pattern: navPattern) { match in
            guard let icon = match.capture(1), let name = match.capture(2) else { return nil }
            return .custom(kind: "navLabel", label: name, systemImage: icon)
        }
    }

    private static func provider() -> ProseInlineContentProvider {
        { _ in NSTextAttachment() }
    }

    private func compiler() throws -> MarkdownAttributedCompiler {
        try MarkdownAttributedCompiler(
            inlineContentRules: [Self.navRule()],
            inlineContentProvider: Self.provider()
        )
    }

    private func controller(_ markdown: String) throws -> EditorController {
        try EditorController(
            initialMarkdown: markdown,
            theme: .default,
            inlineContentRules: [Self.navRule()],
            inlineContentProvider: Self.provider()
        )
    }

    // MARK: - splice

    @Test func aMatchCollapsesToOneAttachmentCharacter() throws {
        let out = try compiler().compile("{nav,  icon=sticky-note, name=note:} looks good\n", theme: .default)
        #expect(out.string == "\u{FFFC} looks good\n")
        #expect(out.attribute(.attachment, at: 0, effectiveRange: nil) != nil)
    }

    @Test func theSplicedCharacterCarriesAnInlineContentLeaf() throws {
        let out = try compiler().compile("{nav, icon=sticky-note, name=note:} ok\n", theme: .default)
        let leaf = try #require(out.nodePath(at: 0)?.leaf)
        #expect(leaf.type == "inline_content")
        #expect(leaf.attrs["kind"]?.stringValue == "navLabel")
        #expect(leaf.attrs["raw"]?.stringValue == "{nav, icon=sticky-note, name=note:}")
    }

    @Test func theSurroundingTextKeepsTheParagraphPath() throws {
        let out = try compiler().compile("{nav, icon=comment, name=thought:} ok\n", theme: .default)
        let paragraph = try #require(out.nodePath(at: 2)?.leaf)
        #expect(paragraph.type == "paragraph")
        // The leaf hangs off that same paragraph node, identity included.
        let leafPath = try #require(out.nodePath(at: 0))
        #expect(leafPath.droppingLast().leaf?.id == paragraph.id)
    }

    @Test func aMatchMidParagraphSplicesInPlace() throws {
        let out = try compiler().compile("see {nav, icon=bug, name=issue:} here\n", theme: .default)
        #expect(out.string == "see \u{FFFC} here\n")
        #expect(out.nodePath(at: 4)?.leaf?.type == "inline_content")
    }

    @Test func twoMatchesOnOneLineBothSplice() throws {
        let source = "{nav, icon=bug, name=issue:} and {nav, icon=comment, name=note:}\n"
        let out = try compiler().compile(source, theme: .default)
        #expect(out.string == "\u{FFFC} and \u{FFFC}\n")
        #expect(out.nodePath(at: 0)?.leaf?.attrs["raw"]?.stringValue == "{nav, icon=bug, name=issue:}")
        #expect(out.nodePath(at: 6)?.leaf?.attrs["raw"]?.stringValue == "{nav, icon=comment, name=note:}")
    }

    @Test func aMatchInsideAHeadingSplices() throws {
        let out = try compiler().compile("# {nav, icon=bug, name=issue:} title\n", theme: .default)
        #expect(out.string == "\u{FFFC} title\n")
    }

    @Test func aMatchInsideAListItemSplices() throws {
        let out = try compiler().compile("- {nav, icon=bug, name=issue:} item\n", theme: .default)
        // The bullet's own marker attachment leads, then the spliced label.
        #expect(out.string == "\u{FFFC} \u{FFFC} item\n")
        #expect(out.nodePath(at: 2)?.leaf?.type == "inline_content")
    }

    // MARK: - opting out

    @Test func withoutAProviderTheSourceStaysVisible() throws {
        let compiler = try MarkdownAttributedCompiler(inlineContentRules: [Self.navRule()])
        let out = compiler.compile("{nav, icon=bug, name=issue:} x\n", theme: .default)
        #expect(out.string == "{nav, icon=bug, name=issue:} x\n")
    }

    @Test func aRuleReturningNilLeavesTheSourceVisible() throws {
        let rule = InlineContentRule(id: "nav", pattern: Self.navPattern) { _ in nil }
        let compiler = try MarkdownAttributedCompiler(
            inlineContentRules: [rule],
            inlineContentProvider: Self.provider()
        )
        let out = compiler.compile("{nav, icon=bug, name=issue:} x\n", theme: .default)
        #expect(out.string == "{nav, icon=bug, name=issue:} x\n")
    }

    @Test func aProviderReturningNilLeavesTheSourceVisible() throws {
        let compiler = try MarkdownAttributedCompiler(
            inlineContentRules: [Self.navRule()],
            inlineContentProvider: { _ in nil }
        )
        let out = compiler.compile("{nav, icon=bug, name=issue:} x\n", theme: .default)
        #expect(out.string == "{nav, icon=bug, name=issue:} x\n")
    }

    // MARK: - exclusions

    @Test func aMatchInsideACodeSpanIsSkipped() throws {
        let source = "`{nav, icon=bug, name=issue:}` x\n"
        let out = try compiler().compile(source, theme: .default)
        #expect(out.string == "{nav, icon=bug, name=issue:} x\n")
    }

    @Test func aMatchInsideAFencedBlockIsSkipped() throws {
        let source = "```\n{nav, icon=bug, name=issue:}\n```\n"
        let out = try compiler().compile(source, theme: .default)
        #expect(out.string.contains("{nav, icon=bug, name=issue:}"))
    }

    @Test func aMatchInsideALinkLabelIsSkipped() throws {
        // A leaf under a link mark would lose the mark on the way back out.
        let source = "[{nav, icon=bug, name=issue:}](https://example.com)\n"
        let out = try compiler().compile(source, theme: .default)
        #expect(out.string == "{nav, icon=bug, name=issue:}\n")
        #expect(try roundTrip(source) == source)
    }

    // MARK: - round trip

    private func roundTrip(_ markdown: String) throws -> String {
        let attributed = try compiler().compile(markdown, theme: .default)
        return AttributedMarkdownSerializer().serialize(attributed)
    }

    @Test func theSourceRoundTripsByteForByte() throws {
        let source = "{nav,  icon=sticky-note, name=note:} looks good\n"
        #expect(try roundTrip(source) == source)
    }

    @Test func theSingleSpaceSpellingRoundTripsToo() throws {
        let source = "{nav, icon=sticky-note, name=note:} looks good\n"
        #expect(try roundTrip(source) == source)
    }

    @Test func theSpaceSeparatedSpellingRoundTrips() throws {
        let source = "{nav icon=sticky-note, name=note:} looks good\n"
        #expect(try roundTrip(source) == source)
    }

    @Test func aMidSentenceTokenRoundTrips() throws {
        let source = "see {nav, icon=bug, name=issue:} here\n"
        #expect(try roundTrip(source) == source)
    }

    @Test func aTokenBesideOtherInlineMarkupRoundTrips() throws {
        let source = "{nav, icon=bug, name=issue:} **bold** and `code`\n"
        #expect(try roundTrip(source) == source)
    }

    @Test func aTokenInAListItemRoundTrips() throws {
        let source = "- {nav, icon=bug, name=issue:} item\n"
        #expect(try roundTrip(source) == source)
    }

    @Test func aTokenInACodeSpanRoundTripsAsLiteralSource() throws {
        let source = "`{nav, icon=bug, name=issue:}` x\n"
        #expect(try roundTrip(source) == source)
    }

    @Test func theControllerSerializesTheTokenBack() throws {
        let controller = try self.controller("{nav,  icon=sticky-note, name=note:} looks good\n")
        #expect(controller.markdown() == "{nav,  icon=sticky-note, name=note:} looks good")
    }

    @Test func aRecompilePreservesTheToken() throws {
        let controller = try self.controller("{nav,  icon=sticky-note, name=note:} looks good\n")
        for _ in 0..<3 {
            controller.setMarkdown(controller.markdown(), async: false)
        }
        #expect(controller.markdown() == "{nav,  icon=sticky-note, name=note:} looks good")
    }

    // MARK: - editing around the icon

    @Test func typingOnTheLineKeepsTheToken() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        // Caret at the end of "ok".
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: "!")
        #expect(controller.markdown() == "{nav, icon=bug, name=issue:} ok!")
    }

    @Test func typingRightAfterTheIconDoesNotExtendTheLeaf() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        controller.testSelection = NSRange(location: 1, length: 0)
        controller.insert(text: "x")
        #expect(controller.markdown() == "{nav, icon=bug, name=issue:}x ok")
        #expect(controller.textStorage.nodePath(at: 1)?.leaf?.type == "paragraph")
    }

    @Test func typingImmediatelyBeforeTheIconKeepsTheToken() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.insert(text: "x")
        #expect(controller.markdown() == "x{nav, icon=bug, name=issue:} ok")
    }

    /// The icon is one character, so an ordinary one-character delete takes the
    /// whole token — no `.proseListMarker`-style special case needed.
    @Test func theIconIsASingleCharacter() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        controller.testSelection = NSRange(location: 1, length: 0)
        #expect(controller.handleBackspace() == false)
        controller.testSelection = NSRange(location: 0, length: 1)
        controller.insert(text: "")
        #expect(controller.markdown() == " ok")
    }

    @Test func deletingTheRestOfTheLineLeavesTheTokenAlone() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        controller.testSelection = NSRange(location: 1, length: 3)
        controller.insert(text: "")
        #expect(controller.markdown() == "{nav, icon=bug, name=issue:}")
    }

    // MARK: - insertion

    @Test func insertMarkdownCollapsesTheTokenImmediately() throws {
        let controller = try self.controller("looks good\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        #expect(controller.insertMarkdown("{nav, icon=sticky-note, name=note:} "))
        #expect(controller.textStorage.string.hasPrefix("\u{FFFC} looks good"))
        #expect(controller.markdown() == "{nav, icon=sticky-note, name=note:} looks good")
    }

    @Test func insertMarkdownMergesIntoTheParagraphItLandsIn() throws {
        let controller = try self.controller("first\n\nsecond\n")
        let paragraphTwo = (controller.textStorage.string as NSString).range(of: "second").location
        controller.testSelection = NSRange(location: paragraphTwo, length: 0)
        #expect(controller.insertMarkdown("{nav, icon=bug, name=issue:} "))
        #expect(controller.markdown() == "first\n\n{nav, icon=bug, name=issue:} second")
    }

    @Test func insertMarkdownReplacesASelectedLabel() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        controller.testSelection = NSRange(location: 0, length: 2)
        #expect(controller.insertMarkdown("{nav, icon=sticky-note, name=note:} "))
        #expect(controller.markdown() == "{nav, icon=sticky-note, name=note:} ok")
    }

    // MARK: - regressions

    /// A rule that reaches into markup the block owns is declined rather than
    /// half-applied: the strip would eat the characters the leaf needs and the
    /// source would be gone with nothing left to round-trip.
    @Test func aMatchOverlappingItsOwnInlineDelimitersIsDeclined() throws {
        let rule = InlineContentRule(id: "strike", pattern: "~~DONE~~") { _ in
            .custom(kind: "done", label: "done", systemImage: "checkmark")
        }
        let compiler = try MarkdownAttributedCompiler(
            inlineContentRules: [rule],
            inlineContentProvider: Self.provider()
        )
        let source = "a ~~DONE~~ b\n"
        let out = compiler.compile(source, theme: .default)
        #expect(!out.string.contains("\u{FFFC}"))
        #expect(AttributedMarkdownSerializer().serialize(out) == source)
    }

    @Test func aMatchReachingIntoABlockMarkerIsDeclined() throws {
        let rule = InlineContentRule(id: "nav", pattern: #"\s?\{nav[^}\n]*\}"#) { _ in
            .custom(kind: "navLabel", label: "note:", systemImage: "note")
        }
        let compiler = try MarkdownAttributedCompiler(
            inlineContentRules: [rule],
            inlineContentProvider: Self.provider()
        )
        for source in [
            "- {nav, icon=bug, name=issue:} item\n",
            "# {nav, icon=bug, name=issue:} title\n",
            "> {nav, icon=bug, name=issue:} quoted\n"
        ] {
            #expect(
                AttributedMarkdownSerializer().serialize(compiler.compile(source, theme: .default)) == source,
                "lost the token in \(source.debugDescription)"
            )
        }
    }

    /// A line whose only stamped run is the leaf has no block path to elect;
    /// the line-collapsing pass mints one and must re-hang the leaf on it.
    @Test func anIconAloneOnALineKeepsItsSource() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:}\n")
        #expect(controller.markdown() == "{nav, icon=bug, name=issue:}")
        controller.testSelection = NSRange(location: 1, length: 0)
        controller.insert(text: "x")
        controller.testSelection = NSRange(location: 1, length: 1)
        controller.insert(text: "")
        #expect(controller.markdown() == "{nav, icon=bug, name=issue:}")
    }

    @Test func deletingEverythingAfterTheIconKeepsIt() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        controller.testSelection = NSRange(location: 1, length: 3)
        controller.insert(text: "")
        #expect(controller.markdown() == "{nav, icon=bug, name=issue:}")
    }

    @Test func anIconDoesNotSplitItsParagraphInTwo() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: "!")
        let doc = ProseDocument.from(storage: controller.textStorage, schema: .defaultMarkdown)
        guard case .structural(_, let blocks) = doc.root else {
            Issue.record("expected a structural root")
            return
        }
        #expect(blocks.count == 1)
    }

    /// A block toggle re-renders the line and re-stamps it; the leaf's run is a
    /// run of its own and must not become a block of its own.
    @Test func blockTogglesKeepTheIconOnOneLine() throws {
        for action in [EditorAction.blockquote, .heading(level: 2), .unorderedList] {
            let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
            controller.testSelection = NSRange(location: 2, length: 0)
            controller.perform(action)
            let markdown = controller.markdown()
            #expect(
                markdown.contains("{nav, icon=bug, name=issue:} ok"),
                "\(action) produced \(markdown.debugDescription)"
            )
            #expect(markdown.components(separatedBy: "\n").count <= 2, "\(action) split the line")
        }
    }

    @Test func aBlockToggleRoundTripsBackToThePlainParagraph() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        controller.testSelection = NSRange(location: 2, length: 0)
        controller.perform(.blockquote)
        #expect(controller.markdown() == "> {nav, icon=bug, name=issue:} ok")
        controller.perform(.blockquote)
        #expect(controller.markdown() == "{nav, icon=bug, name=issue:} ok")
    }

    /// The leaf splits its paragraph into several `proseNodePath` runs; only
    /// the last of them ends the block, so only that one loses its newline.
    @Test func aSoftWrappedParagraphKeepsItsLineBreak() throws {
        let source = "line one\n{nav, icon=bug, name=issue:} line two\n"
        #expect(try roundTrip(source) == source)
    }

    @Test func anIconLeadingALineDoesNotHideItsBlockSpec() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .paragraph)
    }

    @Test func aHeadingLeadingWithAnIconStillReadsAsAHeading() throws {
        let controller = try self.controller("## {nav, icon=bug, name=issue:} title\n")
        #expect(controller.textStorage.blockSpec(at: 0)?.kind == .heading(level: 2))
    }

    @Test func inlineMarksOnTheLeafSurviveSerialization() throws {
        let source = "**{nav, icon=bug, name=issue:}** ok\n"
        let out = try compiler().compile(source, theme: .default)
        #expect(out.string == "\u{FFFC} ok\n")
        #expect(try roundTrip(source) == source)
    }

    @Test func aClipboardRoundTripPreservesTheExactSource() throws {
        let source = "{nav,  icon=sticky-note, name=note:} looks good\n"
        let controller = try self.controller(source)
        let full = NSRange(location: 0, length: controller.textStorage.length)
        let slice = controller.sliceForRange(full)
        let html = DOMSerializer().serialize(slice.content)
        let parsed = try #require(DOMParser().parse(html))
        let back = MarkdownTreeSerializer(schema: .defaultMarkdown).serializeSlice(parsed)
        #expect(back.contains("{nav,  icon=sticky-note, name=note:}"))
        #expect(!back.contains("{nav,  icon=sticky-note, name=note:}{nav"))
    }

    @Test func aProseMirrorRoundTripKeepsTheSource() throws {
        let controller = try self.controller("{nav,  icon=sticky-note, name=note:} looks good\n")
        let json = try controller.exportProseMirrorJSON()
        let reloaded = try self.controller("")
        try reloaded.loadProseMirrorJSON(json)
        #expect(reloaded.markdown() == "{nav,  icon=sticky-note, name=note:} looks good")
    }

    // MARK: - clipboard and codec

    @Test func plainTextCopyEmitsTheSource() throws {
        let controller = try self.controller("{nav, icon=bug, name=issue:} ok\n")
        let full = NSRange(location: 0, length: controller.textStorage.length)
        let slice = controller.sliceForRange(full)
        #expect(PlainTextSerializer().serialize(slice.content) == "{nav, icon=bug, name=issue:} ok")
    }
}
