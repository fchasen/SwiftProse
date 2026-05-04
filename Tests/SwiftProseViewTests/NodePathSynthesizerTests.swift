import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView

@Suite("Phase 2 NodePath synthesizer")
struct NodePathSynthesizerTests {

    private func compile(_ markdown: String) throws -> NSAttributedString {
        let compiler = try MarkdownAttributedCompiler()
        return compiler.compile(markdown, theme: .default)
    }

    private func probePath(_ storage: NSAttributedString, at index: Int) -> NodePath? {
        storage.nodePath(at: index)
    }

    private func probeMarks(_ storage: NSAttributedString, at index: Int) -> MarkSet? {
        storage.markSet(at: index)
    }

    @Test
    func paragraphCarriesDocAndParagraphAncestors() throws {
        let storage = try compile("Hello world\n")
        let path = probePath(storage, at: 0)
        #expect(path?.depth == 2)
        #expect(path?.root?.type == "doc")
        #expect(path?.leaf?.type == "paragraph")
    }

    @Test
    func headingCarriesLevelAttribute() throws {
        let storage = try compile("## Title\n")
        // The "T" of Title is at offset 0 once the markup is stripped.
        let probe = (storage.string as NSString).range(of: "Title").location
        let path = probePath(storage, at: probe)
        #expect(path?.leaf?.type == "heading")
        #expect(path?.leaf?.attrs["level"] == .int(2))
    }

    @Test
    func blockquoteIntroducesAncestor() throws {
        let storage = try compile("> quoted line\n")
        let probe = (storage.string as NSString).range(of: "quoted").location
        let path = probePath(storage, at: probe)
        #expect(path?.depth == 3)
        #expect(path?.nodes[1].type == "blockquote")
        #expect(path?.leaf?.type == "paragraph")
    }

    @Test
    func nestedBlockquoteIntroducesMultipleAncestors() throws {
        let storage = try compile(">> deeper\n")
        let probe = (storage.string as NSString).range(of: "deeper").location
        let path = probePath(storage, at: probe)
        #expect(path?.depth == 4)
        #expect(path?.nodes[1].type == "blockquote")
        #expect(path?.nodes[2].type == "blockquote")
        #expect(path?.leaf?.type == "paragraph")
    }

    @Test
    func boldRunCarriesStrongMark() throws {
        let storage = try compile("**bold** text\n")
        let probe = (storage.string as NSString).range(of: "bold").location
        let marks = probeMarks(storage, at: probe)
        #expect(marks?.contains(type: "strong") == true)
        let plainProbe = (storage.string as NSString).range(of: "text").location
        let plainMarks = probeMarks(storage, at: plainProbe)
        #expect(plainMarks?.contains(type: "strong") != true)
    }

    @Test
    func italicRunCarriesEmMark() throws {
        let storage = try compile("an *italic* run\n")
        let probe = (storage.string as NSString).range(of: "italic").location
        let marks = probeMarks(storage, at: probe)
        #expect(marks?.contains(type: "em") == true)
    }

    @Test
    func codeSpanCarriesCodeMark() throws {
        let storage = try compile("call `now()` please\n")
        let probe = (storage.string as NSString).range(of: "now()").location
        let marks = probeMarks(storage, at: probe)
        #expect(marks?.contains(type: "code") == true)
    }

    @Test
    func boldItalicCombinesStrongAndEm() throws {
        let storage = try compile("***both*** ok\n")
        let probe = (storage.string as NSString).range(of: "both").location
        let marks = probeMarks(storage, at: probe)
        #expect(marks?.contains(type: "strong") == true)
        #expect(marks?.contains(type: "em") == true)
    }

    @Test
    func tableParagraphsShareOneTableEnvelopeNode() throws {
        let storage = try compile("| a | b |\n| - | - |\n| 1 | 2 |\n")
        let firstRowProbe = (storage.string as NSString).range(of: "a").location
        let bodyRowProbe = (storage.string as NSString).range(of: "1").location
        let p1 = probePath(storage, at: firstRowProbe)!
        let p2 = probePath(storage, at: bodyRowProbe)!
        // Both rows pass through the same table node id.
        let tableId1 = p1.nodes.first(where: { $0.type == "table" })?.id
        let tableId2 = p2.nodes.first(where: { $0.type == "table" })?.id
        #expect(tableId1 != nil)
        #expect(tableId1 == tableId2)
    }

    @Test
    func compileToTreeReturnsEquivalentDocument() throws {
        let compiler = try MarkdownAttributedCompiler()
        let document = compiler.compileToTree("# Hi\n\nworld\n", theme: .default)
        guard case .structural(let docNode, let kids) = document.root else {
            Issue.record("expected structural root")
            return
        }
        #expect(docNode.type == "doc")
        // Two block children: heading, paragraph.
        let leafTypes = kids.compactMap { node -> NodeType.Name? in
            if case .structural(let n, _) = node { return n.type }
            return nil
        }
        #expect(leafTypes == ["heading", "paragraph"])
    }

    @Test
    func codeBlockHasNoMarks() throws {
        let storage = try compile("```\nlet x = 1\n```\n")
        let probe = (storage.string as NSString).range(of: "let").location
        let marks = probeMarks(storage, at: probe)
        // Code block content is literal — no inline marks projected.
        // `setMarkSet` removes the attribute when the set is empty so the
        // probe legitimately reads back nil.
        #expect(marks == nil || marks?.isEmpty == true)
    }
}
