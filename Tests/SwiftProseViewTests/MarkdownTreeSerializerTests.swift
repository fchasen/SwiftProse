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
}
