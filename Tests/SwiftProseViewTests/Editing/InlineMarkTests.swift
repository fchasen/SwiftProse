import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

struct MarkCase: CustomTestStringConvertible, Sendable {
    let marks: EditorDocument.InlineMarks
    let markdown: String
    let linkedMarkdown: String

    var testDescription: String {
        var names: [String] = []
        if marks.contains(.strong) { names.append("strong") }
        if marks.contains(.emphasis) { names.append("emphasis") }
        if marks.contains(.code) { names.append("code") }
        if marks.contains(.strikethrough) { names.append("strikethrough") }
        return names.isEmpty ? "plain" : names.joined(separator: "+")
    }
}

enum MarkCases {
    static let url = "https://example.com/p"

    static let marks: [MarkCase] = [
        MarkCase(marks: [], markdown: "a word b", linkedMarkdown: "a [word](\(url)) b"),
        MarkCase(marks: [.strong], markdown: "a **word** b", linkedMarkdown: "a **[word](\(url))** b"),
        MarkCase(marks: [.emphasis], markdown: "a *word* b", linkedMarkdown: "a *[word](\(url))* b"),
        MarkCase(marks: [.strong, .emphasis], markdown: "a ***word*** b", linkedMarkdown: "a ***[word](\(url))*** b"),
        MarkCase(marks: [.code], markdown: "a `word` b", linkedMarkdown: "a [`word`](\(url)) b"),
        MarkCase(marks: [.strong, .code], markdown: "a **`word`** b", linkedMarkdown: "a **[`word`](\(url))** b"),
        MarkCase(marks: [.emphasis, .code], markdown: "a *`word`* b", linkedMarkdown: "a *[`word`](\(url))* b"),
        MarkCase(marks: [.strong, .emphasis, .code], markdown: "a ***`word`*** b", linkedMarkdown: "a ***[`word`](\(url))*** b"),
        MarkCase(marks: [.strikethrough], markdown: "a ~~word~~ b", linkedMarkdown: "a ~~[word](\(url))~~ b"),
        MarkCase(marks: [.strikethrough, .strong], markdown: "a ~~**word**~~ b", linkedMarkdown: "a ~~**[word](\(url))**~~ b"),
        MarkCase(marks: [.strikethrough, .emphasis], markdown: "a ~~*word*~~ b", linkedMarkdown: "a ~~*[word](\(url))*~~ b"),
        MarkCase(marks: [.strikethrough, .strong, .emphasis], markdown: "a ~~***word***~~ b", linkedMarkdown: "a ~~***[word](\(url))***~~ b"),
        MarkCase(marks: [.strikethrough, .code], markdown: "a ~~`word`~~ b", linkedMarkdown: "a ~~[`word`](\(url))~~ b"),
        MarkCase(marks: [.strikethrough, .strong, .code], markdown: "a ~~**`word`**~~ b", linkedMarkdown: "a ~~**[`word`](\(url))**~~ b"),
        MarkCase(marks: [.strikethrough, .emphasis, .code], markdown: "a ~~*`word`*~~ b", linkedMarkdown: "a ~~*[`word`](\(url))*~~ b"),
        MarkCase(marks: [.strikethrough, .strong, .emphasis, .code], markdown: "a ~~***`word`***~~ b", linkedMarkdown: "a ~~***[`word`](\(url))***~~ b"),
    ]
}

@Suite("Inline mark combinations")
struct InlineMarkTests {
    @Test func everyMarkCombinationIsCovered() {
        #expect(Set(MarkCases.marks.map(\.marks.rawValue)) == Set(0..<16))
    }

    @Test(arguments: MarkCases.marks)
    func writerOutputForMarks(_ mark: MarkCase) {
        #expect(WF.inline(WF.t("a "), WF.t("word", mark.marks), WF.t(" b")) == mark.markdown)
        #expect(WF.inline(WF.t("a "), WF.t("word", mark.marks, link: MarkCases.url), WF.t(" b")) == mark.linkedMarkdown)
    }

    @Test(arguments: MarkCases.marks)
    func loaderRoundTripsMarkdownForMarks(_ mark: MarkCase) {
        #expect(Corpus.roundTrip(mark.markdown) == mark.markdown)
        #expect(Corpus.roundTrip(mark.linkedMarkdown) == mark.linkedMarkdown)
    }

    @Test func blockConstructsRoundTrip() {
        let source = "# Title\n\n## Section\n\n- **a**\n- *b*\n\n> `q`\n\n```js\nlet *x* = 1;\n```"
        #expect(Corpus.roundTrip(source) == source)
    }

    @Test func partialMarksInsideWords() {
        #expect(WF.inline(WF.t("pre"), WF.t("mid", .strong), WF.t("post")) == "pre**mid**post")
    }

    @Test func emphasisNextToStrongUsesUnderscore() {
        #expect(WF.inline(WF.t("a ", .strong), WF.t("b", [.strong, .emphasis])) == "**a _b_**")
    }

    @Test func labelNextToEmphasisRoundTrips() {
        let source = "{nav,  icon=file, name=Ready} *nice*"
        #expect(Corpus.roundTrip(source, labels: true) == source)
    }

    @Test func slashHashAndBracketPunctuationIsWrittenUnescaped() {
        let markdown = WF.inline(WF.t("a * b _ c # d [e] //f// ##g##"))
        #expect(markdown == "a * b _ c # d [e] //f// ##g##")
        #expect(!markdown.contains("\\"))
    }
}
