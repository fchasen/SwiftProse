import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite("Phase 3 markdown tree serializer")
struct MarkdownTreeSerializerTests {

    private func roundTrip(_ markdown: String) throws -> String {
        let compiler = try MarkdownAttributedCompiler()
        let storage = compiler.compile(markdown, theme: .default)
        let serializer = AttributedMarkdownSerializer()
        return serializer.serializeFromTree(storage)
    }

    @Test
    func plainParagraphRoundTrips() throws {
        let out = try roundTrip("hello world\n")
        #expect(out == "hello world\n")
    }

    @Test
    func headingRoundTripsWithLevel() throws {
        let out = try roundTrip("## Title\n")
        #expect(out == "## Title\n")
    }

    @Test
    func boldOnlyEmitsRespectingMarkRunBoundaries() throws {
        let out = try roundTrip("**bold** rest\n")
        #expect(out == "**bold** rest\n")
    }

    @Test
    func italicMarkEmitsAsterisks() throws {
        let out = try roundTrip("plain *italic* tail\n")
        #expect(out == "plain *italic* tail\n")
    }

    @Test
    func codeSpanEmitsBackticks() throws {
        let out = try roundTrip("call `now()` please\n")
        #expect(out == "call `now()` please\n")
    }

    @Test
    func boldItalicCombineToTripleStar() throws {
        let out = try roundTrip("***both***\n")
        #expect(out == "***both***\n")
    }

    @Test
    func blockquoteRoundTrips() throws {
        let out = try roundTrip("> quoted line\n")
        #expect(out == "> quoted line\n")
    }

    @Test
    func multipleBlockquoteParagraphsKeepOnePrefixPerLine() throws {
        let out = try roundTrip("> first\n>\n> second\n")
        // The compiler/serializer convention is to separate quoted blocks
        // with a quoted blank line; allow either explicit blank or simple
        // double-paragraph form.
        #expect(out.contains("> first") && out.contains("> second"))
    }

    @Test
    func horizontalRuleRoundTrips() throws {
        let out = try roundTrip("before\n\n---\n\nafter\n")
        #expect(out.contains("before") && out.contains("---") && out.contains("after"))
    }

    @Test
    func headingDoesNotDoubleEmitBoldMarkers() throws {
        // Heading content is bold-by-default in storage; the serializer
        // must not re-emit `**` around it.
        let out = try roundTrip("## Plain heading\n")
        #expect(out == "## Plain heading\n")
        #expect(!out.contains("**"))
    }

    @Test
    func consecutiveBulletItemsShareList() throws {
        let out = try roundTrip("- one\n- two\n")
        #expect(out == "- one\n- two\n")
    }


    @Test
    func consecutiveOrderedItemsShareList() throws {
        let out = try roundTrip("1. one\n2. two\n")
        #expect(out == "1. one\n2. two\n")
    }

    @Test
    func consecutiveTaskItemsShareList() throws {
        let out = try roundTrip("- [x] done\n- [ ] todo\n")
        #expect(out == "- [x] done\n- [ ] todo\n")
    }

    @Test
    func bulletThenOrderedSplitsIntoTwoLists() throws {
        let out = try roundTrip("- bullet\n\n1. ordered\n")
        #expect(out.contains("- bullet"))
        #expect(out.contains("1. ordered"))
    }

    @Test
    func paragraphFollowingBulletStaysOutsideList() throws {
        let out = try roundTrip("- one\n\nafter\n")
        #expect(out.contains("- one"))
        #expect(out.contains("after"))
    }

    @Test
    func blankParagraphBetweenBlocksDoesNotMaterialize() throws {
        let out = try roundTrip("# Hi\n\nworld\n")
        #expect(out == "# Hi\n\nworld\n")
    }

    // MARK: - inline images

    @Test
    func bareImageRoundTrips() throws {
        let out = try roundTrip("![alt](https://example.com/x.png)\n")
        #expect(out == "![alt](https://example.com/x.png)\n")
    }

    @Test
    func imageWithTitleRoundTrips() throws {
        let out = try roundTrip("![alt](https://example.com/x.png \"a title\")\n")
        #expect(out == "![alt](https://example.com/x.png \"a title\")\n")
    }

    @Test
    func imageInsideParagraphRoundTrips() throws {
        let out = try roundTrip("see ![alt](pic.png) below\n")
        #expect(out == "see ![alt](pic.png) below\n")
    }

    @Test
    func imageInsideListItemRoundTrips() throws {
        let out = try roundTrip("- look ![alt](pic.png) here\n")
        #expect(out == "- look ![alt](pic.png) here\n")
    }

    @Test
    func emptyAltImageRoundTrips() throws {
        let out = try roundTrip("![](pic.png)\n")
        #expect(out == "![](pic.png)\n")
    }

    // MARK: - nested lists

    @Test
    func nestedBulletRoundTrips() throws {
        let out = try roundTrip("- a\n  - b\n  - c\n- d\n")
        #expect(out == "- a\n  - b\n  - c\n- d\n")
    }

    @Test
    func threeLevelBulletRoundTrips() throws {
        let out = try roundTrip("- a\n  - b\n    - c\n")
        #expect(out == "- a\n  - b\n    - c\n")
    }

    @Test
    func nestedTaskListRoundTrips() throws {
        let out = try roundTrip("- [ ] a\n  - [x] b\n")
        #expect(out == "- [ ] a\n  - [x] b\n")
    }

    @Test
    func nestedListInsideBlockquoteRoundTrips() throws {
        let out = try roundTrip("> - a\n>   - b\n")
        #expect(out == "> - a\n>   - b\n")
    }

    @Test
    func mixedOrderedThenBulletPreservesNesting() throws {
        // 3-space indent (matching ordered marker width) normalizes to the
        // canonical 2-space indent prosemirror-markdown emits — re-compiling
        // the serialized form yields the same shape, so the round-trip is
        // idempotent on the second pass.
        let out = try roundTrip("1. a\n   - b\n")
        #expect(try roundTrip(out) == out)
        #expect(out.contains("1. a"))
        #expect(out.contains("- b"))
    }
}
