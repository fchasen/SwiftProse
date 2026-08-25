import Testing
import Foundation
import SwiftTreeSitter
@testable import SwiftProseSyntax

@Suite(.serialized) struct MarkdownParserTests {

    @Test func freshParse() throws {
        let p = try MarkdownParser(grammar: .block)
        let tree = try #require(p.parse("# heading\n"))
        let root = try #require(tree.rootNode)
        let s = root.sExpressionString ?? ""
        #expect(s.contains("atx_heading"))
    }

    @Test func reParseTracksMappingState() throws {
        let p = try MarkdownParser(grammar: .block)
        p.parse("a")
        #expect(p.mapping.text == "a")
        p.parse("ab")
        #expect(p.mapping.text == "ab")
    }

    @Test func inlineGrammarDirectParse() throws {
        let p = try MarkdownParser(grammar: .inline)
        let tree = try #require(p.parse("**bold** and *italic*"))
        let root = try #require(tree.rootNode)
        let s = root.sExpressionString ?? ""
        #expect(s.contains("strong_emphasis") || s.contains("emphasis"),
                "expected emphasis nodes in: \(s)")
    }
}
