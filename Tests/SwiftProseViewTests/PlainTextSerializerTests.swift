import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

/// The pasteboard's plain-text form is what the editor shows — never
/// markdown.
@Suite(.serialized) struct PlainTextSerializerTests {

    private func plainText(of markdown: String, range: NSRange? = nil) throws -> String {
        let controller = try EditorController(initialMarkdown: markdown, theme: .default)
        let full = NSRange(location: 0, length: controller.textStorage.length)
        let slice = controller.sliceForRange(range ?? full)
        return PlainTextSerializer().serialize(slice.content)
    }

    @Test func marksAreDroppedNotSpelled() throws {
        let text = try plainText(of: "some **bold** and *em* and `code` and [link](https://x.y) and ~~gone~~")
        #expect(text == "some bold and em and code and link and gone")
    }

    @Test func headingIsItsText() throws {
        #expect(try plainText(of: "# Title\n\nbody") == "Title\nbody")
        #expect(try plainText(of: "### Deep") == "Deep")
    }

    @Test func bulletItemsKeepTheirGlyphAndNestByTab() throws {
        let text = try plainText(of: "- one\n  - nested\n- two")
        #expect(text == "• one\n\t◦ nested\n• two")
    }

    @Test func orderedItemsKeepTheirNumbers() throws {
        #expect(try plainText(of: "1. a\n2. b\n3. c") == "1. a\n2. b\n3. c")
    }

    @Test func orderedListStartCarriesIntoTheMarkers() {
        let frag = Fragment([
            .structural(ProseNode(type: "ordered_list", attrs: ["order": .int(4)]), [
                .structural(ProseNode(type: "list_item"), [
                    .structural(ProseNode(type: "paragraph"), [.inline(text: "a", marks: MarkSet())])
                ]),
                .structural(ProseNode(type: "list_item"), [
                    .structural(ProseNode(type: "paragraph"), [.inline(text: "b", marks: MarkSet())])
                ])
            ])
        ])
        #expect(PlainTextSerializer().serialize(frag) == "4. a\n5. b")
    }

    @Test func taskItemsShowCheckboxes() throws {
        #expect(try plainText(of: "- [ ] todo\n- [x] done") == "☐ todo\n☑ done")
    }

    @Test func blockquoteIsJustItsText() throws {
        #expect(try plainText(of: "> quoted\n> more") == "quoted\nmore")
        #expect(try plainText(of: "> quoted\n\nafter") == "quoted\nafter")
    }

    @Test func codeBlockIsRawWithoutFences() throws {
        let text = try plainText(of: "```swift\nlet x = 1\nlet y = 2\n```\n\nafter")
        #expect(text == "let x = 1\nlet y = 2\nafter")
    }

    @Test func horizontalRuleIsABlankLine() throws {
        #expect(try plainText(of: "a\n\n---\n\nb") == "a\n\nb")
    }

    @Test func tableIsTabSeparatedRows() throws {
        let text = try plainText(of: "| h1 | h2 |\n|---|---|\n| a | b |\n| c | d |")
        #expect(text == "h1\th2\na\tb\nc\td")
    }

    @Test func imageIsItsAltText() throws {
        #expect(try plainText(of: "see ![the alt](https://x.y/i.png) here") == "see the alt here")
    }

    @Test func partialInlineSelectionIsJustThatText() throws {
        let text = try plainText(of: "alpha **beta** gamma", range: NSRange(location: 6, length: 4))
        #expect(text == "beta")
    }

    @Test func hardBreakIsANewline() {
        let frag = Fragment([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "a", marks: MarkSet()),
                .leaf(ProseNode(type: "hard_break")),
                .inline(text: "b", marks: MarkSet())
            ])
        ])
        #expect(PlainTextSerializer().serialize(frag) == "a\nb")
    }

    @Test func nestedOrderedUnderBulletUsesLevelStyle() {
        let frag = Fragment([
            .structural(ProseNode(type: "bullet_list"), [
                .structural(ProseNode(type: "list_item"), [
                    .structural(ProseNode(type: "paragraph"), [.inline(text: "top", marks: MarkSet())]),
                    .structural(ProseNode(type: "ordered_list"), [
                        .structural(ProseNode(type: "list_item"), [
                            .structural(ProseNode(type: "paragraph"), [.inline(text: "first", marks: MarkSet())])
                        ]),
                        .structural(ProseNode(type: "list_item"), [
                            .structural(ProseNode(type: "paragraph"), [.inline(text: "second", marks: MarkSet())])
                        ])
                    ])
                ])
            ])
        ])
        #expect(PlainTextSerializer().serialize(frag) == "• top\n\ta. first\n\tb. second")
    }

    @Test func copyBundleTextHasNoMarkdown() throws {
        let controller = try EditorController(
            initialMarkdown: "# Title\n\nsome **bold** text\n\n- item",
            theme: .default
        )
        let slice = controller.sliceForRange(NSRange(location: 0, length: controller.textStorage.length))
        let bundle = ClipboardSerializer().serializeForClipboard(controller: controller, slice: slice)
        #expect(bundle.text == "Title\nsome bold text\n• item")
        #expect(!bundle.text.contains("#"))
        #expect(!bundle.text.contains("*"))
        #expect(ClipboardSerializer().renderMarkdown(slice).contains("**bold**"))
    }
}
