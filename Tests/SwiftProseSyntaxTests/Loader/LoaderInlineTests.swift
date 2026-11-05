import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Loader inline")
struct LoaderInlineTests {
    @Test func marksBecomeInlineIntents() {
        let storage = LoaderFixture.load("a **b** *c* `d` ~~e~~ ***f*** **g _h_**").storage
        #expect(storage.string == "a b c d e f g h")
        let marked = LoaderFixture.intentRuns(storage).filter { !$0.1.isEmpty }
        #expect(marked.map(\.0) == ["b", "c", "d", "e", "f", "g ", "h"])
        #expect(marked.map(\.1) == [
            .stronglyEmphasized,
            .emphasized,
            .code,
            .strikethrough,
            [.stronglyEmphasized, .emphasized],
            .stronglyEmphasized,
            [.stronglyEmphasized, .emphasized]
        ])
    }

    @Test func breaksBecomeLineSeparators() {
        let storage = LoaderFixture.load("soft\nnext  \nhard\\\nslash").storage
        #expect(storage.string == "soft\u{2028}next\u{2028}hard\u{2028}slash")
        #expect(storage.isMarkdownSoftBreak(at: 4))
        #expect(storage.isMarkdownHardBreak(at: 9))
        #expect(storage.isMarkdownHardBreak(at: 14))
        #expect(LoaderFixture.literals(storage).isEmpty)
    }

    @Test func softBreaksBetweenCJKLinesStayBreaks() {
        let storage = LoaderFixture.load("日本語\n中文").storage
        #expect(storage.string == "日本語\u{2028}中文")
        #expect(storage.isMarkdownSoftBreak(at: 3))
    }

    @Test(arguments: ["\\*", "\\\\", "\\_", "\\#", "\\`", "\\[", "\\]", "\\<", "\\~", "\\|"])
    func escapesBecomeLiterals(escape: String) {
        let storage = LoaderFixture.load("a \(escape) b").storage
        #expect(storage.string == "a \(escape.dropFirst()) b")
        #expect(LoaderFixture.literals(storage) == ["\(escape.dropFirst())=\(escape)"])
    }

    @Test(arguments: [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&copy;", "\u{A9}"),
        ("&#169;", "\u{A9}"),
        ("&#x41;", "A"),
        ("&nbsp;", "\u{A0}"),
        ("&quot;", "\""),
        ("&#0;", "\u{FFFD}")
    ])
    func entitiesBecomeLiterals(entity: String, rendered: String) {
        let storage = LoaderFixture.load("x \(entity) y").storage
        #expect(storage.string == "x \(rendered) y")
        #expect(LoaderFixture.literals(storage) == ["\(rendered)=\(entity)"])
    }

    @Test(arguments: [
        ("a\u{2029}b c", "a\u{00A0}b c"),
        ("a\u{2028}b", "a\u{00A0}b"),
        ("a\u{85}b", "a\u{00A0}b"),
        ("- a\n  b\u{2029}c", "a\u{2028}b\u{00A0}c"),
        ("x `a\u{2028}b` y", "x a\u{00A0}b y"),
        ("&#x2028;x", "\u{00A0}x"),
        ("```\na\u{2028}b\n```", "a\u{00A0}b")
    ])
    func unicodeSeparatorsInSourceStayInsideTheirParagraph(markdown: String, text: String) {
        let storage = LoaderFixture.load(markdown).storage
        #expect(LoaderFixture.paragraphs(storage).map(\.text) == [text])
        #expect(Corpus.roundTrip(markdown) == markdown)
    }

    @Test func invalidEntitiesStayText() {
        let storage = LoaderFixture.load("a &bogus; & b").storage
        #expect(storage.string == "a &bogus; & b")
        #expect(LoaderFixture.literals(storage).isEmpty)
    }

    @Test func literalsInsideMarksKeepTheMark() {
        let storage = LoaderFixture.load("**\\*x\\*** and *a &amp; b*").storage
        #expect(storage.string == "*x* and a & b")
        #expect(LoaderFixture.literals(storage) == ["*=\\*", "*=\\*", "&=&amp;"])
        #expect(storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
        #expect(storage.markdownInlineIntent(at: 10) == .emphasized)
    }

    @Test(arguments: [
        "caf\u{E9} na\u{EF}ve",
        "cafe\u{301} nai\u{308}ve",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1EF}\u{1F1F5} \u{1F44D}\u{1F3FD}",
        "日本語のテキスト、한국어",
        "tab\there and\ttwo"
    ])
    func multibyteTextIsVerbatim(text: String) {
        let (storage, report) = LoaderFixture.load("**\(text)** \(text)")
        #expect(storage.string == "\(text) \(text)")
        #expect(report.fallbackRuns == 0)
        #expect(storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
    }

    @Test func literalsAlignAfterMultibyteText() {
        let storage = LoaderFixture.load("日本\\*語 &amp; \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\\_ e\u{301}&copy;").storage
        #expect(storage.string == "日本*語 & \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}_ e\u{301}\u{A9}")
        #expect(LoaderFixture.literals(storage) == ["*=\\*", "&=&amp;", "_=\\_", "\u{A9}=&copy;"])
    }

    @Test func textInsideContainersAlignsPastPrefixes() {
        let (storage, report) = LoaderFixture.load("> - a \\* b\n>   - c &amp; d")
        #expect(report.fallbackRuns == 0)
        #expect(LoaderFixture.literals(storage) == ["*=\\*", "&=&amp;"])
    }

    @Test func lazyContinuationRealignsWithinItsLine() {
        let (storage, report) = LoaderFixture.load("> lazy \\* start\ncontinuation \\* line")
        #expect(storage.string == "lazy * start\u{2028}continuation * line")
        #expect(report.fallbackRuns == 0)
        #expect(LoaderFixture.literals(storage) == ["*=\\*", "*=\\*"])
        #expect(storage.markdownBlock(at: 0)?.isInQuote == true)
    }

    @Test func bareAutolinksKeepTextAndLink() {
        let storage = LoaderFixture.load("see https://b.com/y and www.c.com ok").storage
        #expect(storage.string == "see https://b.com/y and www.c.com ok")
        #expect(storage.markdownLink(at: 6) == "https://b.com/y")
        #expect(storage.markdownLink(at: 26) == "http://www.c.com")
        #expect(storage.markdownLink(at: 2) == nil)
    }

    @Test func linksCarryURLAndRecoverInnerMarks() {
        let (storage, report) = LoaderFixture.load("[a `c` **b** \\* &amp;](https://x.com \"T\") after")
        #expect(storage.string == "a c b * & after")
        #expect(report.fallbackRuns == 0)
        #expect(storage.markdownLink(at: 0) == "https://x.com")
        #expect(storage.markdownLink(at: 8) == "https://x.com")
        #expect(storage.markdownLink(at: 10) == nil)
        #expect(storage.markdownInlineIntent(at: 2) == .code)
        #expect(storage.markdownInlineIntent(at: 4) == .stronglyEmphasized)
        #expect(LoaderFixture.literals(storage) == ["*=\\*", "&=&amp;"])
    }

    @Test(arguments: [
        ("See [the release\nnotes](http://x) for details.", "See the release\u{2028}notes for details."),
        ("> [quoted\n> link](http://x)", "quoted\u{2028}link"),
        ("- [item\n  link](http://x)", "item\u{2028}link"),
        ("> - [nested\n>   label](http://x) tail", "nested\u{2028}label tail")
    ])
    func linkLabelsSpanningLinesKeepTheirBreaks(markdown: String, text: String) {
        let (storage, report) = LoaderFixture.load(markdown)
        #expect(storage.string == text)
        #expect(report.fallbackRuns == 0)
        #expect(Corpus.roundTrip(markdown) == markdown)
    }

    @Test func linkLabelsSpanningLinesKeepInnerEmphasis() {
        let markdown = "[a *b\nc*](http://x)"
        let (storage, report) = LoaderFixture.load(markdown)
        #expect(storage.string == "a b\u{2028}c")
        #expect(report.fallbackRuns == 0)
        #expect(storage.markdownInlineIntent(at: 2) == .emphasized)
        #expect(storage.markdownInlineIntent(at: 4) == .emphasized)
        #expect(storage.markdownLink(at: 4) == "http://x")
        let reloaded = LoaderFixture.load(Corpus.write(storage)).storage
        #expect(reloaded.string == storage.string)
        #expect(LoaderFixture.intentRuns(reloaded).map(\.1) == LoaderFixture.intentRuns(storage).map(\.1))
    }

    @Test func marksAroundLinksApplyToTheLinkText() {
        let storage = LoaderFixture.load("**[in](w) out**").storage
        #expect(storage.string == "in out")
        #expect(storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
        #expect(storage.markdownLink(at: 0) == "w")
        #expect(storage.markdownInlineIntent(at: 4) == .stronglyEmphasized)
    }

    @Test func angleAutolinks() {
        let storage = LoaderFixture.load("<https://a.com> and <me@x.com>").storage
        #expect(storage.string == "https://a.com and me@x.com")
        #expect(storage.markdownLink(at: 0) == "https://a.com")
        #expect(storage.markdownLink(at: 20) == "mailto:me@x.com")
    }

    @Test func codeSpansAreVerbatim() {
        let storage = LoaderFixture.load("a `` x`y `` b `\\*` c").storage
        #expect(storage.string == "a x`y b \\* c")
        #expect(storage.markdownInlineIntent(at: 2) == .code)
        #expect(storage.markdownInlineIntent(at: 8) == .code)
        #expect(LoaderFixture.literals(storage).isEmpty)
    }

    @Test func headingInlineContentAligns() {
        let storage = LoaderFixture.load("## h `c` **b** \\# ##").storage
        #expect(storage.string == "h c b #")
        #expect(storage.markdownBlock(at: 0)?.headingLevel == 2)
        #expect(LoaderFixture.literals(storage) == ["#=\\#"])
    }

    @Test(arguments: [
        ("- [ ] todo", TaskState.unchecked, "todo"),
        ("- [x] done", TaskState.checked, "done"),
        ("- [X] DONE", TaskState.checked, "DONE"),
        ("- [ ]", TaskState.unchecked, ""),
        ("- [x]", TaskState.checked, ""),
        ("1. [ ] ordered", TaskState.unchecked, "ordered"),
        ("- [ ]  two spaces", TaskState.unchecked, " two spaces"),
        ("- [x] **bold**", TaskState.checked, "bold")
    ])
    func taskMarkersAreStripped(markdown: String, state: TaskState, text: String) throws {
        let paragraph = try #require(LoaderFixture.paragraphs(LoaderFixture.load(markdown).storage).first)
        #expect(paragraph.block?.task == state)
        #expect(paragraph.text == text)
        #expect(paragraph.block?.isListItemStart == true)
    }

    @Test(arguments: ["- \\[ ] escaped", "- [ ]x tight", "[ ] top level", "- [y] other", "- *[ ]* marked"])
    func nonTaskMarkersStayText(markdown: String) throws {
        let paragraph = try #require(LoaderFixture.paragraphs(LoaderFixture.load(markdown).storage).first)
        #expect(paragraph.block?.task == nil)
        #expect(paragraph.text.contains("["))
    }

    @Test func tasksOnlyApplyToItemStarts() {
        let paragraphs = LoaderFixture.paragraphs(LoaderFixture.load("- [ ] a\n\n  [x] cont\n  - [x] nested").storage)
        #expect(paragraphs.map(\.text) == ["a", "[x] cont", "nested"])
        #expect(paragraphs.map { $0.block?.task } == [.unchecked, nil, .checked])
        #expect(paragraphs[2].lists.count == 2)
    }

    @Test func remarkupDraftsLoadAsText() {
        let markdown = "//x// ##x## [[url | x]] {nav,  icon=file, name=nit:} {F12345}"
        let (storage, report) = LoaderFixture.load(markdown)
        #expect(storage.string == markdown)
        #expect(report.fallbackRuns == 0)
    }
}

@Suite("Loader inline content rules")
struct LoaderRuleTests {
    static let tokenPattern = #"\{nav(?:\s+|\s*,\s*)icon=([A-Za-z0-9_\-]+)\s*,\s*name=([^}\n]*)\}"#

    static let rules = [
        InlineContentRule(id: "label", pattern: tokenPattern) { match in
            .custom(kind: "label", label: match.capture(2) ?? "", systemImage: "tag")
        }
    ]

    static let provider: ProseInlineContentProvider = { content in
        ChipAttachment.make(for: content)
    }

    @Test func labelsBecomeAttachmentsWithByteExactSource() throws {
        let token = "{nav,  icon=file, name=nit:}"
        let storage = LoaderFixture.load("\(token) body", rules: Self.rules, provider: Self.provider).storage
        #expect(storage.string == "\u{FFFC} body")
        let attachment = try #require(storage.proseSourceAttachment(at: 0))
        #expect(attachment.markdownSource == token)
        #expect(attachment.contentKind == "label")
        #expect(storage.markdownBlock(at: 0) == .paragraph)
    }

    @Test func multipleLabelsAndMarksArePreserved() throws {
        let markdown = "**{nav icon=a, name=x}** then {nav, icon=b,name=y}"
        let storage = LoaderFixture.load(markdown, rules: Self.rules, provider: Self.provider).storage
        #expect(storage.string == "\u{FFFC} then \u{FFFC}")
        #expect(LoaderFixture.attachments(storage).map(\.markdownSource) == ["{nav icon=a, name=x}", "{nav, icon=b,name=y}"])
        #expect(storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
    }

    @Test func labelsInHeadingsAndItems() {
        let markdown = "# {nav, icon=a, name=x} title\n\n- {nav, icon=b, name=y} item"
        let storage = LoaderFixture.load(markdown, rules: Self.rules, provider: Self.provider).storage
        #expect(LoaderFixture.attachments(storage).count == 2)
    }

    @Test(arguments: [
        "`{nav, icon=a, name=x}`",
        "[{nav, icon=a, name=x}](https://x.com)",
        "{nav, icon=a, name=x\\_y}",
        "{nav, icon=a, **name=x**}",
        "```\n{nav, icon=a, name=x}\n```"
    ])
    func labelsAreSkippedInsideCodeLinksLiteralsAndMixedMarks(markdown: String) {
        let storage = LoaderFixture.load(markdown, rules: Self.rules, provider: Self.provider).storage
        #expect(LoaderFixture.attachments(storage).isEmpty)
        #expect(storage.string.contains("{nav"))
    }

    @Test func rulesNeedAProvider() {
        let storage = LoaderFixture.load("{nav, icon=a, name=x}", rules: Self.rules).storage
        #expect(storage.string == "{nav, icon=a, name=x}")
    }

    @Test func attachmentsWithoutSourceAreIgnored() {
        let storage = LoaderFixture.load("{nav, icon=a, name=x}", rules: Self.rules) { _ in NSTextAttachment() }.storage
        #expect(storage.string == "{nav, icon=a, name=x}")
    }

    @Test func providerReturningNilLeavesText() {
        let storage = LoaderFixture.load("{nav, icon=a, name=x}", rules: Self.rules) { _ in nil }.storage
        #expect(LoaderFixture.attachments(storage).isEmpty)
    }
}
