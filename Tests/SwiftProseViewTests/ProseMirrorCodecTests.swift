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

    private func compileTree(_ markdown: String) throws -> ProseDocument {
        let compiler = try MarkdownAttributedCompiler()
        return compiler.compileToTree(markdown, theme: .default)
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

    // MARK: - tree-direct encode (Phase 7)

    @Test func encodeFromTreeWrapsInDoc() throws {
        let document = try compileTree("hello\n")
        let pm = ProseMirrorCodec().encode(document: document)
        #expect(pm.type == "doc")
        #expect(pm.content?.first?.type == "paragraph")
    }

    @Test func encodeFromTreePreservesHeadingLevel() throws {
        let document = try compileTree("## Title\n")
        let pm = ProseMirrorCodec().encode(document: document)
        let heading = pm.content?.first
        #expect(heading?.type == "heading")
        #expect(heading?.attrs?["level"]?.intValue == 2)
    }

    @Test func encodeFromTreePropagatesMarksOnText() throws {
        let document = try compileTree("**bold** rest\n")
        let pm = ProseMirrorCodec().encode(document: document)
        let paragraph = pm.content?.first
        let firstText = paragraph?.content?.first
        #expect(firstText?.type == "text")
        #expect(firstText?.marks?.contains(where: { $0.type == "strong" }) == true)
    }

    @Test func encodeFromTreeBuildsListStructure() throws {
        let document = try compileTree("- one\n- two\n")
        let pm = ProseMirrorCodec().encode(document: document)
        let list = pm.content?.first
        #expect(list?.type == "bullet_list")
        #expect(list?.content?.count == 2)
        #expect(list?.content?.first?.type == "list_item")
    }

    @Test func encodeFromTreeEmitsCodeBlockLanguage() throws {
        let document = try compileTree("```swift\nlet x = 1\n```\n")
        let pm = ProseMirrorCodec().encode(document: document)
        let code = pm.content?.first
        #expect(code?.type == "code_block")
        #expect(code?.attrs?["params"]?.stringValue == "swift")
    }

    @Test func encodeImageEmitsAttrsNotLiteralText() throws {
        let document = try compileTree("![alt text](pic.png \"a title\")\n")
        let pm = ProseMirrorCodec().encode(document: document)
        let paragraph = pm.content?.first
        let image = paragraph?.content?.first
        #expect(image?.type == "image")
        #expect(image?.attrs?["src"]?.stringValue == "pic.png")
        #expect(image?.attrs?["alt"]?.stringValue == "alt text")
        #expect(image?.attrs?["title"]?.stringValue == "a title")
    }

    // MARK: - tables (structural)

    @Test func encodeTableEmitsStructuralRowsAndCells() throws {
        let document = try compileTree("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        let pm = ProseMirrorCodec().encode(document: document)
        let table = pm.content?.first
        #expect(table?.type == "table")
        #expect(table?.content?.count == 2)
        let firstRow = table?.content?.first
        #expect(firstRow?.type == "table_row")
        let headerCells = firstRow?.content
        #expect(headerCells?.count == 2)
        #expect(headerCells?.first?.type == "table_header")
        let bodyRow = table?.content?[1]
        #expect(bodyRow?.content?.first?.type == "table_cell")
    }

    @Test func encodeTableCellAlignmentAttrSurvives() throws {
        let document = try compileTree("| h |\n| ---: |\n| a |\n")
        let pm = ProseMirrorCodec().encode(document: document)
        let cell = pm.content?.first?.content?.first?.content?.first
        #expect(cell?.attrs?["align"]?.stringValue == "right")
    }

    @Test func encodeTableCellInlineMarksSurvive() throws {
        let document = try compileTree("| **bold** |\n| --- |\n| a |\n")
        let pm = ProseMirrorCodec().encode(document: document)
        let header = pm.content?.first?.content?.first?.content?.first
        let para = header?.content?.first
        let textNode = para?.content?.first(where: { $0.type == "text" })
        #expect(textNode?.marks?.contains(where: { $0.type == "strong" }) == true)
    }

    @Test func decodeStructuralTableProducesCellPaths() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"table","content":[
            {"type":"table_row","content":[
              {"type":"table_header","attrs":{"align":"left"},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"H"}]}
              ]}
            ]},
            {"type":"table_row","content":[
              {"type":"table_cell","attrs":{"align":"left"},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"a"}]}
              ]}
            ]}
          ]}
        ]}
        """
        let attributed = try decoded(json)
        var hasTableHeaderCell = false
        var hasTableBodyCell = false
        attributed.enumerateNodePaths { _, path in
            let names = path.nodes.map(\.type)
            if names.contains("table_header") { hasTableHeaderCell = true }
            if names.contains("table_cell") { hasTableBodyCell = true }
        }
        #expect(hasTableHeaderCell)
        #expect(hasTableBodyCell)
    }

    @Test func tableJSONRoundTripIsStructural() throws {
        let document = try compileTree("| h1 | h2 |\n| :--- | ---: |\n| **a** | b |\n")
        let codec = ProseMirrorCodec()
        let pm = codec.encode(document: document)
        let data = try JSONEncoder().encode(pm)
        let json = String(data: data, encoding: .utf8) ?? ""
        let attributed = try codec.decode(json)
        let pm2 = codec.encode(attributed)
        let table = pm2.content?.first
        #expect(table?.type == "table")
        let header = table?.content?.first?.content?.first
        #expect(header?.type == "table_header")
        #expect(header?.attrs?["align"]?.stringValue == "left")
        let body = table?.content?[1].content?.first
        #expect(body?.type == "table_cell")
    }

    @Test func decodeImageRoundTripsThroughEncode() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[
            {"type":"image","attrs":{"src":"pic.png","alt":"alt","title":null}}
          ]}
        ]}
        """
        let attributed = try decoded(json)
        let pm = ProseMirrorCodec().encode(attributed)
        let image = pm.content?.first?.content?.first
        #expect(image?.type == "image")
        #expect(image?.attrs?["src"]?.stringValue == "pic.png")
        #expect(image?.attrs?["alt"]?.stringValue == "alt")
    }

}
