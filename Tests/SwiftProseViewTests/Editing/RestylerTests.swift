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

@Suite("Restyler")
struct RestylerTests {
    let theme = ProseTheme.default
    var restyler: Restyler { Restyler(theme: theme) }

    private func font(_ storage: NSAttributedString, _ index: Int) -> PlatformFont? {
        storage.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont
    }

    private func color(_ storage: NSAttributedString, _ index: Int) -> PlatformColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? PlatformColor
    }

    @Test func headingsUseThemeHeadingFontAndSpacing() {
        let storage = StorageBuilder.build {
            $0.paragraph("Title", MarkdownBlock(leaf: .heading(level: 1)))
            $0.paragraph("body")
        }
        restyler.restyleAll(storage)
        #expect(font(storage, 0) == theme.headingFont(level: 1))
        #expect(font(storage, 6) == theme.bodyFont)
        let style = storage.paragraphStyle(at: 0)
        #expect(style?.paragraphSpacingBefore == 12)
        #expect(style?.paragraphSpacing == Restyler.headingSpacingAfter)
    }

    @Test func marksDeriveFontTraitsStrikeAndCodeBackground() {
        let storage = StorageBuilder.build { $0.paragraph("bold ital both code strike") }
        storage.addIntent(.stronglyEmphasized, NSRange(location: 0, length: 4))
        storage.addIntent(.emphasized, NSRange(location: 5, length: 4))
        storage.addIntent([.stronglyEmphasized, .emphasized], NSRange(location: 10, length: 4))
        storage.addIntent(.code, NSRange(location: 15, length: 4))
        storage.addIntent(.strikethrough, NSRange(location: 20, length: 6))
        restyler.restyleAll(storage)
        #expect(font(storage, 0)?.fontTraits == [.bold])
        #expect(font(storage, 5)?.fontTraits == [.italic])
        #expect(font(storage, 10)?.fontTraits == [.bold, .italic])
        #expect(font(storage, 15)?.isMonospace == true)
        #expect(font(storage, 15)?.pointSize == theme.bodyFont.pointSize)
        #expect(storage.attribute(.backgroundColor, at: 15, effectiveRange: nil) as? PlatformColor == theme.codeBlock.fillColor)
        #expect(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect((storage.attribute(.strikethroughStyle, at: 20, effectiveRange: nil) as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue)
        #expect(storage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
    }

    @Test func removedMarksClearDerivedAttributes() {
        let storage = StorageBuilder.build { $0.paragraph("code") }
        storage.addIntent([.code, .strikethrough], NSRange(location: 0, length: 4))
        restyler.restyleAll(storage)
        storage.removeAttribute(.markdownInlineIntent, range: NSRange(location: 0, length: 4))
        restyler.restyleAll(storage)
        #expect(font(storage, 0) == theme.bodyFont)
        #expect(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(storage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
    }

    @Test func inlineCodeInHeadingKeepsHeadingSize() {
        let storage = StorageBuilder.build { $0.paragraph("Title", MarkdownBlock(leaf: .heading(level: 2))) }
        storage.addIntent(.code, NSRange(location: 0, length: 5))
        restyler.restyleAll(storage)
        #expect(font(storage, 0)?.isMonospace == true)
        #expect(font(storage, 0)?.pointSize == theme.headingFont(level: 2).pointSize)
        #expect(font(storage, 0)?.fontTraits.contains(.bold) == true)
    }

    @Test func linksUseLinkColor() {
        let storage = StorageBuilder.build { $0.paragraph("see docs") }
        storage.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 4, length: 4))
        restyler.restyleAll(storage)
        #expect(color(storage, 4) == theme.linkColor)
        #expect(color(storage, 0) == theme.foregroundColor)
    }

    @Test func codeBlockLinesShareEdgeSpacingAndInset() {
        let group = GroupToken.mint()
        let code = MarkdownBlock(leaf: .code(language: nil, group: group))
        let storage = StorageBuilder.build {
            $0.paragraph("intro")
            $0.paragraph("a", code)
            $0.paragraph("b", code)
            $0.paragraph("c", code)
            $0.paragraph("outro")
        }
        storage.addIntent(.stronglyEmphasized, NSRange(location: 6, length: 1))
        restyler.restyleAll(storage)
        let first = storage.paragraphStyle(at: 6)
        let middle = storage.paragraphStyle(at: 8)
        let last = storage.paragraphStyle(at: 10)
        #expect(first?.paragraphSpacingBefore == Restyler.codeEdgeSpacing)
        #expect(first?.paragraphSpacing == 0)
        #expect(middle?.paragraphSpacingBefore == 0)
        #expect(middle?.paragraphSpacing == 0)
        #expect(last?.paragraphSpacing == Restyler.codeEdgeSpacing)
        #expect(first?.headIndent == Restyler.codeInset)
        #expect(font(storage, 6) == theme.monospaceFont)
    }

    @Test func adjacentCodeGroupsStayDistinct() {
        let storage = StorageBuilder.build {
            $0.paragraph("a", MarkdownBlock(leaf: .code(language: nil, group: GroupToken.mint())))
            $0.paragraph("b", MarkdownBlock(leaf: .code(language: nil, group: GroupToken.mint())))
        }
        restyler.restyleAll(storage)
        #expect(storage.paragraphStyle(at: 0)?.paragraphSpacing == Restyler.codeEdgeSpacing)
        #expect(storage.paragraphStyle(at: 2)?.paragraphSpacingBefore == Restyler.codeEdgeSpacing)
    }

    @Test func containersIndentAndTextListsSurvive() {
        let list = NSTextList(markerFormat: .decimal, options: 0)
        let quote = GroupToken.mint()
        let storage = StorageBuilder.build {
            $0.paragraph("quoted", MarkdownBlock(containers: [.quote(quote)]))
            $0.paragraph("item", MarkdownBlock(containers: [.quote(quote), .listItem]), lists: [list])
            $0.paragraph("cont", MarkdownBlock(containers: [.quote(quote), .listItem], isContinuation: true), lists: [list])
        }
        restyler.restyleAll(storage)
        #expect(storage.paragraphStyle(at: 0)?.headIndent == Restyler.quoteIndent)
        let item = storage.paragraphStyle(at: 7)
        #expect(item?.headIndent == Restyler.quoteIndent + Restyler.listIndent)
        #expect(item?.firstLineHeadIndent == Restyler.quoteIndent + Restyler.listIndent)
        #expect(item?.textLists.first === list)
        #expect(storage.paragraphStyle(at: 12)?.textLists.first === list)
        #expect(storage.paragraphStyle(at: 12)?.headIndent == item?.headIndent)
    }

    @Test func foreignParagraphAttributesAreReplaced() {
        let storage = StorageBuilder.build { $0.paragraph("text") }
        let foreign = NSMutableParagraphStyle()
        foreign.alignment = .center
        foreign.headIndent = 72
        storage.addAttribute(.paragraphStyle, value: foreign, range: NSRange(location: 0, length: 5))
        restyler.restyleAll(storage)
        #expect(storage.paragraphStyle(at: 0)?.alignment == .natural)
        #expect(storage.paragraphStyle(at: 0)?.headIndent == 0)
    }

    @Test func excludedParagraphIsLeftAlone() {
        let storage = StorageBuilder.build {
            $0.paragraph("one")
            $0.paragraph("two")
        }
        restyler.restyle(storage, in: NSRange(location: 0, length: storage.length), excluding: NSRange(location: 5, length: 1))
        #expect(font(storage, 0) == theme.bodyFont)
        #expect(font(storage, 4) == nil)
    }

    @Test func restyleIsIdempotentAndLeavesVocabulary() {
        let storage = StorageBuilder.build { $0.paragraph("bold", MarkdownBlock(leaf: .heading(level: 3))) }
        storage.addIntent(.stronglyEmphasized, NSRange(location: 0, length: 4))
        storage.addAttribute(.markdownLiteral, value: "\\*", range: NSRange(location: 0, length: 1))
        restyler.restyleAll(storage)
        let once = NSAttributedString(attributedString: storage)
        restyler.restyleAll(storage)
        #expect(storage.isEqual(to: once))
        #expect(storage.markdownLiteral(at: 0) == "\\*")
        #expect(storage.markdownBlock(at: 0)?.headingLevel == 3)
    }

    @Test func typingAttributesCarryVocabularyAndDerivedStyle() {
        let block = MarkdownBlock(leaf: .heading(level: 2))
        let attributes = restyler.typingAttributes(for: block, intent: [.emphasized, .code], paragraphStyle: nil)
        #expect(attributes.markdownBlock == block)
        #expect(attributes.markdownInlineIntent == [.emphasized, .code])
        #expect((attributes[.font] as? PlatformFont)?.isMonospace == true)
        #expect(attributes[.backgroundColor] as? PlatformColor == theme.codeBlock.fillColor)
        #expect((attributes[.paragraphStyle] as? NSParagraphStyle)?.paragraphSpacing == Restyler.headingSpacingAfter)

        let code = MarkdownBlock(leaf: .code(language: nil, group: GroupToken.mint()))
        let codeAttributes = restyler.typingAttributes(for: code, intent: .stronglyEmphasized, paragraphStyle: nil)
        #expect(codeAttributes.markdownInlineIntent.isEmpty)
        #expect(codeAttributes[.font] as? PlatformFont == theme.monospaceFont)
    }

    @Test func restylesFiftyKilobytesQuickly() {
        let storage = NSMutableAttributedString()
        var builder = StorageBuilder()
        for index in 0..<1000 {
            builder.paragraph("Paragraph \(index) with **some** text that is long enough.")
        }
        storage.append(builder.result)
        storage.addIntent(.stronglyEmphasized, NSRange(location: 0, length: storage.length / 2))
        let clock = ContinuousClock()
        let elapsed = clock.measure { restyler.restyleAll(storage) }
        #expect(storage.length > 50_000)
        #expect(elapsed < .milliseconds(500))
    }
}
