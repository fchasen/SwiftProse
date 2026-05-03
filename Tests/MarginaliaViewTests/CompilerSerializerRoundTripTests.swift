import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView

@Suite(.serialized) struct CompilerSerializerRoundTripTests {

    private func roundTrip(_ markdown: String, dialect: AttributedMarkdownSerializer.Dialect = .commonMark) throws -> String {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        let compilerDialect: MarkdownAttributedCompiler.Dialect =
            (dialect == .commonMark) ? .commonMark : .remarkup
        let attributed = compiler.compile(markdown, dialect: compilerDialect, mode: .rich, theme: .default)
        return serializer.serialize(attributed, dialect: dialect)
    }

    @Test func emptyString() throws {
        #expect(try roundTrip("") == "")
    }

    @Test func plainParagraph() throws {
        let out = try roundTrip("hello world\n")
        #expect(out == "hello world\n")
    }

    @Test func atxHeading() throws {
        let out = try roundTrip("# Hello\n")
        #expect(out == "# Hello\n")
    }

    @Test func multipleHeadings() throws {
        let input = "# H1\n\n## H2\n\n### H3\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func boldInline() throws {
        let out = try roundTrip("This is **bold** word\n")
        #expect(out == "This is **bold** word\n")
    }

    @Test func italicInline() throws {
        let out = try roundTrip("This is *italic* word\n")
        #expect(out == "This is *italic* word\n")
    }

    @Test func boldAndItalicTogether() throws {
        let out = try roundTrip("Mix of **bold** and *italic*\n")
        #expect(out == "Mix of **bold** and *italic*\n")
    }

    @Test func unorderedList() throws {
        let out = try roundTrip("- one\n- two\n- three\n")
        #expect(out == "- one\n- two\n- three\n")
    }

    @Test func orderedList() throws {
        let out = try roundTrip("1. first\n2. second\n3. third\n")
        #expect(out == "1. first\n2. second\n3. third\n")
    }

    @Test func taskList() throws {
        let out = try roundTrip("- [x] done\n- [ ] todo\n")
        #expect(out == "- [x] done\n- [ ] todo\n")
    }

    @Test func blockquote() throws {
        let out = try roundTrip("> quoted line\n")
        #expect(out == "> quoted line\n")
    }

    @Test func horizontalRule() throws {
        let out = try roundTrip("---\n")
        #expect(out == "---\n")
    }

    @Test func inlineCode() throws {
        let out = try roundTrip("Use `let x = 1` here\n")
        #expect(out == "Use `let x = 1` here\n")
    }

    @Test func remarkupItalic() throws {
        let out = try roundTrip("This is //italic// word\n", dialect: .remarkup)
        #expect(out.contains("//italic//"))
    }
}
