import Foundation
import Testing
@testable import SwiftProseSyntax
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Vocabulary")
struct VocabularyTests {
    @Test func blocksCompareByValue() {
        let group = GroupToken.mint()
        let a = MarkdownBlock(leaf: .code(language: "swift", group: group), containers: [.listItem])
        let b = MarkdownBlock(leaf: .code(language: "swift", group: group), containers: [.listItem])
        #expect(a == b)
        #expect(a.hash == b.hash)
        #expect(a != a.with(leaf: .code(language: "swift", group: GroupToken.mint())))
    }

    @Test func mintedTokensAreDistinct() {
        #expect(GroupToken.mint() != GroupToken.mint())
    }

    @Test func equalBlocksCoalesceIntoOneAttributeRun() {
        let storage = NSMutableAttributedString(string: "one\ntwo\n")
        let block = MarkdownBlock(leaf: .heading(level: 2))
        storage.addAttribute(.markdownBlock, value: block, range: NSRange(location: 0, length: 4))
        storage.addAttribute(.markdownBlock, value: MarkdownBlock(leaf: .heading(level: 2)), range: NSRange(location: 4, length: 4))
        var effective = NSRange()
        _ = storage.attribute(.markdownBlock, at: 0, effectiveRange: &effective)
        #expect(effective == NSRange(location: 0, length: 8))
        #expect(storage.markdownBlock(at: 5)?.headingLevel == 2)
    }

    @Test func inlineIntentRoundTripsThroughFoundationKey() {
        let storage = NSMutableAttributedString(string: "a\u{2028}b")
        let intent: MarkdownInlineIntent = [.stronglyEmphasized, .code]
        storage.addAttribute(.markdownInlineIntent, value: intent.attributeValue, range: NSRange(location: 0, length: 1))
        storage.addAttribute(.markdownInlineIntent, value: MarkdownInlineIntent.softBreak.attributeValue, range: NSRange(location: 1, length: 1))
        #expect(storage.markdownInlineIntent(at: 0) == intent)
        #expect(storage.isMarkdownCode(at: 0))
        #expect(storage.isMarkdownSoftBreak(at: 1))
        #expect(!storage.isMarkdownHardBreak(at: 1))
        #expect(EditorDocument.InlineMarks(intent: intent) == [.strong, .code])
    }

    @Test func paragraphRangesIncludeTrailingEmptyParagraph() {
        let storage = NSAttributedString(string: "a\nbc\n")
        #expect(storage.markdownParagraphRanges() == [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 3),
            NSRange(location: 5, length: 0)
        ])
        #expect(NSAttributedString(string: "").markdownParagraphRanges() == [NSRange(location: 0, length: 0)])
        #expect(storage.markdownParagraphRanges(in: NSRange(location: 3, length: 0)) == [NSRange(location: 2, length: 3)])
    }

    @Test func plainParagraphsRoundTripThroughStubPipeline() {
        let source = "first\n\nsecond"
        let loaded = MarkdownLoader().load(source)
        #expect(MarkdownWriter().write(StorageReader().document(from: loaded)) == source)
    }

    @Test func orderedMarkerMatchesTextKit() {
        let formats: [NSTextList.MarkerFormat] = [
            .disc, .circle, .square, .hyphen, .box, .check, .diamond,
            .decimal, .octal, .lowercaseHexadecimal, .uppercaseHexadecimal, .lowercaseAlpha, .uppercaseAlpha,
            .lowercaseLatin, .uppercaseLatin, .lowercaseRoman, .uppercaseRoman,
            NSTextList.MarkerFormat(rawValue: "({decimal})"), NSTextList.MarkerFormat(rawValue: "")
        ]
        for format in formats {
            let list = NSTextList(markerFormat: format, options: 0)
            #expect(list.hasOrderedMarker == list.isOrdered, "\(format.rawValue)")
        }
    }
}
