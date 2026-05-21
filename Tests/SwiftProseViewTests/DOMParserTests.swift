import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct DOMParserTests {

    private func parse(_ html: String) -> Slice? {
        DOMParser().parse(html)
    }

    @Test func emptyHtmlReturnsNil() {
        #expect(parse("") == nil)
    }

    @Test func paragraphParses() throws {
        let slice = try #require(parse("<p>hello</p>"))
        #expect(slice.content.childCount == 1)
        if case .structural(let pn, let kids) = slice.content.firstChild {
            #expect(pn.type == "paragraph")
            #expect(kids.count == 1)
            if case .inline(let text, _) = kids[0] {
                #expect(text == "hello")
            }
        } else {
            Issue.record("expected paragraph")
        }
    }

    @Test func headingParses() throws {
        let slice = try #require(parse("<h2>title</h2>"))
        if case .structural(let pn, _) = slice.content.firstChild {
            #expect(pn.type == "heading")
            #expect(pn.attrs["level"]?.intValue == 2)
        } else {
            Issue.record("expected heading")
        }
    }

    @Test func boldAndItalicMarks() throws {
        let slice = try #require(parse("<p><strong>bold</strong> and <em>italic</em></p>"))
        guard case .structural(_, let kids) = slice.content.firstChild else {
            Issue.record("expected structural"); return
        }
        // kids: inline("bold", strong), inline(" and "), inline("italic", em)
        #expect(kids.count >= 2)
        var sawStrong = false
        var sawEm = false
        for kid in kids {
            if case .inline(_, let marks) = kid {
                if marks.contains(type: "strong") { sawStrong = true }
                if marks.contains(type: "em") { sawEm = true }
            }
        }
        #expect(sawStrong)
        #expect(sawEm)
    }

    @Test func anchorParsesAsLinkMark() throws {
        let slice = try #require(parse("<p>see <a href=\"https://example.com\">site</a></p>"))
        guard case .structural(_, let kids) = slice.content.firstChild else {
            Issue.record("expected structural"); return
        }
        var sawLink = false
        for kid in kids {
            if case .inline(_, let marks) = kid,
               let link = marks.marks.first(where: { $0.type == "link" }) {
                sawLink = true
                #expect(link.attrs["href"]?.stringValue == "https://example.com")
            }
        }
        #expect(sawLink)
    }

    @Test func bulletListParses() throws {
        let slice = try #require(parse("<ul><li><p>one</p></li><li><p>two</p></li></ul>"))
        guard case .structural(let pn, let kids) = slice.content.firstChild else {
            Issue.record("expected structural"); return
        }
        #expect(pn.type == "bullet_list")
        #expect(kids.count == 2)
    }

    @Test func codeBlockKeepsLanguage() throws {
        let slice = try #require(parse("<pre><code class=\"language-swift\">let x = 1</code></pre>"))
        guard case .structural(let pn, let kids) = slice.content.firstChild else {
            Issue.record("expected structural"); return
        }
        #expect(pn.type == "code_block")
        #expect(pn.attrs["params"]?.stringValue == "swift")
        if case .inline(let text, _) = kids.first {
            #expect(text == "let x = 1")
        }
    }

    @Test func hrParsesAsLeaf() throws {
        let slice = try #require(parse("<hr>"))
        if case .leaf(let pn, _) = slice.content.firstChild {
            #expect(pn.type == "horizontal_rule")
        } else {
            Issue.record("expected hr leaf")
        }
    }

    @Test func brIsHardBreakLeaf() throws {
        let slice = try #require(parse("<p>line<br>break</p>"))
        guard case .structural(_, let kids) = slice.content.firstChild else {
            Issue.record("expected structural"); return
        }
        var sawBr = false
        for kid in kids {
            if case .leaf(let pn, _) = kid, pn.type == "hard_break" { sawBr = true }
        }
        #expect(sawBr)
    }

    @Test func pmSliceMarkerRecoversOpenDepths() throws {
        let html = "<div data-pm-slice=\"1 1 []\">hello</div>"
        let slice = try #require(parse(html))
        #expect(slice.openStart == 1)
        #expect(slice.openEnd == 1)
    }

    @Test func entitiesAreDecoded() throws {
        let slice = try #require(parse("<p>a &amp; b &lt;c&gt;</p>"))
        guard case .structural(_, let kids) = slice.content.firstChild else {
            Issue.record("expected structural"); return
        }
        if case .inline(let text, _) = kids.first {
            #expect(text == "a & b <c>")
        }
    }

    @Test func unknownTagsAreTransparent() throws {
        let slice = try #require(parse("<section><p>inside</p></section>"))
        if case .structural(let pn, _) = slice.content.firstChild {
            #expect(pn.type == "paragraph")
        }
    }

    @Test func multipleParagraphsBecomeClosedSlice() throws {
        let slice = try #require(parse("<p>one</p><p>two</p>"))
        #expect(slice.content.childCount == 2)
        #expect(slice.openStart == 0)
        #expect(slice.openEnd == 0)
    }
}

@Suite(.serialized) struct ClipboardParserTests {

    private func setup(_ md: String = "") throws -> EditorController {
        try EditorController(initialMarkdown: md, theme: .default)
    }

    @Test func plainTextRequestSkipsHtml() throws {
        let controller = try setup("")
        let parser = ClipboardParser()
        let slice = try #require(parser.parseFromClipboard(
            controller: controller,
            text: "plain",
            html: "<p><strong>html</strong></p>",
            plainText: true,
            selection: NSRange(location: 0, length: 0)
        ))
        // Plain branch — compiles markdown source "plain" into an inline slice.
        if case .inline(let text, _) = slice.content.firstChild {
            #expect(text == "plain")
        }
    }

    @Test func inCodeKeepsVerbatim() throws {
        let controller = try setup("```\n\n```")
        var codeProbe: Int = 0
        for i in 0..<controller.textStorage.length {
            if controller.textStorage.blockSpec(at: i)?.isCodeBlock == true {
                codeProbe = i
                break
            }
        }
        let parser = ClipboardParser()
        let slice = try #require(parser.parseFromClipboard(
            controller: controller,
            text: "a\nb",
            html: "<p>a</p><p>b</p>",
            plainText: false,
            selection: NSRange(location: codeProbe, length: 0)
        ))
        // Code-block destination: text-only, closed.
        #expect(slice.openStart == 0)
        #expect(slice.openEnd == 0)
        if case .inline(let text, _) = slice.content.firstChild {
            #expect(text == "a\nb")
        }
    }

    @Test func htmlBranchUsesDOMParser() throws {
        let controller = try setup("")
        let parser = ClipboardParser()
        let slice = try #require(parser.parseFromClipboard(
            controller: controller,
            text: "fallback",
            html: "<h1>Title</h1>",
            plainText: false,
            selection: NSRange(location: 0, length: 0)
        ))
        if case .structural(let pn, _) = slice.content.firstChild {
            #expect(pn.type == "heading")
        }
    }

    @Test func markdownFallbackOnMissingHtml() throws {
        let controller = try setup("")
        let parser = ClipboardParser()
        let slice = try #require(parser.parseFromClipboard(
            controller: controller,
            text: "**bold** text",
            html: nil,
            plainText: false,
            selection: NSRange(location: 0, length: 0)
        ))
        // Compiled markdown: bold + plain run.
        let serialized = MarkdownTreeSerializer().serializeSlice(slice)
        #expect(serialized.contains("**bold**"))
    }

    @Test func dispatchPasteRoutesHtmlThroughSliceBranch() throws {
        let controller = try setup("")
        let event = PasteEvent(
            text: "fallback",
            html: "<h1>Title</h1><p>body</p>",
            selection: NSRange(location: 0, length: 0)
        )
        _ = controller.dispatchPaste(event)
        let md = controller.markdown()
        #expect(md.contains("# Title"))
        #expect(md.contains("body"))
    }

    @Test func clipboardTextParserHookOverridesDefault() throws {
        let controller = try setup("")

        final class StubPlugin: EditorPlugin {
            let key = AnyPluginKey(name: "stub")
            var props: PluginProps {
                PluginProps(clipboardTextParser: { _, _, _, _ in
                    Slice(content: Fragment([.inline(text: "STUB", marks: MarkSet())]),
                          openStart: 1, openEnd: 1)
                })
            }
        }
        controller.register(plugin: StubPlugin())
        let parser = ClipboardParser()
        let slice = try #require(parser.parseFromClipboard(
            controller: controller,
            text: "raw",
            html: nil,
            plainText: false,
            selection: NSRange(location: 0, length: 0)
        ))
        if case .inline(let text, _) = slice.content.firstChild {
            #expect(text == "STUB")
        }
    }

    @Test func transformPastedHTMLRunsBeforeParse() throws {
        let controller = try setup("")

        final class StubPlugin: EditorPlugin {
            let key = AnyPluginKey(name: "stub")
            var props: PluginProps {
                PluginProps(transformPastedHTML: { _, _, _ in "<h2>rewritten</h2>" })
            }
        }
        controller.register(plugin: StubPlugin())
        let parser = ClipboardParser()
        let slice = try #require(parser.parseFromClipboard(
            controller: controller,
            text: "",
            html: "<p>original</p>",
            plainText: false,
            selection: NSRange(location: 0, length: 0)
        ))
        if case .structural(let pn, _) = slice.content.firstChild {
            #expect(pn.type == "heading")
            #expect(pn.attrs["level"]?.intValue == 2)
        }
    }
}
