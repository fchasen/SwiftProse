import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Loader atoms")
struct LoaderAtomTests {
    @Test(arguments: [
        "![alt *t*](i.png \"title\")",
        "![a](<with space.png>)",
        "![a](u(1).png)",
        "![it's](x.png 'q')",
        "![ref][r]",
        "![](empty.png)",
        "![nested [b]](n.png)"
    ])
    func imagesKeepByteExactSource(image: String) throws {
        let markdown = "before \(image) after\n\n[r]: https://r.png"
        let (storage, report) = LoaderFixture.load(markdown)
        #expect(report.fallbackRuns == 0)
        let paragraph = try #require(LoaderFixture.paragraphs(storage).first)
        #expect(paragraph.text == "before \u{FFFC} after")
        let attachment = try #require(storage.proseSourceAttachment(at: 7) as? ChipTextAttachment)
        #expect(attachment.markdownSource == image)
        #expect(attachment.contentKind == AtomKind.image)
    }

    @Test func imageChipShowsAltText() throws {
        let storage = LoaderFixture.load("![a diagram](d.png) ![](e.png)").storage
        let chips = LoaderFixture.attachments(storage).compactMap { $0 as? ChipTextAttachment }
        #expect(chips.map(\.chipLabel) == ["a diagram", "image"])
        #expect(chips.map(\.markdownSource) == ["![a diagram](d.png)", "![](e.png)"])
    }

    @Test(arguments: [
        ("![a](x.png)![b](x.png)", ["![a](x.png)", "![b](x.png)"]),
        ("![](x.png)![](x.png)", ["![](x.png)", "![](x.png)"]),
        ("![a](x.png)![](x.png)![c](x.png)", ["![a](x.png)", "![](x.png)", "![c](x.png)"]),
        ("**![a](x.png)![b](x.png)**", ["![a](x.png)", "![b](x.png)"])
    ])
    func adjacentImagesWithTheSameURLStayDistinct(markdown: String, sources: [String]) {
        let (storage, report) = LoaderFixture.load(markdown)
        #expect(report.fallbackRuns == 0)
        #expect(LoaderFixture.attachments(storage).map(\.markdownSource) == sources)
        #expect(storage.string == String(repeating: "\u{FFFC}", count: sources.count))
        #expect(Corpus.roundTrip(markdown) == markdown)
    }

    @Test(arguments: [
        ("[](http://x.com) text", 1),
        ("a [](http://x.com) text", 1),
        ("text [](http://x.com)", 1),
        ("**a [](u) b**", 1),
        ("[](u) [](v \"t\")", 2),
        ("[](http://x.com)", 1),
        ("- [](u)\n- b", 1),
        ("- a\n  [](u)", 1),
        ("[](u)\nb", 1),
        ("> [](u)", 1),
        ("## [](u) heading", 1)
    ])
    func emptyLinksSurviveAsAtoms(markdown: String, count: Int) {
        let (storage, report) = LoaderFixture.load(markdown)
        #expect(report.fallbackRuns == 0)
        let atoms = LoaderFixture.attachments(storage)
        #expect(atoms.count == count)
        #expect(atoms.allSatisfy { $0.contentKind == AtomKind.emptyLink })
        #expect(Corpus.roundTrip(markdown) == markdown)
    }

    @Test(arguments: ["[a](http://x/[](y)) b", "`[](x)` b", "\\[](x) b", "![](x.png) b"])
    func emptyLinkLookalikesAreNotAtoms(markdown: String) {
        let atoms = LoaderFixture.attachments(LoaderFixture.load(markdown).storage)
        #expect(!atoms.contains { $0.contentKind == AtomKind.emptyLink })
    }

    @Test func imagesInsideLinksCarryTheLink() throws {
        let storage = LoaderFixture.load("[![img](a.png)](https://b.com)").storage
        #expect(storage.string == "\u{FFFC}")
        #expect(storage.proseSourceAttachment(at: 0)?.markdownSource == "![img](a.png)")
        #expect(storage.markdownLink(at: 0) == "https://b.com")
    }

    @Test func inlineHTMLBecomesChips() {
        let storage = LoaderFixture.load("x <b>y</b> <br/> z").storage
        #expect(storage.string == "x \u{FFFC}y\u{FFFC} \u{FFFC} z")
        let atoms = LoaderFixture.attachments(storage)
        #expect(atoms.map(\.markdownSource) == ["<b>", "</b>", "<br/>"])
        #expect(atoms.allSatisfy { $0.contentKind == AtomKind.inlineHTML })
    }

    @Test func tableCellsLoadAsRowParagraphs() throws {
        let markdown = "| a | **b** |\n|:--|--:|\n| 1 | `two` |\n|  | x \\| y |"
        let storage = LoaderFixture.load("intro\n\n\(markdown)\n\nafter").storage
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(paragraphs.map(\.text) == ["intro", "a\tb", "1\ttwo", "\tx | y", "after"])
        let rows = paragraphs[1...3]
        #expect(rows.allSatisfy { $0.block?.tableAlignments == [.left, .right] })
        #expect(rows.map { $0.block?.isTableHeader } == [true, false, false])
        #expect(Set(rows.compactMap { $0.block?.tableGroup }).count == 1)
        #expect(storage.markdownInlineIntent(at: paragraphs[1].range.location + 2) == .stronglyEmphasized)
        #expect(storage.markdownInlineIntent(at: paragraphs[2].range.location + 2) == .code)
        #expect(storage.attribute(.markdownTableSeparator, at: paragraphs[1].range.location + 1, effectiveRange: nil) != nil)
    }

    @Test func tableRowsExtendOverEmptyTrailingRows() {
        let storage = LoaderFixture.load("| a |\n|---|\n| 1 |\n| |").storage
        #expect(LoaderFixture.paragraphs(storage).map(\.text) == ["a", "1", ""])
    }

    @Test(arguments: ["```x|y\n```", "> ```x|y\n> ```"])
    func tableStopsAtAFollowingEmptyFence(fence: String) throws {
        let quoted = fence.hasPrefix(">")
        let table = quoted ? "> | a |\n> |---|\n> | 1 |" : "| a |\n|---|\n| 1 |"
        let markdown = table + "\n" + fence
        let storage = LoaderFixture.load(markdown).storage
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(paragraphs.map(\.text) == ["a", "1", ""])
        #expect(paragraphs.last?.block?.isCode == true)
        let canonical = quoted ? "> | a |\n> | --- |\n> | 1 |" : "| a |\n| --- |\n| 1 |"
        let written = Corpus.roundTrip(markdown)
        #expect(written == canonical + (quoted ? "\n>\n" : "\n\n") + fence)
        #expect(Corpus.roundTrip(written) == written)
    }

    @Test(arguments: [
        ("> | a |\n> |---|\n> | 1 |", "q"),
        ("- | a |\n  |---|\n  | 1 |", "l"),
        ("- intro\n\n  | a |\n  |---|\n  | 1 |", "l"),
        ("> - | a |\n>   |---|\n>   | 1 |", "ql")
    ])
    func tableRowsKeepTheirContainers(markdown: String, expectedShape: String) throws {
        let storage = LoaderFixture.load(markdown).storage
        let rows = LoaderFixture.paragraphs(storage).filter { $0.block?.isTableRow == true }
        #expect(rows.map(\.text) == ["a", "1"])
        #expect(rows.allSatisfy { shape(of: $0.containers) == expectedShape })
        let canonical = markdown.replacingOccurrences(of: "|---|", with: "| --- |")
        #expect(Corpus.roundTrip(markdown) == canonical)
    }

    @Test func htmlBlocksKeepVerbatimSource() throws {
        let html = "<details>\n<summary>More</summary>\n\nBody\n</details>"
        let storage = LoaderFixture.load("para\n\n<div class=\"x\">\n  <p>hi</p>\n</div>\n\n\(html)").storage
        let atoms = LoaderFixture.attachments(storage)
        #expect(atoms.allSatisfy { $0 is HTMLBlockAttachment })
        #expect(atoms.first?.markdownSource == "<div class=\"x\">\n  <p>hi</p>\n</div>")
        #expect(atoms.first?.contentKind == AtomKind.htmlBlock)
        #expect(LoaderFixture.paragraphs(storage).first?.text == "para")
    }

    @Test @MainActor func htmlBlocksRenderImportedContent() throws {
        let attachment = HTMLBlockAttachment(markdownSource: "<div><b>bold</b> text</div>")
        let rendered = attachment.renderedContent
        #expect(rendered.string.contains("bold"))
        #expect(!rendered.string.contains("<b>"))
        let bounds = attachment.attachmentBounds(
            for: nil,
            proposedLineFragment: CGRect(x: 0, y: 0, width: 300, height: 20),
            glyphPosition: .zero,
            characterIndex: 0
        )
        #expect(bounds.height > 0)
        #expect(attachment.image(forBounds: bounds, textContainer: nil, characterIndex: 0) != nil)
    }

    @Test func thematicBreakIsAHorizontalRuleAttachment() throws {
        let storage = LoaderFixture.load("a\n\n___\n\nb").storage
        let rule = try #require(storage.proseSourceAttachment(at: 2) as? HorizontalRuleAttachment)
        #expect(rule.markdownSource == "___")
        #expect(storage.markdownBlock(at: 2)?.leaf == .thematicBreak)
        #expect(storage.markdownBlock(at: 2)?.isAtom == true)
    }

    @Test func atomParagraphsHoldOneObjectReplacementCharacter() {
        let storage = LoaderFixture.load("***\n\n<div>x</div>").storage
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(paragraphs.map(\.text) == ["\u{FFFC}", "\u{FFFC}"])
        #expect(paragraphs.map(\.leaf) == [.thematicBreak, .html])
        #expect(paragraphs.allSatisfy { storage.markdownInlineIntent(at: $0.range.location).isEmpty })
    }
}
