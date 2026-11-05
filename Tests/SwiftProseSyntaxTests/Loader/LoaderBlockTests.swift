import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ContainerCase: CustomTestStringConvertible, Sendable {
    let name: String
    let first: String
    let rest: String
    let shape: String
    let ordered: Bool

    var testDescription: String { name }

    static let all: [ContainerCase] = [
        ContainerCase(name: "top", first: "", rest: "", shape: "", ordered: false),
        ContainerCase(name: "quote", first: "> ", rest: "> ", shape: "q", ordered: false),
        ContainerCase(name: "bullet", first: "- ", rest: "  ", shape: "l", ordered: false),
        ContainerCase(name: "ordered", first: "1. ", rest: "   ", shape: "l", ordered: true),
        ContainerCase(name: "quote>bullet", first: "> - ", rest: ">   ", shape: "ql", ordered: false),
        ContainerCase(name: "bullet>quote", first: "- > ", rest: "  > ", shape: "lq", ordered: false),
        ContainerCase(name: "ordered>bullet", first: "1. - ", rest: "     ", shape: "ll", ordered: true),
        ContainerCase(name: "quote>quote", first: "> > ", rest: "> > ", shape: "qq", ordered: false)
    ]

    func wrap(_ lines: [String]) -> String {
        lines.enumerated().map { index, line in (index == 0 ? first : rest) + line }.joined(separator: "\n")
    }
}

struct LeafCase: CustomTestStringConvertible, Sendable {
    let name: String
    let lines: [String]

    var testDescription: String { name }

    static let all: [LeafCase] = [
        LeafCase(name: "paragraph", lines: ["some *text*"]),
        LeafCase(name: "heading", lines: ["## head"]),
        LeafCase(name: "code", lines: ["```js", "let x = 1", "```"]),
        LeafCase(name: "thematicBreak", lines: ["***"]),
        LeafCase(name: "table", lines: ["| a | b |", "|---|:-:|", "| 1 | 2 |"]),
        LeafCase(name: "html", lines: ["<div>x</div>"])
    ]
}

func shape(of containers: [MarkdownBlock.Container]) -> String {
    containers.map {
        switch $0 {
        case .quote: "q"
        case .listItem: "l"
        }
    }.joined()
}

@Suite("Loader blocks")
struct LoaderBlockTests {
    @Test(arguments: ContainerCase.all, LeafCase.all)
    func everyLeafInEveryContainer(container: ContainerCase, leaf: LeafCase) throws {
        let markdown = container.wrap(leaf.lines)
        let (storage, report) = LoaderFixture.load(markdown)
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(report.fallbackRuns == 0)
        #expect(LoaderFixture.blockIsUniform(storage))
        let first = try #require(paragraphs.first)
        #expect(paragraphs.count == (leaf.name == "table" ? 2 : 1))
        #expect(shape(of: first.containers) == container.shape)
        #expect(first.block?.isContinuation == false)
        #expect(first.lists.count == first.block?.listDepth)
        if container.shape.contains("l") {
            #expect(first.lists.first?.isOrdered == container.ordered)
        }

        switch leaf.name {
        case "paragraph":
            #expect(first.leaf == .paragraph)
            #expect(first.text == "some text")
        case "heading":
            #expect(first.block?.headingLevel == 2)
            #expect(first.text == "head")
        case "code":
            #expect(first.block?.codeLanguage == "js")
            #expect(first.text == "let x = 1")
        case "thematicBreak":
            #expect(first.leaf == .thematicBreak)
            let rule = try #require(storage.proseSourceAttachment(at: first.range.location))
            #expect(rule is HorizontalRuleAttachment)
            #expect(rule.markdownSource == "***")
        case "table":
            let body = try #require(paragraphs.last)
            #expect(first.block?.isTableHeader == true)
            #expect(first.block?.tableAlignments == [.none, .center])
            #expect(first.text == "a\tb")
            #expect(body.text == "1\t2")
            #expect(body.block?.tableGroup == first.block?.tableGroup)
            #expect(body.block?.isTableHeader == false)
            #expect(shape(of: body.containers) == container.shape)
            #expect(body.block?.isContinuation == container.shape.contains("l"))
            #expect(Corpus.roundTrip(markdown) == container.wrap(["| a | b |", "| --- | :---: |", "| 1 | 2 |"]))
        case "html":
            #expect(first.leaf == .html)
            let html = try #require(storage.proseSourceAttachment(at: first.range.location) as? HTMLBlockAttachment)
            #expect(html.markdownSource == "<div>x</div>")
        default:
            Issue.record("unknown leaf \(leaf.name)")
        }
    }

    @Test func emptyDocumentLoadsEmptyStorage() {
        #expect(LoaderFixture.load("").storage.length == 0)
        #expect(LoaderFixture.load("\n\n").storage.length == 0)
    }

    @Test func paragraphsAreSeparatedByNewlinesWithoutATrailingOne() {
        let storage = LoaderFixture.load("one\n\ntwo\n\n\n").storage
        #expect(storage.string == "one\ntwo")
        #expect(storage.markdownBlock(at: 3) == .paragraph)
    }

    @Test func crlfIsNormalized() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("a\r\nb\r\n\r\n- c\r\n").storage)
        #expect(paragraphs.map(\.text) == ["a\u{2028}b", "c"])
        #expect(shape(of: paragraphs[1].containers) == "l")
    }

    @Test func multiParagraphItemsMarkContinuationsAndShareLists() throws {
        let markdown = "- a\n\n  b\n- c\n  - d\n\n    e\n\n  f"
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load(markdown).storage)
        #expect(paragraphs.map(\.text) == ["a", "b", "c", "d", "e", "f"])
        #expect(paragraphs.map { $0.block?.isContinuation ?? false } == [false, true, false, false, true, true])
        #expect(paragraphs.map { shape(of: $0.containers) } == ["l", "l", "l", "ll", "ll", "l"])
        let outer = try #require(paragraphs[0].lists.first)
        #expect(paragraphs.allSatisfy { $0.lists.first === outer })
        #expect(paragraphs[3].lists[1] === paragraphs[4].lists[1])
        #expect(paragraphs[1].lists.count == 1)
        #expect(outer.markerFormat == .disc)
        #expect(paragraphs[3].lists[1].markerFormat == .circle)
    }

    @Test func separateListsGetSeparateTextLists() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("- a\n- b\n\n1. c\n2. d").storage)
        #expect(paragraphs[0].lists[0] === paragraphs[1].lists[0])
        #expect(paragraphs[1].lists[0] !== paragraphs[2].lists[0])
        #expect(paragraphs[2].lists[0].isOrdered)
        #expect(paragraphs[2].lists[0] === paragraphs[3].lists[0])
    }

    @Test func orderedListsKeepTheirStartingNumber() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("3. a\n4. b\n10. c").storage)
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].lists[0].startingItemNumber == 3)
        #expect(paragraphs[0].lists[0].markerFormat == .decimal)
    }

    @Test func quoteTokensGroupParagraphsOfOneQuote() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("> q1\n>\n> q2\n\n> other").storage)
        #expect(paragraphs.map(\.text) == ["q1", "q2", "other"])
        #expect(paragraphs[0].block?.quoteTokens == paragraphs[1].block?.quoteTokens)
        #expect(paragraphs[1].block?.quoteTokens != paragraphs[2].block?.quoteTokens)
        #expect(paragraphs.allSatisfy { $0.lists.isEmpty })
    }

    @Test func nestedQuotesInListsKeepTheirOrder() {
        let markdown = "> - a\n>   - b\n>\n>   c\n>   > deep"
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load(markdown).storage)
        #expect(paragraphs.map(\.text) == ["a", "b", "c", "deep"])
        #expect(paragraphs.map { shape(of: $0.containers) } == ["ql", "qll", "ql", "qlq"])
        #expect(paragraphs[2].block?.isContinuation == true)
        #expect(paragraphs[3].block?.isContinuation == true)
        #expect(paragraphs[3].lists.count == 1)
    }

    @Test func codeBlocksSplitIntoLinesWithOneGroupEach() throws {
        let markdown = "```swift title\nlet x\n\n\tindented  \n```\n```\nsecond\n```"
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load(markdown).storage)
        #expect(paragraphs.map(\.text) == ["let x", "", "\tindented  ", "second"])
        let first = try #require(paragraphs[0].block?.codeGroup)
        #expect(paragraphs[1].block?.codeGroup == first)
        #expect(paragraphs[2].block?.codeGroup == first)
        #expect(paragraphs[3].block?.codeGroup != first)
        #expect(paragraphs[0].block?.codeLanguage == "swift title")
        #expect(paragraphs[3].block?.codeLanguage == nil)
    }

    @Test func codeLinesAfterTheFirstAreContinuationsInsideItems() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("- ```\n  a\n  b\n  ```").storage)
        #expect(paragraphs.map(\.text) == ["a", "b"])
        #expect(paragraphs.map { $0.block?.isContinuation ?? false } == [false, true])
        #expect(paragraphs[0].lists[0] === paragraphs[1].lists[0])
    }

    @Test func indentedCodeLoadsAsCode() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("    one\n    two\n\npara").storage)
        #expect(paragraphs.map(\.text) == ["one", "two", "para"])
        #expect(paragraphs[0].block?.isCode == true)
        #expect(paragraphs[0].block?.codeLanguage == nil)
        #expect(paragraphs[2].leaf == .paragraph)
    }

    @Test(arguments: [
        ("***", "***"),
        ("---", "---"),
        ("___", "___"),
        ("- - -", "- - -"),
        (" * * * ", "* * *")
    ])
    func thematicBreaksKeepTheirSource(markdown: String, source: String) throws {
        let storage = LoaderFixture.load("para\n\n\(markdown)\n\nafter").storage
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(paragraphs.map(\.leaf) == [.paragraph, .thematicBreak, .paragraph])
        let rule = try #require(storage.proseSourceAttachment(at: paragraphs[1].range.location))
        #expect(rule.markdownSource == source)
        #expect(rule.contentKind == AtomKind.thematicBreak)
    }

    @Test func consecutiveThematicBreaksMapToTheirOwnLines() {
        let storage = LoaderFixture.load("***\n\n---\n\n- ___").storage
        #expect(LoaderFixture.attachments(storage).map(\.markdownSource) == ["***", "---", "___"])
        #expect(shape(of: LoaderFixture.paragraphs(storage)[2].containers) == "l")
    }

    @Test func setextHeadingsAreHeadingsWithoutRecoveredLines() {
        let (storage, report) = LoaderFixture.load("Title\n---\n\nSub\n===\n\n- a\n  -")
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(paragraphs.map(\.text) == ["Title", "Sub", "a"])
        #expect(paragraphs.map { $0.block?.headingLevel } == [2, 1, 2])
        #expect(report.recoveredLines.isEmpty)
    }

    @Test(arguments: ["#5 crashes on start\n-\nSteps below.", "#hashtag title\n===\nSteps below."])
    func setextHeadingTextStartingWithHashIsNotATX(markdown: String) {
        let (storage, report) = LoaderFixture.load(markdown)
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(paragraphs.count == 2)
        #expect(paragraphs.first?.block?.headingLevel != nil)
        #expect(paragraphs.allSatisfy { $0.lists.isEmpty })
        #expect(report.recoveredLines.isEmpty)
        let reloaded = LoaderFixture.paragraphs(Corpus.load(Corpus.roundTrip(markdown)))
        #expect(reloaded.map(\.text) == paragraphs.map(\.text))
        #expect(reloaded.map { $0.block?.headingLevel } == paragraphs.map { $0.block?.headingLevel })
    }

    @Test func linkReferenceDefinitionsVanishAndLinksResolve() {
        let (storage, report) = LoaderFixture.load("[r]: https://r.com\n\nsee [r]")
        #expect(LoaderFixture.paragraphs(storage).map(\.text) == ["see r"])
        #expect(storage.markdownLink(at: 4) == "https://r.com")
        #expect(report.recoveredLines.isEmpty)
    }

    @Test func emptyItemsInsideListsAreRecovered() {
        let (storage, report) = LoaderFixture.load("- a\n-\n- b\n-")
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(paragraphs.map(\.text) == ["a", "", "b", ""])
        #expect(paragraphs.allSatisfy { shape(of: $0.containers) == "l" && $0.block?.isListItemStart == true })
        #expect(paragraphs.allSatisfy { $0.lists.first === paragraphs[0].lists.first })
        #expect(report.recoveredLines == [2, 4])
        #expect(storage.string == "a\n\nb\n\n")
    }

    @Test func leadingEmptyOrderedItemSetsTheListStart() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("1.\n2. a\n3.").storage)
        #expect(paragraphs.map(\.text) == ["", "a", ""])
        let list = paragraphs[1].lists[0]
        #expect(paragraphs.allSatisfy { $0.lists.first === list })
        #expect(list.startingItemNumber == 1)
        #expect(list.isOrdered)
    }

    @Test func leadingEmptyItemJoinsTheFollowingList() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("> -\n> - a").storage)
        #expect(paragraphs.map(\.text) == ["", "a"])
        #expect(paragraphs[0].block?.quoteTokens == paragraphs[1].block?.quoteTokens)
        #expect(paragraphs[0].lists[0] === paragraphs[1].lists[0])
    }

    @Test func emptyNestedItemOpensASublist() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("- a\n\n  -\n- b").storage)
        #expect(paragraphs.map(\.text) == ["a", "", "b"])
        #expect(paragraphs.map { shape(of: $0.containers) } == ["l", "ll", "l"])
        #expect(paragraphs[1].lists[0] === paragraphs[0].lists[0])
        #expect(paragraphs[1].block?.isListItemStart == true)
    }

    @Test func itemWhoseContentStartsOnTheNextLineIsNotDuplicated() {
        let (storage, report) = LoaderFixture.load("-\n  foo\n- bar")
        #expect(LoaderFixture.paragraphs(storage).map(\.text) == ["foo", "bar"])
        #expect(report.recoveredLines.isEmpty)
    }

    @Test func emptyHeadingsAndFencesAreRecovered() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("#\n\n```js\n```\n\n- ##\n\npara").storage)
        #expect(paragraphs.map(\.text) == ["", "", "", "para"])
        #expect(paragraphs[0].block?.headingLevel == 1)
        #expect(paragraphs[1].block?.codeLanguage == "js")
        #expect(paragraphs[2].block?.headingLevel == 2)
        #expect(shape(of: paragraphs[2].containers) == "l")
    }

    @Test func emptyQuoteLinesAreNotRecovered() {
        let (storage, report) = LoaderFixture.load("> a\n>\n>\n> b")
        #expect(LoaderFixture.paragraphs(storage).map(\.text) == ["a", "b"])
        #expect(report.recoveredLines.isEmpty)
    }

    @Test func blockHTMLInsideItemsAndQuotesIsAnAtom() throws {
        let storage = LoaderFixture.load("- a\n  <div>\n  x\n  </div>\n- b\n\n> <div>q</div>").storage
        let paragraphs = LoaderFixture.paragraphs(storage)
        #expect(paragraphs.map(\.leaf) == [.paragraph, .html, .paragraph, .html])
        #expect(paragraphs[1].block?.isContinuation == true)
        let html = try #require(storage.proseSourceAttachment(at: paragraphs[1].range.location))
        #expect(html.markdownSource == "<div>\nx\n</div>")
        #expect(shape(of: paragraphs[3].containers) == "q")
    }

    @Test func emptyLastParagraphKeepsItsNewline() {
        let storage = LoaderFixture.load("- a\n-").storage
        #expect(storage.string == "a\n\n")
        #expect(storage.markdownBlock(at: 2)?.isListItemStart == true)
    }

    static let corpus: [String] = [
        "# Bug 1234567\n\nSteps to reproduce:\n\n1. Open `about:config`\n2. Set **foo** to *true*\n   - check the [docs](https://example.com)\n\nExpected: works.\n\n```js\nconsole.log(1);\n```",
        "> Quoting a reviewer:\n> - nit: rename\n> - [ ] follow-up\n>\n> Thanks!\n\n---\n\n| a | b |\n|---|---|\n| 1 | 2 |",
        "{nav, icon=check, name=praise:} Looks good.\n\n//x// ##x## [[url | x]]",
        "- a\n  1. b\n     > c\n     > ```\n     > d\n     > ```\n- e\n\n<details>\n<summary>s</summary>\n</details>",
        "Line one\nline two  \nline three\\\nfour &amp; \\* \u{1F600}",
        "1. [x] done\n2. [ ] todo\n\n   more text\n3.\n\n***"
    ]

    @Test(arguments: corpus)
    func corpusStorageInvariants(markdown: String) {
        let (storage, report) = LoaderFixture.load(markdown)
        #expect(report.fallbackRuns == 0)
        #expect(LoaderFixture.blockIsUniform(storage))
        #expect(!storage.string.contains("\r"))
        #expect(!storage.string.contains("\u{2029}"))
        var itemLists: [NSTextList] = []
        for paragraph in LoaderFixture.paragraphs(storage) {
            let block = paragraph.block ?? .paragraph
            #expect(paragraph.lists.count == block.listDepth)
            if block.isContinuation, let last = paragraph.lists.last {
                #expect(itemLists.contains { $0 === last })
            }
            if block.isListItemStart, let last = paragraph.lists.last {
                itemLists.append(last)
            }
            if block.isAtom {
                #expect(paragraph.text == "\u{FFFC}")
                #expect(storage.proseSourceAttachment(at: paragraph.range.location) != nil)
            }
            if block.isCode {
                #expect(!paragraph.text.contains("\u{2028}"))
            }
        }
    }
}
