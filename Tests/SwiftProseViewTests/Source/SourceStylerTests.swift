import Foundation
import Testing
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
final class SourceProbe {
    let controller: SourceEditorController

    init(_ text: String, highlighter: CodeBlockHighlighter? = nil) {
        controller = SourceEditorController(text: text, codeBlockHighlighter: highlighter)
    }

    var storage: NSTextStorage { controller.textStorage }
    var ns: NSString { storage.string as NSString }
    var theme: ProseTheme { controller.theme }
    var source: SourceStyle { theme.source }
    var lastLines: [String] { controller.styler.lastPass.lines.map { ns.substring(with: $0) } }

    func range(of needle: String, after anchor: String? = nil) -> NSRange {
        var searchStart = 0
        if let anchor {
            let found = ns.range(of: anchor)
            searchStart = found.location == NSNotFound ? 0 : NSMaxRange(found)
        }
        return ns.range(of: needle, range: NSRange(location: searchStart, length: ns.length - searchStart))
    }

    func location(of needle: String, after anchor: String? = nil) -> Int {
        range(of: needle, after: anchor).location
    }

    func color(at index: Int) -> PlatformColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? PlatformColor
    }

    func font(at index: Int) -> PlatformFont? {
        storage.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont
    }

    func isColor(_ color: PlatformColor, _ needle: String, after anchor: String? = nil) -> Bool {
        let range = range(of: needle, after: anchor)
        guard range.location != NSNotFound else { return false }
        return (range.location..<NSMaxRange(range)).allSatisfy { self.color(at: $0)?.isEqual(color) == true }
    }

    func traits(_ needle: String, after anchor: String? = nil) -> FontTraits {
        let range = range(of: needle, after: anchor)
        return font(at: range.location)?.fontTraits ?? []
    }

    func isCodeBlock(_ needle: String) -> Bool {
        storage.markdownBlock(at: location(of: needle))?.isCode == true
    }

    func edit(_ range: NSRange, _ replacement: String) {
        storage.replaceCharacters(in: range, with: replacement)
    }

    func insert(_ text: String, at location: Int) {
        edit(NSRange(location: location, length: 0), text)
    }

    var codeBodies: [String] {
        CodeHighlighting.extents(in: storage).map { CodeBody(storage, range: $0.body).text as String }
    }

    func highlightMismatches() -> [String] {
        var failures: [String] = []
        for extent in CodeHighlighting.extents(in: storage) {
            let body = CodeBody(storage, range: extent.body)
            let expected = CodeHighlightProbe.expectedColors(body: body.text, base: controller.styler.codeBaseColor)
            for (offset, color) in expected.enumerated() {
                let location = body.storageRanges(for: NSRange(location: offset, length: 1))[0].location
                if self.color(at: location)?.isEqual(color) != true { failures.append("offset \(offset)") }
            }
        }
        return failures
    }
}

@Suite("Source styler tokens")
@MainActor
struct SourceStylerTokenTests {
    static let document = """
    # Heading *em* ##
    Setext
    ======
    Para **strong** _em_ ~~gone~~ `code` [text](https://x.test "t") ![alt](img.png) <https://auto.test> https://bare.test \\* <span>h</span>
    - item
    1. [x] done
    > quote
    | a | b |
    |---|:-:|
    | 1 | 2 |

        indented

    ```swift
    let x = 1
    ```
    ***
    <div>
    block
    </div>

    [ref]: https://ref.test
    """

    @Test func headingsUseSyntaxMarkersAndBoldText() {
        let probe = SourceProbe(Self.document)
        #expect(probe.isColor(probe.source.syntaxColor, "#"))
        #expect(probe.isColor(probe.source.headingColor, "Heading"))
        #expect(probe.traits("Heading").contains(.bold))
        #expect(probe.traits("em", after: "Heading ").contains(.italic))
        #expect(probe.isColor(probe.source.syntaxColor, "##"))
        #expect(probe.traits("Setext").contains(.bold))
        #expect(probe.isColor(probe.source.syntaxColor, "======"))
    }

    @Test func inlineMarksStyleTheirContentAndDelimiters() {
        let probe = SourceProbe(Self.document)
        #expect(probe.isColor(probe.source.syntaxColor, "**", after: "Para "))
        #expect(probe.traits("strong").contains(.bold))
        #expect(probe.traits("em", after: "strong** _").contains(.italic))
        #expect(probe.isColor(probe.source.syntaxColor, "_", after: "strong** "))
        let gone = probe.range(of: "gone")
        #expect(probe.storage.attribute(.strikethroughStyle, at: gone.location, effectiveRange: nil) != nil)
        #expect(probe.isColor(probe.source.syntaxColor, "~~"))
        #expect(probe.isColor(probe.source.codeColor, "code"))
        #expect(probe.isColor(probe.source.syntaxColor, "`", after: "gone~~ "))
        #expect(probe.controller.isLocationInCode(probe.location(of: "code") + 1))
        #expect(!probe.traits("Para").contains(.bold))
        #expect(probe.isColor(probe.theme.foregroundColor, "Para"))
    }

    @Test func linksImagesAndAutolinks() {
        let probe = SourceProbe(Self.document)
        #expect(probe.isColor(probe.theme.linkColor, "text", after: "`code` ["))
        #expect(probe.isColor(probe.source.urlColor, "https://x.test \"t\""))
        #expect(probe.isColor(probe.source.syntaxColor, "](", after: "[text"))
        #expect(probe.isColor(probe.source.syntaxColor, "![", after: "\"t\") "))
        #expect(probe.isColor(probe.theme.linkColor, "alt"))
        #expect(probe.isColor(probe.source.urlColor, "img.png"))
        #expect(probe.isColor(probe.source.urlColor, "https://auto.test"))
        #expect(probe.isColor(probe.source.syntaxColor, "<", after: "img.png) "))
        #expect(probe.isColor(probe.source.urlColor, "https://bare.test"))
    }

    @Test func escapesAndInlineHTML() {
        let probe = SourceProbe(Self.document)
        let escape = probe.location(of: "\\*")
        #expect(probe.color(at: escape)?.isEqual(probe.source.syntaxColor) == true)
        #expect(probe.color(at: escape + 1)?.isEqual(probe.theme.foregroundColor) == true)
        #expect(probe.isColor(probe.source.htmlColor, "<span>"))
        #expect(probe.isColor(probe.source.htmlColor, "</span>"))
        #expect(probe.isColor(probe.theme.foregroundColor, "h", after: "<span>"))
    }

    @Test func listTaskAndQuoteMarkers() {
        let probe = SourceProbe(Self.document)
        #expect(probe.isColor(probe.source.syntaxColor, "- ", after: "</span>"))
        #expect(probe.isColor(probe.theme.foregroundColor, "item"))
        #expect(probe.isColor(probe.source.syntaxColor, "1. "))
        #expect(probe.isColor(probe.source.syntaxColor, "[x] "))
        #expect(probe.isColor(probe.theme.foregroundColor, "done"))
        #expect(probe.isColor(probe.source.syntaxColor, ">", after: "done"))
        #expect(probe.isColor(probe.source.quoteColor, "quote"))
    }

    @Test func tablePipesAndDelimiterRow() {
        let probe = SourceProbe(Self.document)
        #expect(probe.isColor(probe.source.syntaxColor, "|", after: "quote"))
        #expect(probe.isColor(probe.theme.foregroundColor, "a", after: "quote\n| "))
        #expect(probe.isColor(probe.source.syntaxColor, "|---|:-:|"))
        #expect(probe.isColor(probe.source.syntaxColor, "|", after: ":-:|\n"))
        #expect(probe.isColor(probe.theme.foregroundColor, "1", after: ":-:|\n| "))
    }

    @Test func fencedAndIndentedCode() {
        let probe = SourceProbe(Self.document)
        #expect(probe.isColor(probe.source.syntaxColor, "```"))
        #expect(probe.isColor(probe.theme.codeBlock.languageTagColor, "swift"))
        #expect(probe.isCodeBlock("let x = 1"))
        #expect(probe.storage.markdownBlock(at: probe.location(of: "let x"))?.codeLanguage == "swift")
        #expect(probe.isColor(probe.controller.styler.codeBaseColor, "let x = 1"))
        #expect(probe.isCodeBlock("indented"))
        #expect(!probe.isCodeBlock("Para"))
        #expect(probe.controller.isLocationInCode(probe.location(of: "let x") + 2))
        #expect(!probe.controller.isLocationInCode(probe.location(of: "Para") + 2))
    }

    @Test func thematicBreakHTMLBlockAndReferenceDefinition() {
        let probe = SourceProbe(Self.document)
        #expect(probe.isColor(probe.source.syntaxColor, "***"))
        #expect(probe.isColor(probe.source.htmlColor, "<div>"))
        #expect(probe.isColor(probe.source.htmlColor, "block"))
        #expect(probe.isColor(probe.source.htmlColor, "</div>"))
        #expect(probe.isColor(probe.theme.linkColor, "ref", after: "</div>\n\n["))
        #expect(probe.isColor(probe.source.urlColor, "https://ref.test"))
    }

    @Test func emphasisDoesNotCrossCodeOrURLs() {
        let probe = SourceProbe("a `*not*` b https://x.test/a_b_c d")
        #expect(!probe.traits("not").contains(.italic))
        #expect(probe.isColor(probe.source.codeColor, "*not*"))
        #expect(!probe.traits("b_c").contains(.italic))
    }

    @Test func setextNeedsAPlainParagraphAbove() {
        let probe = SourceProbe("- item\n---\n\ntext\n---")
        #expect(!probe.traits("item").contains(.bold))
        #expect(probe.traits("text").contains(.bold))
    }

    @Test func indentedTextInsideAListIsNotCode() {
        let probe = SourceProbe("- item\n\n    more item text")
        #expect(!probe.isCodeBlock("more item"))
    }
}

@Suite("Source styler incremental")
@MainActor
struct SourceStylerIncrementalTests {
    @Test func typingRestylesOnlyTheEditedParagraph() {
        let probe = SourceProbe("one\ntwo **b**\nthree\n\nfour")
        probe.insert("x", at: probe.location(of: "two") + 1)
        #expect(probe.lastLines == ["txwo **b**\n"])
        probe.insert("*", at: probe.location(of: "three"))
        #expect(probe.lastLines == ["*three\n"])
        probe.edit(NSRange(location: probe.location(of: "four") + 3, length: 1), "")
        #expect(probe.lastLines == ["fou"])
    }

    @Test func returnRestylesTheSplitLinesAndStopsWhenStateConverges() {
        let probe = SourceProbe("one\ntwo\nthree\nfour")
        probe.insert("\n", at: probe.location(of: "two") + 3)
        #expect(probe.lastLines == ["two\n", "\n", "three\n"])
    }

    @Test func closingAFenceRestylesExactlyTheLinesThatLeaveTheBlock() {
        let probe = SourceProbe("intro\n```\ncode\nmore\ntail\nend")
        #expect(probe.isCodeBlock("tail"))
        probe.insert("```\n", at: probe.location(of: "tail"))
        #expect(probe.lastLines == ["```\n", "tail\n", "end"])
        #expect(!probe.isCodeBlock("tail"))
        #expect(!probe.isCodeBlock("end"))
        #expect(probe.isCodeBlock("more"))
    }

    @Test func openingAFenceRestylesThroughTheEndOfTheNewBlock() {
        let probe = SourceProbe("a\nb\n```\nx\n```\nc")
        probe.insert("```\n", at: probe.location(of: "b"))
        #expect(probe.lastLines == ["```\n", "b\n", "```\n", "x\n", "```\n", "c"])
        #expect(probe.isCodeBlock("b"))
        #expect(!probe.isCodeBlock("x"))
        #expect(probe.isCodeBlock("c"))
    }

    @Test func editingTheInfoStringRestylesTheBlockAndStopsAtTheClosingFence() {
        let probe = SourceProbe("```swift\nlet a\nlet b\n```\nafter\nmore")
        probe.edit(NSRange(location: probe.location(of: "swift"), length: 5), "rust")
        #expect(probe.lastLines == ["```rust\n", "let a\n", "let b\n", "```\n"])
        #expect(probe.storage.markdownBlock(at: probe.location(of: "let b"))?.codeLanguage == "rust")
    }

    @Test func typingInsideACodeBodyKeepsTheBlockGroup() {
        let probe = SourceProbe("```\nfirst\nsecond\n```\nafter")
        let group = probe.storage.markdownBlock(at: probe.location(of: "first"))?.codeGroup
        probe.insert("z", at: probe.location(of: "second"))
        #expect(probe.lastLines == ["zsecond\n"])
        #expect(probe.controller.styler.lastPass.structureChanged == false)
        #expect(probe.storage.markdownBlock(at: probe.location(of: "zsecond"))?.codeGroup == group)
    }

    @Test func setextUnderlineRestylesTheLineAbove() {
        let probe = SourceProbe("Title\nbody\nafter")
        probe.edit(probe.range(of: "body"), "===")
        #expect(probe.lastLines == ["Title\n", "===\n", "after"])
        #expect(probe.traits("Title").contains(.bold))
        probe.edit(probe.range(of: "==="), "text")
        #expect(probe.lastLines == ["Title\n", "text\n", "after"])
        #expect(!probe.traits("Title").contains(.bold))
    }

    @Test func blankLineChangesTheNextLineFromContinuationToIndentedCode() {
        let probe = SourceProbe("para\n    code\nafter")
        #expect(!probe.isCodeBlock("code"))
        probe.insert("\n", at: probe.location(of: "para") + 4)
        #expect(probe.isCodeBlock("code"))
        #expect(probe.lastLines == ["para\n", "\n", "    code\n", "after"])
    }
}

@Suite("Source code highlighting")
@MainActor
struct SourceCodeHighlightTests {
    private func mismatches(_ probe: SourceProbe) -> [String] {
        probe.highlightMismatches()
    }

    @Test func bodiesUseSessionsAndEditsStayIncremental() {
        let highlighter = FakeCodeHighlighter()
        let probe = SourceProbe("intro\n```py\nx = 1\n# note\n```\nafter", highlighter: highlighter)
        #expect(highlighter.resetCount == 1)
        #expect(highlighter.sessions.first?.language == "py")
        #expect(highlighter.sessions.first?.resets == ["x = 1\n# note"])
        #expect(mismatches(probe).isEmpty)
        probe.insert("x", at: probe.location(of: "= 1") + 3)
        #expect(highlighter.resetCount == 1)
        #expect(highlighter.editCount == 1)
        #expect(highlighter.sessions.first?.edits.last?.replacement == "x")
        #expect(highlighter.isConsistent)
        #expect(mismatches(probe).isEmpty)
        probe.insert("\nx", at: probe.location(of: "# note") + 6)
        #expect(highlighter.resetCount == 1)
        #expect(highlighter.editCount == 2)
        #expect(highlighter.isConsistent)
        #expect(mismatches(probe).isEmpty)
    }

    @Test func proseEditsDoNotTouchSessions() {
        let highlighter = FakeCodeHighlighter()
        let probe = SourceProbe("intro\n```\nx\n```\nafter", highlighter: highlighter)
        probe.insert("y", at: probe.location(of: "after"))
        #expect(highlighter.resetCount == 1)
        #expect(highlighter.editCount == 0)
    }

    @Test func closingTheFenceDropsLinesFromTheBody() {
        let highlighter = FakeCodeHighlighter()
        let probe = SourceProbe("```\nx\ntail x\n", highlighter: highlighter)
        probe.insert("```\n", at: probe.location(of: "tail"))
        #expect(highlighter.isConsistent)
        #expect(mismatches(probe).isEmpty)
        #expect(probe.isColor(probe.theme.foregroundColor, "tail x"))
    }

    @Test func changingTheLanguageResetsTheSession() {
        let highlighter = FakeCodeHighlighter()
        let probe = SourceProbe("```py\nx\n```", highlighter: highlighter)
        probe.edit(probe.range(of: "py"), "rb")
        #expect(highlighter.resetCount == 2)
        #expect(highlighter.sessions.last?.language == "rb")
        #expect(mismatches(probe).isEmpty)
    }
}
