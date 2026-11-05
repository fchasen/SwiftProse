import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Writer blocks")
struct WriterBlockTests {
    @Test func paragraphsAreSeparatedByOneBlankLine() {
        #expect(WF.write(WF.p("a"), WF.p("b")) == "a\n\nb")
        #expect(WF.write(WF.p("a"), WF.p(""), WF.p(""), WF.p("b")) == "a\n\nb")
        #expect(WF.write(WF.p(""), WF.p("a")) == "a")
        #expect(WF.write(WF.p("a"), WF.p("  "), WF.p("b")) == "a\n\nb")
    }

    @Test(arguments: ["    x", "\tx", "  \t x", "      deep text"])
    func deeplyIndentedParagraphTextReloadsAsParagraph(text: String) throws {
        let list = WF.bullet()
        let quote = GroupToken.mint()
        let storages = [
            WF.storage([WF.p(text)]),
            WF.storage([WF.item(text, [list])]),
            WF.storage([WF.p(text, block: MarkdownBlock(containers: [.quote(quote)]))])
        ]
        for storage in storages {
            let written = MarkdownWriter().markdown(from: storage)
            let paragraph = try #require(LoaderFixture.paragraphs(MarkdownLoader().load(written)).first)
            #expect(paragraph.leaf == .paragraph, "\(written)")
            #expect(paragraph.text == storage.string.trimmingCharacters(in: .newlines), "\(written)")
            #expect(Corpus.roundTrip(written) == written)
        }
        #expect(WF.write(WF.p("   x")) == "   x")
    }

    @Test func trailingEmptyParagraphsAreStripped() {
        #expect(WF.write(WF.p("a"), trailingNewline: true) == "a")
        #expect(WF.write(WF.p("a"), WF.p(""), WF.p(""), trailingNewline: true) == "a")
        #expect(MarkdownWriter().markdown(from: NSAttributedString(string: "")) == "")
        #expect(MarkdownWriter().markdown(from: NSAttributedString(string: "\n\n")) == "")
    }

    @Test func headings() {
        for level in 1...6 {
            let block = MarkdownBlock(leaf: .heading(level: level))
            #expect(WF.write(WF.p("Title", block: block)) == String(repeating: "#", count: level) + " Title")
        }
        let h2 = MarkdownBlock(leaf: .heading(level: 2))
        #expect(WF.write(WF.p(WF.t("a"), WF.soft, WF.t("b", .strong), block: h2), WF.p("c")) == "## a **b**\n\nc")
        #expect(WF.write(WF.p("a"), WF.p("", block: h2), WF.p("b")) == "a\n\nb")
    }

    @Test func codeBlocksFenceTheirLines() {
        let group = GroupToken.mint()
        #expect(WF.write(
            WF.code("let x = 1", group, language: "swift"),
            WF.code("", group, language: "swift"),
            WF.code("  y", group, language: "swift")
        ) == "```swift\nlet x = 1\n\n  y\n```")
        #expect(WF.write(WF.code("plain", group)) == "```\nplain\n```")
    }

    @Test func codeFencesOutgrowInnerBackticks() {
        let group = GroupToken.mint()
        #expect(WF.write(WF.code("```", group), WF.code("x", group)) == "````\n```\nx\n````")
        #expect(WF.write(WF.code("a ````` b", group)) == "``````\na ````` b\n``````")
        #expect(WF.write(WF.code("x", group, language: "we`ird")) == "~~~we`ird\nx\n~~~")
    }

    @Test func codeGroupsStayDistinct() {
        let first = GroupToken.mint()
        let second = GroupToken.mint()
        #expect(WF.write(WF.code("a", first), WF.code("b", second)) == "```\na\n```\n\n```\nb\n```")
        #expect(WF.write(WF.code("a", first), WF.code("b", first)) == "```\na\nb\n```")
        #expect(WF.write(WF.code("a", first), WF.p(""), WF.code("b", first)) == "```\na\n```\n\n```\nb\n```")
        #expect(WF.write(WF.code("a", first), WF.p("text"), WF.code("b", first)) == "```\na\n```\n\ntext\n\n```\nb\n```")
    }

    @Test func codeLinesAreVerbatim() {
        let group = GroupToken.mint()
        let block = MarkdownBlock(leaf: .code(language: nil, group: group))
        let line = WF.p(WF.t("*", literal: "\\*"), WF.t("x", .strong), WF.t(" [a](b)", link: "u"), block: block)
        #expect(WF.write(line) == "```\n*x [a](b)\n```")
        #expect(WF.write(WF.p(WF.t("a"), WF.hard, WF.t("b"), block: block)) == "```\na\nb\n```")
    }

    @Test func emptyCodeLinesSurviveAtDocumentEnd() {
        let group = GroupToken.mint()
        #expect(WF.write(WF.code("a", group), WF.code("", group), trailingNewline: true) == "```\na\n\n```")
    }

    @Test func thematicBreakHazards() {
        let rule = WF.p(WF.atom("___", kind: AtomKind.thematicBreak), block: MarkdownBlock(leaf: .thematicBreak))
        #expect(WF.write(WF.p("a"), rule, WF.p("b")) == "a\n\n___\n\nb")
        let bare = WF.p(WF.t("\u{FFFC}"), block: MarkdownBlock(leaf: .thematicBreak))
        #expect(WF.write(WF.p("a"), bare) == "a\n\n---")
        let bogus = WF.p(WF.atom("-*-", kind: AtomKind.thematicBreak), block: MarkdownBlock(leaf: .thematicBreak))
        #expect(WF.write(bogus) == "---")
        let spaced = WF.p(WF.atom("* * *", kind: AtomKind.thematicBreak), block: MarkdownBlock(leaf: .thematicBreak))
        #expect(WF.write(spaced) == "* * *")
        let list = WF.bullet()
        let itemRule = WF.p(
            WF.atom("---", kind: AtomKind.thematicBreak),
            block: MarkdownBlock(leaf: .thematicBreak, containers: [.listItem]),
            lists: [list]
        )
        #expect(WF.write(itemRule) == "- ***")
        let continuationRule = WF.p(
            WF.atom("---", kind: AtomKind.thematicBreak),
            block: MarkdownBlock(leaf: .thematicBreak, containers: [.listItem], isContinuation: true),
            lists: [list]
        )
        #expect(WF.write(WF.item("a", [list]), continuationRule) == "- a\n\n  ---")
    }

    @Test func blockAtomsWriteTheirSourceUnderPrefixes() {
        let html = "<div>\n  <p>x</p>\n</div>"
        #expect(WF.write(WF.p(WF.atom(html, kind: AtomKind.htmlBlock), block: MarkdownBlock(leaf: .html))) == html)
        let document = StorageReader().document(from: WF.storage([WF.p(WF.atom(html, kind: AtomKind.htmlBlock), block: MarkdownBlock(leaf: .html))]))
        #expect(document.blocks == [.atom(.init(source: html, kind: AtomKind.htmlBlock))])
    }

    @Test func multiParagraphQuotes() {
        let quote = GroupToken.mint()
        let block = MarkdownBlock(containers: [.quote(quote)])
        #expect(WF.write(WF.p("a", block: block), WF.p("b", block: block)) == "> a\n>\n> b")
        #expect(WF.write(WF.p(WF.t("a"), WF.soft, WF.t("b"), block: block)) == "> a\n> b")
        #expect(WF.write(WF.p("a", block: block), WF.p("", block: block), WF.p("b", block: block)) == "> a\n>\n> b")
    }

    @Test func distinctQuoteTokensStaySeparate() {
        let first = MarkdownBlock(containers: [.quote(GroupToken.mint())])
        let second = MarkdownBlock(containers: [.quote(GroupToken.mint())])
        #expect(WF.write(WF.p("a", block: first), WF.p("b", block: second)) == "> a\n\n> b")
        #expect(WF.write(WF.p("a", block: first), WF.p(""), WF.p("b", block: first)) == "> a\n\n> b")
    }

    @Test func nestedQuotes() {
        let outer = GroupToken.mint()
        let inner = GroupToken.mint()
        #expect(WF.write(
            WF.p("a", block: MarkdownBlock(containers: [.quote(outer)])),
            WF.p("b", block: MarkdownBlock(containers: [.quote(outer), .quote(inner)])),
            WF.p("c", block: MarkdownBlock(containers: [.quote(outer)]))
        ) == "> a\n>\n> > b\n>\n> c")
        let group = GroupToken.mint()
        #expect(WF.write(
            WF.code("x", group, containers: [.quote(outer)]),
            WF.code("", group, containers: [.quote(outer)]),
            WF.code("y", group, containers: [.quote(outer)])
        ) == "> ```\n> x\n>\n> y\n> ```")
    }

    @Test func bulletAndOrderedLists() {
        let bullet = WF.bullet()
        #expect(WF.write(WF.item("a", [bullet]), WF.item("b", [bullet])) == "- a\n- b")
        let ordered = WF.ordered(3)
        #expect(WF.write(WF.item("a", [ordered]), WF.item("b", [ordered])) == "3. a\n4. b")
    }

    @Test func tenthItemLeavesEarlierItemsUnchanged() {
        let list = WF.ordered()
        let names = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        var nine = names.prefix(9).map { WF.item($0, [list]) }
        nine.append(WF.item("i2", [list], continuation: true))
        let nineOutput = WF.write(nine)
        var ten = nine
        ten.append(WF.item("j", [list]))
        ten.append(WF.item("j2", [list], continuation: true))
        let tenOutput = WF.write(ten)
        #expect(tenOutput.hasPrefix(nineOutput + "\n"))
        #expect(nineOutput.hasSuffix("9. i\n\n   i2"))
        #expect(tenOutput.hasSuffix("9. i\n\n   i2\n10. j\n\n    j2"))
    }

    @Test func continuationParagraphsIndentByMarkerWidth() {
        let bullet = WF.bullet()
        #expect(WF.write(WF.item("a", [bullet]), WF.item("more", [bullet], continuation: true), WF.item("b", [bullet])) == "- a\n\n  more\n- b")
        let ordered = WF.ordered()
        #expect(WF.write(WF.item("a", [ordered]), WF.item("more", [ordered], continuation: true)) == "1. a\n\n   more")
        #expect(WF.write(WF.p(WF.t("a"), WF.soft, WF.t("b"), block: MarkdownBlock(containers: [.listItem]), lists: [bullet])) == "- a\n  b")
    }

    @Test func emptyMarkerListsAreIgnored() {
        let list = WF.ordered()
        let carried = WF.p("cont", block: MarkdownBlock(containers: [.listItem], isContinuation: true), lists: [list, WF.carrier()])
        #expect(WF.write(WF.item("a", [list]), carried, WF.item("b", [list])) == "1. a\n\n   cont\n2. b")
        #expect(WF.write(WF.p("plain", lists: [WF.carrier()])) == "plain")
    }

    @Test func segmentedListsJoinAndKeepNumbering() {
        let first = WF.ordered()
        let segment = WF.ordered(3)
        #expect(WF.write(WF.item("a", [first]), WF.item("b", [first]), WF.item("c", [segment])) == "1. a\n2. b\n3. c")
    }

    @Test func extraTextListsStartItems() {
        let outer = WF.bullet()
        let inner = WF.bullet()
        let stale = WF.p("b", block: MarkdownBlock(containers: [.listItem], isContinuation: true), lists: [outer, inner])
        #expect(WF.write(WF.item("a", [outer]), stale) == "- a\n  - b")
    }

    @Test func nestedLists() {
        let outer = WF.bullet()
        let inner = WF.bullet()
        #expect(WF.write(WF.item("a", [outer]), WF.item("b", [outer, inner]), WF.item("c", [outer])) == "- a\n  - b\n- c")
        let numbered = WF.ordered()
        #expect(WF.write(WF.item("a", [outer]), WF.item("b", [outer, numbered]), WF.item("c", [outer, numbered])) == "- a\n  1. b\n  2. c")
        let deep = WF.ordered()
        #expect(WF.write(WF.item("1", [deep]), WF.item("2", [deep, inner]), WF.item("3", [deep, inner, numbered])) == "1. 1\n   - 2\n     1. 3")
    }

    @Test func sublistsThatCannotInterruptGetABlankLine() {
        let outer = WF.bullet()
        #expect(WF.write(WF.item("a", [outer]), WF.item("b", [outer, WF.ordered(2)])) == "- a\n\n  2. b")
        let inner = WF.bullet()
        #expect(WF.write(WF.item("a", [outer]), WF.item("", [outer, inner]), WF.item("c", [outer, inner])) == "- a\n\n  -\n  - c")
    }

    @Test func tasks() {
        let list = WF.bullet()
        #expect(WF.write(WF.item("a", [list], task: .unchecked), WF.item("b", [list], task: .checked)) == "- [ ] a\n- [x] b")
        let ordered = WF.ordered()
        #expect(WF.write(WF.item("a", [ordered], task: .unchecked)) == "1. [ ] a")
        #expect(WF.write(WF.item("a", [list], task: .checked), WF.item("more", [list], task: .unchecked, continuation: true)) == "- [x] a\n\n  more")
    }

    @Test func emptyItems() {
        let list = WF.bullet()
        #expect(WF.write(WF.item("a", [list]), WF.item("", [list]), WF.item("c", [list])) == "- a\n-\n- c")
        let ordered = WF.ordered()
        #expect(WF.write(WF.item("a", [ordered]), WF.item("", [ordered]), WF.item("c", [ordered])) == "1. a\n2.\n3. c")
        #expect(WF.write(WF.item("a", [list]), WF.item("", [list]), trailingNewline: true) == "- a")
        #expect(WF.write(WF.item("a", [list]), WF.item("b", [list]), WF.item("", [list]), WF.p(""), trailingNewline: true) == "- a\n- b")
    }

    @Test func listsJoinBySameObjectOrKind() {
        #expect(WF.write(WF.item("a", [WF.bullet()]), WF.item("b", [WF.bullet()])) == "- a\n- b")
        #expect(WF.write(WF.item("a", [WF.ordered()]), WF.item("b", [WF.ordered(7)])) == "1. a\n2. b")
        #expect(WF.write(WF.item("a", [WF.bullet()]), WF.item("b", [WF.ordered()])) == "- a\n\n1. b")
        let list = WF.bullet()
        #expect(WF.write(WF.item("a", [list]), WF.p(""), WF.item("b", [list])) == "- a\n\n- b")
        #expect(WF.write(WF.item("a", [list]), WF.p("p"), WF.item("b", [list])) == "- a\n\np\n\n- b")
    }

    @Test(arguments: [
        ("- a\n* b", "- a\n\n* b"),
        ("1. a\n1) b", "1. a\n\n1) b"),
        ("- a\n* b\n+ c", "- a\n\n* b\n\n- c"),
        ("- a\n* ---", "- a\n\n* ---"),
        ("- x\n  - a\n  * b", "- x\n  - a\n  * b")
    ])
    func adjacentListsTheLoaderKeepsApartStayApart(markdown: String, expected: String) {
        let written = Corpus.roundTrip(markdown)
        #expect(written == expected)
        func listCount(_ source: String) -> Int {
            Set(LoaderFixture.paragraphs(Corpus.load(source)).compactMap { $0.lists.last.map(ObjectIdentifier.init) }).count
        }
        #expect(listCount(written) == listCount(markdown))
        #expect(Corpus.roundTrip(written) == written)
    }

    @Test func textListsWinOverBlockContainers() {
        #expect(WF.write(WF.p("a", block: MarkdownBlock(containers: [.listItem]))) == "a")
        #expect(WF.write(WF.p("a", lists: [WF.bullet()])) == "- a")
        let outer = WF.bullet()
        let inner = WF.bullet()
        #expect(WF.write(WF.item("a", [outer]), WF.p("b", block: MarkdownBlock(containers: [.listItem]), lists: [outer, inner])) == "- a\n  - b")
    }

    @Test func blocksInsideItems() {
        let list = WF.bullet()
        let group = GroupToken.mint()
        #expect(WF.write(
            WF.item("a", [list]),
            WF.code("x", group, containers: [.listItem], lists: [list], continuation: true),
            WF.code("", group, containers: [.listItem], lists: [list], continuation: true),
            WF.code("y", group, containers: [.listItem], lists: [list], continuation: true)
        ) == "- a\n  ```\n  x\n\n  y\n  ```")
        #expect(WF.write(WF.code("x", group, containers: [.listItem], lists: [list])) == "- ```\n  x\n  ```")
        let heading = MarkdownBlock(leaf: .heading(level: 3), containers: [.listItem], isContinuation: true)
        #expect(WF.write(WF.item("a", [list]), WF.p("h", block: heading, lists: [list])) == "- a\n  ### h")
        let quote = GroupToken.mint()
        #expect(WF.write(WF.item("a", [list]), WF.item("q", [list], continuation: true, quotes: [])) == "- a\n\n  q")
        let quoted = WF.p("q", block: MarkdownBlock(containers: [.listItem, .quote(quote)], isContinuation: true), lists: [list])
        #expect(WF.write(WF.item("a", [list]), quoted) == "- a\n  > q")
        let quoteFirst = WF.p("q", block: MarkdownBlock(containers: [.listItem, .quote(quote)]), lists: [list])
        let quoteSecond = WF.p("r", block: MarkdownBlock(containers: [.listItem, .quote(quote)], isContinuation: true), lists: [list])
        #expect(WF.write(quoteFirst, quoteSecond, WF.item("b", [list])) == "- > q\n  >\n  > r\n- b")
    }

    @Test(arguments: [
        "- x\n\n  <div>\n  hi\n  </div>\n\n  > q",
        "- x\n\n  <div>\n  hi\n  </div>\n\n  ```\n  c\n  ```",
        "- x\n\n  <div>\n  hi\n  </div>\n\n  - nested",
        "- x\n\n  <div>\n  hi\n  </div>\n\n  ## h",
        "- x\n  > a\n\n  > b"
    ])
    func itemBlocksThatWouldMergeKeepABlankLine(markdown: String) {
        let written = Corpus.roundTrip(markdown)
        #expect(written == markdown)
        let original = LoaderFixture.paragraphs(Corpus.load(markdown))
        let reloaded = LoaderFixture.paragraphs(Corpus.load(written))
        #expect(reloaded.map(\.text) == original.map(\.text))
        #expect(reloaded.map(\.containers.count) == original.map(\.containers.count))
    }

    @Test func listsInsideQuotes() {
        let quote = GroupToken.mint()
        let list = WF.bullet()
        let inner = WF.ordered()
        #expect(WF.write(
            WF.p("intro", block: MarkdownBlock(containers: [.quote(quote)])),
            WF.item("a", [list], quotes: [quote]),
            WF.item("b", [list, inner], quotes: [quote]),
            WF.item("more", [list], continuation: true, quotes: [quote])
        ) == "> intro\n>\n> - a\n>   1. b\n>\n>   more")
    }

    @Test func returnAtDocumentEndInListIsStripped() {
        let list = WF.bullet()
        let storage = NSMutableAttributedString(attributedString: WF.storage([WF.item("a", [list]), WF.item("b", [list])], trailingNewline: true))
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        storage.append(NSAttributedString(string: "\n", attributes: [
            .paragraphStyle: style,
            .markdownBlock: MarkdownBlock(containers: [.listItem])
        ]))
        #expect(MarkdownWriter().markdown(from: storage) == "- a\n- b")
    }

    @Test func documentHasNoFinalNewline() {
        let output = WF.write(WF.p("a"), WF.item("b", [WF.bullet()]), WF.code("c", GroupToken.mint()), trailingNewline: true)
        #expect(output == "a\n\n- b\n\n```\nc\n```")
        #expect(!output.hasSuffix("\n"))
    }

    @Test func blankParagraphsCarryingMarksAreSeparators() {
        #expect(WF.write(WF.p("a"), WF.p(WF.t(" ", .strong)), WF.p("b")) == "a\n\nb")
    }
}
