import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct ProseMirrorCodecTests {

    private func decoded(_ json: String) throws -> NSAttributedString {
        try ProseMirrorCodec().decode(json)
    }

    private func encoded(_ attributed: NSAttributedString) -> PMNode {
        ProseMirrorCodec().encode(attributed)
    }

    @Test func decodeSimpleParagraph() throws {
        let json = """
        {"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"hello"}]}]}
        """
        let attributed = try decoded(json)
        #expect(attributed.string.hasPrefix("hello"))
        let spec = attributed.blockSpec(at: 0)
        #expect(spec?.kind == BlockSpec.Kind.paragraph)
    }

    @Test func decodeHeadingPreservesLevel() throws {
        let json = """
        {"type":"doc","content":[{"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"hi"}]}]}
        """
        let attributed = try decoded(json)
        let spec = attributed.blockSpec(at: 0)
        if case .heading(let level) = spec?.kind {
            #expect(level == 3)
        } else {
            Issue.record("expected heading spec, got \(String(describing: spec?.kind))")
        }
    }

    @Test func decodeNestedBlockquote() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"blockquote","content":[
            {"type":"blockquote","content":[
              {"type":"paragraph","content":[{"type":"text","text":"deep"}]}
            ]}
          ]}
        ]}
        """
        let attributed = try decoded(json)
        let spec = attributed.blockSpec(at: 0)
        #expect(spec?.blockquoteDepth == 2)
    }

    @Test func decodeBulletAndOrderedLists() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"bullet_list","content":[
            {"type":"list_item","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]}]}
          ]},
          {"type":"ordered_list","attrs":{"order":3},"content":[
            {"type":"list_item","content":[{"type":"paragraph","content":[{"type":"text","text":"b"}]}]}
          ]}
        ]}
        """
        let attributed = try decoded(json)
        let cursorBullet = attributed.string.firstIndex(of: "a").flatMap { attributed.string.utf16.distance(from: attributed.string.utf16.startIndex, to: $0.samePosition(in: attributed.string.utf16)!) } ?? 0
        if case .unorderedListItem = attributed.blockSpec(at: cursorBullet)?.kind {} else {
            Issue.record("expected unordered list item")
        }
        let cursorOrdered = attributed.string.firstIndex(of: "b").flatMap { attributed.string.utf16.distance(from: attributed.string.utf16.startIndex, to: $0.samePosition(in: attributed.string.utf16)!) } ?? 0
        if case .orderedListItem(let idx) = attributed.blockSpec(at: cursorOrdered)?.kind {
            #expect(idx == 3)
        } else {
            Issue.record("expected ordered list item with index 3")
        }
    }

    @Test func decodeCodeBlockUsesParams() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"code_block","attrs":{"params":"swift"},"content":[{"type":"text","text":"let x = 1"}]}
        ]}
        """
        let attributed = try decoded(json)
        if case .fencedCode(let lang) = attributed.blockSpec(at: 0)?.kind {
            #expect(lang == "swift")
        } else {
            Issue.record("expected fenced code spec")
        }
    }

    @Test func decodeMarksProduceFontTraits() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[
            {"type":"text","text":"bold","marks":[{"type":"strong"}]}
          ]}
        ]}
        """
        let attributed = try decoded(json)
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.hasBoldTrait == true)
    }

    @Test func encodeProducesDocWithExpectedStructure() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":1},"content":[{"type":"text","text":"Title"}]},
          {"type":"paragraph","content":[{"type":"text","text":"Body"}]}
        ]}
        """
        let attributed = try decoded(json)
        let pm = encoded(attributed)
        #expect(pm.type == "doc")
        #expect(pm.content?.count == 2)
        #expect(pm.content?.first?.type == "heading")
        #expect(pm.content?[1].type == "paragraph")
    }

    @Test func taskItemEncodesAsBulletWithBracketPrefix() throws {
        let compiler = try MarkdownAttributedCompiler()
        let attributed = compiler.compile("- [x] done\n- [ ] todo\n", theme: .default)
        let pm = ProseMirrorCodec().encode(attributed)
        #expect(pm.content?.first?.type == "bullet_list")
        let firstItemFirstText = pm.content?.first?.content?.first?.content?.first?.content?.first?.text
        #expect(firstItemFirstText?.hasPrefix("[x] ") == true)
    }

    @Test func unknownNodeFallsBackToParagraph() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"unknown_widget","content":[{"type":"text","text":"hello"}]}
        ]}
        """
        let attributed = try decoded(json)
        #expect(attributed.string.contains("hello"))
        #expect(attributed.blockSpec(at: 0)?.kind == BlockSpec.Kind.paragraph)
    }

    @Test func roundTripPreservesHeadingAndParagraph() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Title"}]},
          {"type":"paragraph","content":[{"type":"text","text":"Body"}]}
        ]}
        """
        let attributed = try decoded(json)
        let pm = encoded(attributed)
        let reEncoded = try JSONEncoder().encode(pm)
        let reDecoded = try JSONDecoder().decode(PMNode.self, from: reEncoded)
        #expect(reDecoded.content?.first?.type == "heading")
        #expect(reDecoded.content?.first?.attrs?["level"]?.intValue == 2)
        #expect(reDecoded.content?[1].type == "paragraph")
    }
}
