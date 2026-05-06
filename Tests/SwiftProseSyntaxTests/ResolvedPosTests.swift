import Testing
import Foundation
@testable import SwiftProseSyntax

@Suite("ResolvedPos / NodeRange")
struct ResolvedPosTests {

    private let schema: Schema = .defaultMarkdown

    private func makeDoc(_ kids: [TreeNode]) -> ProseDocument {
        ProseDocument.make(schema: schema, children: kids)
    }

    @Test
    func resolveZeroLandsAtRoot() {
        let doc = makeDoc([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "Hello", marks: MarkSet())
            ])
        ])
        let resolved = doc.resolve(0)!
        #expect(resolved.depth == 1)
        #expect(resolved.parent(at: 0).type == "doc")
        #expect(resolved.parent(at: 1).type == "paragraph")
        #expect(resolved.index(at: 0) == 0)
    }

    @Test
    func resolveWithinParagraphReportsTextOffset() {
        let doc = makeDoc([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "Hello", marks: MarkSet())
            ])
        ])
        // "Hello" is 5 chars; resolving at 3 lands inside the paragraph,
        // 3 chars into the inline run.
        let resolved = doc.resolve(3)!
        #expect(resolved.parent.type == "paragraph")
        #expect(resolved.textOffset == 3)
    }

    @Test
    func marksAtPositionReflectInlineRun() {
        let strongMarks = MarkSet([ProseMark(type: "strong")])
        let doc = makeDoc([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "bold", marks: strongMarks)
            ])
        ])
        let resolved = doc.resolve(2)!
        #expect(resolved.marks().contains(type: "strong"))
    }

    @Test
    func startAndEndAtRootSpanWholeDocument() {
        let doc = makeDoc([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "abc", marks: MarkSet())
            ]),
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "def", marks: MarkSet())
            ])
        ])
        let resolved = doc.resolve(0)!
        #expect(resolved.start(at: 0) == 0)
        // Two paragraphs of length 3 + a separator newline = 7.
        #expect(resolved.end(at: 0) == 3 + 1 + 3)
    }

    @Test
    func nodeRangeEnclosesSamePosition() {
        let doc = makeDoc([
            .structural(ProseNode(type: "paragraph"), [
                .inline(text: "abc", marks: MarkSet())
            ])
        ])
        let resolved = doc.resolve(1)!
        let range = resolved.blockRange()
        #expect(range != nil)
        #expect(range?.parent.type == "paragraph")
    }
}
