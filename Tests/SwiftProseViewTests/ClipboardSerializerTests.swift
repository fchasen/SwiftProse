import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct DOMSerializerTests {

    @Test func paragraphWrapsInline() {
        let dom = DOMSerializer()
        let frag = Fragment([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "hello", marks: MarkSet())
            ])
        ])
        #expect(dom.serialize(frag) == "<p>hello</p>")
    }

    @Test func headingLevelSurfacesInTagName() {
        let dom = DOMSerializer()
        let frag = Fragment([
            .structural(
                ProseNode(type: "heading", attrs: ["level": .int(3)]),
                [.inline(text: "h3", marks: MarkSet())]
            )
        ])
        #expect(dom.serialize(frag) == "<h3>h3</h3>")
    }

    @Test func strongAndEmNestInSchemaOrder() {
        let dom = DOMSerializer()
        let marks = MarkSet([
            ProseMark(type: "strong"),
            ProseMark(type: "em")
        ])
        let frag = Fragment([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "x", marks: marks)
            ])
        ])
        let html = dom.serialize(frag)
        // Schema declares link, em, strong, code, strike — so em outer, strong inner.
        #expect(html == "<p><em><strong>x</strong></em></p>")
    }

    @Test func linkMarkEmitsAnchor() {
        let dom = DOMSerializer()
        let link = ProseMark(type: "link", attrs: [
            "href": .string("https://example.com")
        ])
        let frag = Fragment([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "click", marks: MarkSet([link]))
            ])
        ])
        let html = dom.serialize(frag)
        #expect(html.contains("<a href=\"https://example.com\">click</a>"))
    }

    @Test func bulletList() {
        let dom = DOMSerializer()
        let frag = Fragment([
            .structural(ProseNode(type: "bullet_list"), [
                .structural(ProseNode(type: "list_item"), [
                    .structural(ProseNode(type: "paragraph"), [
                        .inline(text: "item", marks: MarkSet())
                    ])
                ])
            ])
        ])
        #expect(dom.serialize(frag) == "<ul><li><p>item</p></li></ul>")
    }

    @Test func codeBlockCarriesLanguageClass() {
        let dom = DOMSerializer()
        let frag = Fragment([
            .structural(
                ProseNode(type: "code_block", attrs: ["params": .string("swift")]),
                [.inline(text: "let x = 1", marks: MarkSet())]
            )
        ])
        let html = dom.serialize(frag)
        #expect(html == "<pre><code class=\"language-swift\">let x = 1</code></pre>")
    }

    @Test func imageLeafSurvivesEncoding() {
        let dom = DOMSerializer()
        let frag = Fragment([
            .leaf(ProseNode(type: "image", attrs: [
                "src": .string("a.png"),
                "alt": .string("alt"),
                "title": .string("")
            ]), MarkSet())
        ])
        let html = dom.serialize(frag)
        #expect(html.contains("<img"))
        #expect(html.contains("src=\"a.png\""))
        #expect(html.contains("alt=\"alt\""))
    }

    @Test func textIsHtmlEscaped() {
        let dom = DOMSerializer()
        let frag = Fragment([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "a < b & c > d", marks: MarkSet())
            ])
        ])
        #expect(dom.serialize(frag) == "<p>a &lt; b &amp; c &gt; d</p>")
    }
}

@Suite(.serialized) struct ClipboardSerializerTests {

    @Test func bundleCarriesTextHtmlAndSlice() throws {
        let controller = try EditorController(initialMarkdown: "hello world", theme: .default)
        let slice = controller.sliceForRange(NSRange(location: 0, length: 5))
        let serializer = ClipboardSerializer(schema: .defaultMarkdown)
        let bundle = serializer.serializeForClipboard(controller: controller, slice: slice)
        #expect(bundle.text == "hello")
        let html = try #require(bundle.html)
        #expect(html.contains("data-pm-slice="))
        // Inline slices have open boundaries (openStart=openEnd=1) so the
        // body emits its inline children without paragraph wrapping.
        #expect(html.contains("hello"))
        #expect(!html.contains("<p>"))
    }

    @Test func multiBlockSerialization() throws {
        let controller = try EditorController(initialMarkdown: "# Title\n\nbody", theme: .default)
        let slice = controller.sliceForRange(
            NSRange(location: 0, length: controller.textStorage.length)
        )
        let serializer = ClipboardSerializer(schema: .defaultMarkdown)
        let bundle = serializer.serializeForClipboard(controller: controller, slice: slice)
        let html = try #require(bundle.html)
        #expect(html.contains("<h1>"))
        #expect(html.contains("<p>body</p>"))
        #expect(bundle.text == "Title\nbody")
        #expect(serializer.renderMarkdown(slice).contains("# Title"))
    }

    @Test func dataPmSliceMarkerIncludesOpenDepths() throws {
        let controller = try EditorController(initialMarkdown: "abc", theme: .default)
        let slice = controller.sliceForRange(NSRange(location: 0, length: 3))
        let serializer = ClipboardSerializer(schema: .defaultMarkdown)
        let html = serializer.renderHTML(slice)
        // Inline slice → openStart=1, openEnd=1
        #expect(html.contains("data-pm-slice=\"1 1 []\""))
    }

    @Test func emptySelectionProducesEmptySlice() throws {
        let controller = try EditorController(initialMarkdown: "abc", theme: .default)
        let slice = controller.sliceForRange(NSRange(location: 1, length: 0))
        #expect(slice.isEmpty)
    }

    @Test func sliceForRangeHandlesPartialSelection() throws {
        let controller = try EditorController(initialMarkdown: "alpha beta", theme: .default)
        let slice = controller.sliceForRange(NSRange(location: 6, length: 4))
        // Inline-only slice — single inline child carrying "beta"
        #expect(slice.openStart == 1)
        #expect(slice.openEnd == 1)
        let serializer = MarkdownTreeSerializer()
        #expect(serializer.serializeSlice(slice) == "beta")
    }
}
