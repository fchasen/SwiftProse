import Testing
import Foundation
import SwiftTreeSitter
@testable import MarginaliaSyntax

@Suite(.serialized) struct HighlightApplierTests {

    private func block(_ source: String) throws -> [HighlightSpan] {
        let p = try MarkdownParser(grammar: .block)
        let tree = try #require(p.parse(source))
        let root = try #require(tree.rootNode)
        let applier = try HighlightApplier()
        return applier.highlights(rootNode: root, in: tree, mapping: p.mapping, grammar: .block)
    }

    private func inline(_ source: String) throws -> [HighlightSpan] {
        let p = try MarkdownParser(grammar: .inline)
        let tree = try #require(p.parse(source))
        let root = try #require(tree.rootNode)
        let applier = try HighlightApplier()
        return applier.highlights(rootNode: root, in: tree, mapping: p.mapping, grammar: .inline)
    }

    // MARK: - block grammar

    @Test func headingMarkerAndTitle() throws {
        let spans = try block("# heading\n")
        #expect(spans.contains { $0.tag == .punctuationSpecial },
                "expected '#' marker as punctuation.special: \(spans)")
        #expect(spans.contains { $0.tag == .textTitle },
                "expected heading title: \(spans)")
    }

    @Test func headingTitleRangeMatchesUTF16() throws {
        let spans = try block("# h\n")
        let title = spans.first { $0.tag == .textTitle }
        #expect(title != nil)
        // "# h\n" — title text "h" lives at utf16 offset 2 length 1
        #expect(title?.range.location == 2)
        #expect(title?.range.length == 1)
    }

    @Test func fencedCodeBlockHighlights() throws {
        let spans = try block("```\nlet x = 1\n```\n")
        #expect(spans.contains { $0.tag == .textLiteral })
        #expect(spans.contains { $0.tag == .punctuationDelimiter })
    }

    @Test func listMarkers() throws {
        let spans = try block("- a\n- b\n")
        let markers = spans.filter { $0.tag == .punctuationSpecial }
        #expect(markers.count >= 2)
    }

    @Test func thematicBreak() throws {
        let spans = try block("---\n")
        #expect(spans.contains { $0.tag == .punctuationSpecial })
    }

    @Test func blockquoteMarker() throws {
        let spans = try block("> quoted\n")
        #expect(spans.contains { $0.tag == .punctuationSpecial })
    }

    // MARK: - inline grammar

    @Test func strongEmphasis() throws {
        let spans = try inline("**bold**")
        #expect(spans.contains { $0.tag == .textStrong })
        #expect(spans.contains { $0.tag == .punctuationDelimiter })
    }

    @Test func emphasis() throws {
        let spans = try inline("*italic*")
        #expect(spans.contains { $0.tag == .textEmphasis })
    }

    @Test func codeSpan() throws {
        let spans = try inline("`code`")
        #expect(spans.contains { $0.tag == .textLiteral })
    }

    @Test func inlineLink() throws {
        let spans = try inline("[label](https://example.com)")
        // Brackets, parens, and the URL destination are all classified as
        // markup so they hide off-line; the label content is text.reference.
        #expect(spans.contains { $0.tag == .punctuationDelimiter })
        #expect(spans.contains { $0.tag == .textReference })
    }

    @Test func uriAutolinkStaysVisible() throws {
        let spans = try inline("<https://example.com>")
        // Standalone autolinks have no separate label, so they keep text.uri
        // styling and aren't hidden.
        #expect(spans.contains { $0.tag == .textURI })
    }

    @Test func emphasisRangeIncludesContent() throws {
        let spans = try inline("**bold**")
        let strongSpan = spans.first { $0.tag == .textStrong }
        #expect(strongSpan != nil)
        // strong_emphasis covers the whole "**bold**" — utf16 [0, 8)
        #expect(strongSpan?.range.location == 0)
        #expect(strongSpan?.range.length == 8)
    }
}
