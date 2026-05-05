import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct CompilerSerializerRoundTripTests {

    private func roundTrip(_ markdown: String) throws -> String {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        let attributed = compiler.compile(markdown, theme: .default)
        return serializer.serialize(attributed)
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

    @Test func fencedCodeBlock() throws {
        let out = try roundTrip("```swift\nlet x = 1\n```\n")
        #expect(out == "```swift\nlet x = 1\n```\n")
    }

    @Test func fencedCodeBlockNoLanguage() throws {
        let out = try roundTrip("```\nlet x = 1\n```\n")
        #expect(out == "```\nlet x = 1\n```\n")
    }

    @Test func fencedCodeBlockMultipleLines() throws {
        let out = try roundTrip("```swift\nlet x = 1\nlet y = 2\n```\n")
        #expect(out == "```swift\nlet x = 1\nlet y = 2\n```\n")
    }

    @Test func indentedCodeBlock() throws {
        let out = try roundTrip("    let x = 1\n")
        #expect(out == "    let x = 1\n")
    }

    @Test func indentedCodeBlockMultipleLines() throws {
        let out = try roundTrip("    let x = 1\n    let y = 2\n")
        #expect(out == "    let x = 1\n    let y = 2\n")
    }

    @Test func linkReferenceDefinition() throws {
        let out = try roundTrip("[ref]: https://example.com\n")
        #expect(out == "[ref]: https://example.com\n")
    }

    @Test func linkReferenceDefinitionWithTitle() throws {
        let out = try roundTrip("[ref]: https://example.com \"docs\"\n")
        #expect(out == "[ref]: https://example.com \"docs\"\n")
    }

}
