import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct SliceTests {

    private func compiler() throws -> MarkdownAttributedCompiler {
        try MarkdownAttributedCompiler()
    }

    @Test func fragmentBasicOps() {
        let inline: TreeNode = .inline(text: "abc", marks: MarkSet())
        let frag = Fragment([inline])
        #expect(frag.childCount == 1)
        #expect(frag.firstChild == inline)
        #expect(frag.lastChild == inline)

        let appended = frag.appending(.inline(text: "def", marks: MarkSet()))
        #expect(appended.childCount == 2)
        #expect(appended.lastChild?.contentLength == 3)

        let cut = appended.cut(from: 1)
        #expect(cut.childCount == 1)
        #expect(cut.firstChild?.contentLength == 3)
    }

    @Test func sliceMaxOpenWalksStructural() {
        let inner: TreeNode = .inline(text: "x", marks: MarkSet())
        let para: TreeNode = .structural(
            ProseNode(type: "paragraph"),
            [inner]
        )
        let frag = Fragment([para])
        let slice = Slice.maxOpen(frag)
        #expect(slice.openStart == 1)
        #expect(slice.openEnd == 1)
    }

    @Test func sliceMaxOpenStopsAtIsolating() {
        let table: TreeNode = .structural(
            ProseNode(type: "table"),
            [.inline(text: "cell", marks: MarkSet())]
        )
        let frag = Fragment([table])
        let slice = Slice.maxOpen(frag, openIsolating: false)
        #expect(slice.openStart == 0)
        #expect(slice.openEnd == 0)
    }

    @Test func singleParagraphCompilesToInlineFragment() throws {
        let compiler = try compiler()
        let slice = compiler.compileSlice("hello", theme: .default)
        // Single-paragraph source unwraps to its inline children so the
        // slice can merge into surrounding context.
        #expect(slice.content.children.count == 1)
        if case .inline(let text, _) = slice.content.firstChild {
            #expect(text == "hello")
        } else {
            Issue.record("expected inline child, got \(String(describing: slice.content.firstChild))")
        }
    }

    @Test func multiBlockCompilesToBlockChildren() throws {
        let compiler = try compiler()
        let slice = compiler.compileSlice("para one\n\npara two", theme: .default)
        #expect(slice.content.children.count == 2)
        for kid in slice.content.children {
            if case .structural(let pn, _) = kid {
                #expect(pn.type == "paragraph")
            } else {
                Issue.record("expected paragraph, got \(kid)")
            }
        }
    }

    @Test func markdownRoundTripSinglePara() throws {
        let compiler = try compiler()
        let serializer = MarkdownTreeSerializer()
        let slice = compiler.compileSlice("foo *bar* baz", theme: .default)
        let md = serializer.serializeSlice(slice)
        // Inline source round-trips without a trailing newline.
        #expect(md == "foo *bar* baz")
    }

    @Test func markdownRoundTripMultiBlock() throws {
        let compiler = try compiler()
        let serializer = MarkdownTreeSerializer()
        let slice = compiler.compileSlice("# Heading\n\nbody text", theme: .default)
        let md = serializer.serializeSlice(slice)
        #expect(md.contains("# Heading"))
        #expect(md.contains("body text"))
    }

    @Test func sliceJSONRoundTripInline() throws {
        let compiler = try compiler()
        let codec = ProseMirrorCodec()
        let original = compiler.compileSlice("hello *world*", theme: .default)
        let json = codec.encodeSlice(original)
        let decoded = try #require(codec.decodeSlice(json))
        #expect(decoded.openStart == original.openStart)
        #expect(decoded.openEnd == original.openEnd)
        #expect(decoded.content.childCount == original.content.childCount)
    }

    @Test func sliceJSONRoundTripMultiBlock() throws {
        let compiler = try compiler()
        let codec = ProseMirrorCodec()
        let original = compiler.compileSlice("# Heading\n\npara", theme: .default)
        let json = codec.encodeSlice(original)
        let decoded = try #require(codec.decodeSlice(json))
        #expect(decoded.content.childCount == original.content.childCount)
        // Top-level children survive — first should be a heading.
        if case .structural(let pn, _) = decoded.content.firstChild {
            #expect(pn.type == "heading")
        } else {
            Issue.record("expected heading first child, got \(String(describing: decoded.content.firstChild))")
        }
    }

    @Test func sliceJSONOmitsZeroOpenFields() throws {
        let slice = Slice(content: Fragment([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "x", marks: MarkSet())
            ])
        ]), openStart: 0, openEnd: 0)
        let codec = ProseMirrorCodec()
        let json = codec.encodeSlice(slice)
        guard case .object(let obj) = json else {
            Issue.record("expected object")
            return
        }
        #expect(obj["openStart"] == nil)
        #expect(obj["openEnd"] == nil)
        #expect(obj["content"] != nil)
    }

    @Test func emptySliceConstants() {
        #expect(Slice.empty.isEmpty)
        #expect(Slice.empty.content.isEmpty)
        #expect(Slice.empty.openStart == 0)
        #expect(Slice.empty.openEnd == 0)
    }

    @Test func compileSliceTrimsTrailingEmptyParagraph() throws {
        let compiler = try compiler()
        // Markdown with trailing whitespace tends to add an empty paragraph;
        // compileSlice should trim it so the inline branch fires.
        let slice = compiler.compileSlice("hello\n", theme: .default)
        #expect(slice.content.childCount == 1)
        if case .inline(let text, _) = slice.content.firstChild {
            #expect(text == "hello")
        }
    }
}
