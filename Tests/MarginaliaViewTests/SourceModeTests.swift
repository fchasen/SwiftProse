import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView

@Suite(.serialized) struct SourceModeTests {

    @Test func sourceModeStorageMatchesMarkdownVerbatim() throws {
        let compiler = try MarkdownAttributedCompiler()
        let md = "# Heading\n\n**bold** word\n"
        let attributed = compiler.compile(md, dialect: .commonMark, mode: .source, theme: .default)
        #expect(attributed.string == md)
    }

    @Test func sourceModeRoundTripIsIdentity() throws {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        let md = "## Header\n\n- one\n- two\n\n> quote\n"
        let attributed = compiler.compile(md, dialect: .commonMark, mode: .source, theme: .default)
        let out = serializer.serialize(attributed, dialect: .commonMark)
        // In source mode storage is verbatim source; serializer walks it
        // as plain runs (no marginaliaBlock attribute). Result should
        // match the input.
        #expect(out == md || out + "\n" == md || out == md + "\n")
    }

    @Test func controllerToggleModeRoundtripsMarkdown() throws {
        let controller = try EditorController(
            initialMarkdown: "# Hello\n\n- one\n- two\n",
            theme: .default,
            dialect: .commonMark,
            mode: .rich
        )
        // Round-trip through serialize → re-emit
        let initialMd = controller.markdown()
        controller.mode = .source
        let sourceMd = controller.markdown()
        #expect(sourceMd == initialMd, "mode switch must preserve markdown")
        controller.mode = .rich
        let backMd = controller.markdown()
        #expect(backMd == initialMd, "switching back must preserve markdown")
    }
}
