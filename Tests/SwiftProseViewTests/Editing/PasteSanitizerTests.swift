import Foundation
import Testing
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("PasteSanitizer", .serialized)
struct PasteSanitizerTests {
    let sanitizer = PasteSanitizer()

    private func body(_ size: CGFloat = 12) -> PlatformFont { PlatformFont.systemFont(ofSize: size) }
    private func bold(_ size: CGFloat = 12) -> PlatformFont { PlatformFont.boldSystemFont(ofSize: size) }
    private func mono(_ size: CGFloat = 12) -> PlatformFont { PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular) }

    @Test func plainLineEndingsAreNormalized() {
        #expect(PasteSanitizer.normalizeLineEndings("a\r\nb\rc\u{2029}d\u{0085}e\u{000B}f") == "a\nb\nc\nd\ne\u{2028}f")
        #expect(PasteSanitizer.normalizeLineEndings("plain\ntext") == "plain\ntext")
    }

    @Test func richLineEndingsAreNormalized() {
        let input = NSAttributedString(string: "one\r\ntwo\u{2029}three\r", attributes: [.font: body()])
        let output = sanitizer.sanitize(input)
        #expect(output.string == "one\ntwo\nthree\n")
        #expect(output.blocks() == [.paragraph, .paragraph, .paragraph])
    }

    @Test func foreignAttributesAreDropped() {
        let input = NSAttributedString(string: "text", attributes: [
            .font: PlatformFont(name: "Times-Roman", size: 12) ?? body(),
            .foregroundColor: PlatformColor.red,
            .backgroundColor: PlatformColor.yellow,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .kern: 2
        ])
        let output = sanitizer.sanitize(input)
        let attributes = output.attributes(at: 0, effectiveRange: nil)
        #expect(Set(attributes.keys) == [.markdownBlock])
    }

    @Test func fontTraitsBecomeMarks() {
        let input = NSMutableAttributedString()
        input.append(NSAttributedString(string: "b", attributes: [.font: bold()]))
        input.append(NSAttributedString(string: "i", attributes: [.font: body().withFontTraits(.italic)]))
        input.append(NSAttributedString(string: "c", attributes: [.font: mono()]))
        input.append(NSAttributedString(string: "s", attributes: [.font: body(), .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        input.append(NSAttributedString(string: "l", attributes: [.font: body(), .link: URL(string: "https://example.com")!]))
        input.append(NSAttributedString(string: " plain", attributes: [.font: body()]))
        let output = sanitizer.sanitize(input)
        #expect(output.markdownInlineIntent(at: 0) == .stronglyEmphasized)
        #expect(output.markdownInlineIntent(at: 1) == .emphasized)
        #expect(output.markdownInlineIntent(at: 2) == .code)
        #expect(output.markdownInlineIntent(at: 3) == .strikethrough)
        #expect(output.markdownLink(at: 4) == "https://example.com")
        #expect(output.markdownInlineIntent(at: 6).isEmpty)
    }

    @Test func foreignInlinePresentationIntentBecomesMarks() {
        let input = NSAttributedString(string: "x", attributes: [
            .inlinePresentationIntent: NSNumber(value: InlinePresentationIntent([.emphasized, .strikethrough]).rawValue)
        ])
        let output = sanitizer.sanitize(input)
        #expect(output.markdownInlineIntent(at: 0) == [.emphasized, .strikethrough])
    }

    @Test func listMarkerTextIsStrippedAndListsBecomeContainers() {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        let input = NSMutableAttributedString(string: "Intro\n", attributes: [.font: body()])
        input.append(NSAttributedString(string: "\t•\tone\n\t•\ttwo\n", attributes: [.font: body(), .paragraphStyle: style]))
        let output = sanitizer.sanitize(input)
        #expect(output.string == "Intro\none\ntwo\n")
        #expect(output.blocks() == [.paragraph, MarkdownBlock(containers: [.listItem]), MarkdownBlock(containers: [.listItem])])
        #expect(output.paragraphStyle(at: 6)?.textLists.first === list)
        #expect(output.paragraphStyle(at: 0) == nil)
    }

    @Test func orderedMarkerTextIsStripped() {
        let list = NSTextList(markerFormat: .decimal, options: 0)
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        let input = NSAttributedString(string: "\t1.\tfirst\n\t10.\ttenth\n", attributes: [.font: body(), .paragraphStyle: style])
        #expect(sanitizer.sanitize(input).string == "first\ntenth\n")
    }

    @Test func bulletMarkerWithoutListCreatesOneList() {
        let input = NSAttributedString(string: "\t•\ta\n\t•\tb\nc\n", attributes: [.font: body()])
        let output = sanitizer.sanitize(input)
        #expect(output.string == "a\nb\nc\n")
        let first = output.paragraphStyle(at: 0)?.textLists.first
        #expect(first != nil)
        #expect(output.paragraphStyle(at: 2)?.textLists.first === first)
        #expect(output.markdownBlock(at: 4) == .paragraph)
    }

    @Test func tabbedTextWithoutListIsKept() {
        let input = NSAttributedString(string: "\tcol\tvalue\n", attributes: [.font: body()])
        #expect(sanitizer.sanitize(input).string == "\tcol\tvalue\n")
    }

    @Test func monospacedParagraphsBecomeOneCodeGroup() {
        let input = NSMutableAttributedString(string: "Intro\n", attributes: [.font: body()])
        input.append(NSAttributedString(string: "let a = 1\nlet b = 2\n", attributes: [.font: mono()]))
        input.append(NSAttributedString(string: "outro\n", attributes: [.font: body()]))
        let output = sanitizer.sanitize(input)
        let blocks = output.blocks()
        #expect(blocks[1]?.isCode == true)
        #expect(blocks[1]?.codeGroup == blocks[2]?.codeGroup)
        #expect(blocks[3] == .paragraph)
        #expect(output.markdownInlineIntent(at: 6).isEmpty)
    }

    @Test func blankLinesInsideMonospacedRunStayInCodeGroup() {
        let input = NSMutableAttributedString(string: "Intro\n", attributes: [.font: body()])
        input.append(NSAttributedString(string: "a\n\n  \nb\n\n", attributes: [.font: mono()]))
        input.append(NSAttributedString(string: "outro\n", attributes: [.font: body()]))
        let blocks = sanitizer.sanitize(input).blocks()
        #expect(blocks.count == 7)
        #expect(blocks[0] == .paragraph)
        for index in 1...4 {
            #expect(blocks[index]?.codeGroup == blocks[1]?.codeGroup)
            #expect(blocks[index]?.isCode == true)
        }
        #expect(blocks[5] == .paragraph)
        #expect(blocks[6] == .paragraph)
    }

    @Test func largeBoldParagraphsBecomeHeadings() {
        let input = NSMutableAttributedString(string: "Title\n", attributes: [.font: bold(24)])
        input.append(NSAttributedString(string: "Section\n", attributes: [.font: bold(18)]))
        input.append(NSAttributedString(string: "Body text that is long enough to dominate.\n", attributes: [.font: body(12)]))
        input.append(NSAttributedString(string: "Bold line\n", attributes: [.font: bold(12)]))
        let output = sanitizer.sanitize(input)
        let blocks = output.blocks()
        #expect(blocks[0]?.headingLevel == 1)
        #expect(blocks[1]?.headingLevel == 2)
        #expect(blocks[2] == .paragraph)
        #expect(blocks[3] == .paragraph)
        #expect(output.markdownInlineIntent(at: 0).isEmpty)
        let boldLine = (output.string as NSString).range(of: "Bold line").location
        #expect(output.markdownInlineIntent(at: boldLine) == .stronglyEmphasized)
    }

    @Test func presentationIntentHeadingsAndCodeAreHonoured() {
        var heading = AttributedString("Head\n")
        heading.presentationIntent = PresentationIntent(.header(level: 2), identity: 1)
        var code = AttributedString("let x\n")
        code.presentationIntent = PresentationIntent(.codeBlock(languageHint: "swift"), identity: 2)
        heading.append(code)
        let output = sanitizer.sanitize(NSAttributedString(heading))
        #expect(output.markdownBlock(at: 0)?.headingLevel == 2)
        #expect(output.markdownBlock(at: 5)?.codeLanguage == "swift")
    }

    @Test func foreignAttachmentsAreRemovedAndSourceAttachmentsKept() {
        let input = NSMutableAttributedString(string: "a", attributes: [.font: body()])
        input.append(NSAttributedString(attachment: NSTextAttachment(data: nil, ofType: nil)))
        input.append(NSAttributedString(attachment: HorizontalRuleAttachment(color: .gray)))
        input.append(NSAttributedString(string: "b", attributes: [.font: body()]))
        let output = sanitizer.sanitize(input)
        #expect(output.string == "a\u{FFFC}b")
        #expect(output.proseSourceAttachment(at: 1) is HorizontalRuleAttachment)
    }

    @Test func captureMapsForeignIntentAndStripsTextBlocks() {
        let storage = NSMutableAttributedString(string: "xy", attributes: [
            .inlinePresentationIntent: NSNumber(value: InlinePresentationIntent.stronglyEmphasized.rawValue)
        ])
        #if canImport(AppKit) && os(macOS)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [NSTextTableBlock(table: NSTextTable(), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)]
        storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: 2))
        #endif
        PasteSanitizer.captureForeignAttributes(in: storage, range: NSRange(location: 0, length: 2))
        if Marks.keyIsCustom {
            #expect(storage.attribute(.inlinePresentationIntent, at: 0, effectiveRange: nil) == nil)
            #expect(storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
        }
        #if canImport(AppKit) && os(macOS)
        #expect(storage.paragraphStyle(at: 0)?.textBlocks.isEmpty == true)
        #endif
    }
}

#if canImport(AppKit) && os(macOS)
@Suite("PasteSanitizer HTML (macOS, .serialized)")
@MainActor
struct PasteSanitizerHTMLTests {
    private func importHTML(_ html: String) throws -> NSAttributedString {
        let data = Data(html.utf8)
        return try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }

    @Test func htmlListPasteLosesMarkerTextAndKeepsMarks() throws {
        let imported = try importHTML("<p>Hello <b>bold</b> <i>it</i></p><ul><li>one</li><li>two</li></ul><pre>code</pre>")
        #expect(imported.string.contains("\t•\t"))
        let output = PasteSanitizer().sanitize(imported)
        #expect(!output.string.contains("\t"))
        #expect(output.string.hasPrefix("Hello bold it\none\ntwo\ncode"))
        let boldIndex = (output.string as NSString).range(of: "bold").location
        let italicIndex = (output.string as NSString).range(of: "it\n").location
        #expect(output.markdownInlineIntent(at: boldIndex) == .stronglyEmphasized)
        #expect(output.markdownInlineIntent(at: italicIndex) == .emphasized)
        let oneIndex = (output.string as NSString).range(of: "one").location
        #expect(output.markdownBlock(at: oneIndex)?.isListItem == true)
        let codeIndex = (output.string as NSString).range(of: "code").location
        #expect(output.markdownBlock(at: codeIndex)?.isCode == true)
    }

    @Test func htmlPreWithBlankLineIsOneCodeBlock() throws {
        let imported = try importHTML("<pre><code>a\n\nb\n    c</code></pre>")
        let harness = EditorHarness(markdown: "")
        #expect(harness.controller.paste(PastePayload(richText: imported), replacing: harness.selection))
        #expect(harness.markdown == "```\na\n\nb\n    c\n```")
    }

    @Test func htmlTablePasteKeepsTextKit2() throws {
        let imported = try importHTML("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table><p>after</p>")
        var hadBlocks = false
        imported.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: imported.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { hadBlocks = true }
        }
        #expect(hadBlocks)
        let output = PasteSanitizer().sanitize(imported)
        var leftover = false
        output.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: output.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { leftover = true }
        }
        #expect(!leftover)
        for cell in ["a", "b", "c", "d", "after"] {
            #expect(output.string.contains(cell))
        }

        let harness = EditorHarness(markdown: "", pipeline: .normalizer)
        harness.load(StorageBuilder.build { $0.paragraph("start", separator: false) })
        harness.select(5)
        harness.step {
            if harness.textView.shouldChangeText(in: NSRange(location: 5, length: 0), replacementString: output.string) {
                harness.storage.insert(output, at: 5)
                harness.textView.didChangeText()
            }
        }
        #expect(harness.isTextKit2)
    }
}
#endif
