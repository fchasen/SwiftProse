import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Table load and write")
struct TableRoundTripTests {
    @Test(arguments: [
        "| a | b | c | d |\n| --- | :--- | :---: | ---: |\n| 1 | 2 | 3 | 4 |",
        "| a \\| b | `c \\| d` |\n| --- | --- |\n| x | y |",
        "| **b** *i* ~~s~~ | [l](https://x.com) |\n| --- | --- |\n| `code` | &amp; \\* |",
        "| a | |\n| --- | --- |\n| | b |",
        "| only |\n| --- |",
        "> | q |\n> | --- |\n> | 1 |",
        "- item\n\n  | a | b |\n  | --- | --- |\n  | 1 | 2 |\n- next",
        "| a |\n| --- |\n| 1 |\n\n| b |\n| --- |\n| 2 |",
        "Intro\n\n| a |\n| --- |\n| 1 |\n\nAfter"
    ])
    func canonicalTablesAreFixedPoints(markdown: String) {
        let storage = Corpus.load(markdown)
        #expect(LoaderFixture.blockIsUniform(storage))
        #expect(Corpus.write(storage) == markdown)
    }

    @Test func headerAndBodyDistinction() {
        let storage = Corpus.load("| h1 | h2 |\n| --- | --- |\n| a | b |")
        let rows = LoaderFixture.paragraphs(storage)
        #expect(rows.map { $0.block?.isTableHeader } == [true, false])
        #expect(Corpus.write(storage) == "| h1 | h2 |\n| --- | --- |\n| a | b |")
    }

    @Test func multipleBodyRows() {
        let markdown = "| h1 | h2 |\n| --- | --- |\n| a1 | a2 |\n| b1 | b2 |\n| c1 | c2 |"
        let storage = Corpus.load(markdown)
        #expect(TableFixture.rows(storage) == ["h1\th2", "a1\ta2", "b1\tb2", "c1\tc2"])
        #expect(Corpus.write(storage) == markdown)
    }

    @Test func alignmentsLoadIntoEveryRow() {
        let storage = Corpus.load("| a | b | c | d |\n| --- | :--- | :---: | ---: |\n| 1 | 2 | 3 | 4 |")
        let rows = LoaderFixture.paragraphs(storage)
        #expect(rows.allSatisfy { $0.block?.tableAlignments == [.none, .left, .center, .right] })
        #expect(rows.map(\.text) == ["a\tb\tc\td", "1\t2\t3\t4"])
    }

    @Test func escapedPipesBecomeCellText() {
        let storage = Corpus.load("| a \\| b | `c \\| d` |\n| --- | --- |")
        #expect(TableFixture.rows(storage) == ["a | b\tc | d"])
        #expect(storage.markdownInlineIntent(at: 6) == .code)
        #expect(storage.markdownLiteral(at: 2) == nil)
    }

    @Test func chipsAndLinksLiveInsideCells() {
        let markdown = "| {nav, icon=file, name=Ready} | [docs](https://x.com) |\n| --- | --- |\n| a | b |"
        let storage = Corpus.load(markdown, labels: true)
        #expect(TableFixture.rows(storage).first == "\u{FFFC}\tdocs")
        #expect(storage.proseSourceAttachment(at: 0)?.markdownSource == "{nav, icon=file, name=Ready}")
        #expect(storage.markdownLink(at: 2) == "https://x.com")
        #expect(Corpus.write(storage) == markdown)
    }

    @Test func raggedRowsArePaddedAndClipped() {
        let storage = Corpus.load("| a | b |\n| --- | --- |\n| 1 |\n| 1 | 2 | 3 |")
        #expect(TableFixture.rows(storage) == ["a\tb", "1\t", "1\t2"])
    }

    @Test func readerGathersRowsIntoATableBlock() {
        let storage = Corpus.load("| a | **b** |\n| :---: | --- |\n| 1 | 2 |")
        let document = StorageReader().document(from: storage)
        guard case .table(let table)? = document.blocks.first else {
            Issue.record("expected a table block")
            return
        }
        #expect(table.alignments == [.center, .none])
        #expect(table.header.count == 2)
        #expect(table.header[1] == [.text("b", marks: .strong)])
        #expect(table.body == [[[.text("1")], [.text("2")]]])
        #expect(MarkdownWriter().write(document) == "| a | **b** |\n| :---: | --- |\n| 1 | 2 |")
    }

    @Test func writerEscapesPipesInTextCodeAndAtoms() {
        let table = EditorDocument.TableBlock(
            alignments: [.none, .none, .none],
            header: [
                [.text("a|b")],
                [.text("c|d", marks: .code)],
                [EditorDocument.InlineRun(.atom(.init(source: "![x|y](u)", kind: AtomKind.image)))]
            ],
            body: [[[.text("x"), EditorDocument.InlineRun(.hardBreak), .text("y")], [], [.text("  padded  ")]]]
        )
        let written = MarkdownWriter().write(EditorDocument(blocks: [.table(table)]))
        #expect(written == "| a\\|b | `c\\|d` | ![x\\|y](u) |\n| --- | --- | --- |\n| x y | | padded |")
        let reloaded = Corpus.load(written)
        #expect(TableFixture.rows(reloaded) == ["a|b\tc|d\t\u{FFFC}", "x y\t\tpadded"])
    }

    @Test func pipeTypedIntoACellIsEscaped() {
        let storage = Corpus.load("| a |\n| --- |")
        storage.insert(NSAttributedString(string: "|", attributes: storage.attributes(at: 0, effectiveRange: nil)), at: 1)
        #expect(Corpus.write(storage) == "| a\\| |\n| --- |")
    }
}
