import Testing
import Foundation
import SwiftTreeSitter
@testable import MarginaliaSyntax

@Suite(.serialized) struct MarkdownParserTests {

    @Test func freshParse() throws {
        let p = try MarkdownParser(grammar: .block)
        let tree = try #require(p.parse("# heading\n"))
        let root = try #require(tree.rootNode)
        let s = root.sExpressionString ?? ""
        #expect(s.contains("atx_heading"))
    }

    @Test func incrementalReParseAfterTextInsert() throws {
        let p = try MarkdownParser(grammar: .block)
        p.parse("Hello\n")
        let changed = p.applyEdit(
            replacing: NSRange(location: 0, length: 0),
            with: "# ",
            newSource: "# Hello\n"
        )
        #expect(!changed.isEmpty)
        let root = try #require(p.rootNode)
        let s = root.sExpressionString ?? ""
        #expect(s.contains("atx_heading"))
    }

    @Test func incrementalParseTracksMappingState() throws {
        let p = try MarkdownParser(grammar: .block)
        p.parse("a")
        #expect(p.mapping.text == "a")
        p.applyEdit(
            replacing: NSRange(location: 1, length: 0),
            with: "b",
            newSource: "ab"
        )
        #expect(p.mapping.text == "ab")
    }

    @Test func incrementalReParseDeletion() throws {
        let p = try MarkdownParser(grammar: .block)
        p.parse("# heading\nbody\n")
        let changed = p.applyEdit(
            replacing: NSRange(location: 0, length: 2),
            with: "",
            newSource: "heading\nbody\n"
        )
        #expect(!changed.isEmpty)
        // After removing "# " the heading becomes a paragraph
        let root = try #require(p.rootNode)
        let s = root.sExpressionString ?? ""
        #expect(!s.contains("atx_heading"))
        #expect(s.contains("paragraph"))
    }

    @Test func incrementalReParseFenceOpening() throws {
        // Opening a fence affects classification of subsequent lines —
        // changedRanges should reflect that the lines below shifted role.
        let p = try MarkdownParser(grammar: .block)
        p.parse("text\nmore\n")
        p.applyEdit(
            replacing: NSRange(location: 0, length: 0),
            with: "```\n",
            newSource: "```\ntext\nmore\n"
        )
        let root = try #require(p.rootNode)
        let s = root.sExpressionString ?? ""
        #expect(s.contains("fenced_code_block"))
    }

    @Test func inlineGrammarDirectParse() throws {
        let p = try MarkdownParser(grammar: .inline)
        let tree = try #require(p.parse("**bold** and *italic*"))
        let root = try #require(tree.rootNode)
        let s = root.sExpressionString ?? ""
        #expect(s.contains("strong_emphasis") || s.contains("emphasis"),
                "expected emphasis nodes in: \(s)")
    }

    @Test func applyEditWithoutPriorParseFallsBackToFreshParse() throws {
        let p = try MarkdownParser(grammar: .block)
        let changed = p.applyEdit(
            replacing: NSRange(location: 0, length: 0),
            with: "# h",
            newSource: "# h"
        )
        #expect(!changed.isEmpty)
        #expect(p.mapping.text == "# h")
    }
}
