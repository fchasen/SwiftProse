import Testing
import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline
@testable import MarginaliaSyntax

@Suite(.serialized) struct ParserSmokeTests {

    @Test func blockGrammarLoads() throws {
        let parser = Parser()
        try parser.setLanguage(Language(language: tree_sitter_markdown()))
    }

    @Test func inlineGrammarLoads() throws {
        let parser = Parser()
        try parser.setLanguage(Language(language: tree_sitter_markdown_inline()))
    }

    @Test func parsesAtxHeading() throws {
        let parser = Parser()
        try parser.setLanguage(Language(language: tree_sitter_markdown()))
        let source = "# heading\n"
        let tree = try #require(parser.parse(source))
        let root = try #require(tree.rootNode)
        let s = root.sExpressionString ?? ""
        #expect(s.contains("atx_heading"), "expected atx_heading in: \(s)")
    }

    @Test func parsesFencedCodeBlock() throws {
        let parser = Parser()
        try parser.setLanguage(Language(language: tree_sitter_markdown()))
        let source = "```\nlet x = 1\n```\n"
        let tree = try #require(parser.parse(source))
        let s = tree.rootNode!.sExpressionString ?? ""
        #expect(s.contains("fenced_code_block"), "expected fenced_code_block in: \(s)")
    }

    @Test func incrementalParseChangedRanges() throws {
        let parser = Parser()
        try parser.setLanguage(Language(language: tree_sitter_markdown()))
        let source1 = "Hello\n"
        let tree1 = try #require(parser.parse(source1))

        // Insert "# " at offset 0 (turns "Hello" into a heading)
        let edit = InputEdit(
            startByte: 0,
            oldEndByte: 0,
            newEndByte: 2,
            startPoint: Point(row: 0, column: 0),
            oldEndPoint: Point(row: 0, column: 0),
            newEndPoint: Point(row: 0, column: 2)
        )
        tree1.edit(edit)
        let source2 = "# Hello\n"
        let tree2 = try #require(parser.parse(tree: tree1, string: source2))

        let changed = tree1.changedRanges(from: tree2)
        #expect(!changed.isEmpty, "expected at least one changed range")
    }
}
