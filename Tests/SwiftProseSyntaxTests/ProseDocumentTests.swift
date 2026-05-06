import Testing
import Foundation
@testable import SwiftProseSyntax

@Suite("ProseDocument tree types and projection")
struct ProseDocumentTests {

    private let schema: Schema = .defaultMarkdown

    // MARK: - Schema sanity

    @Test
    func defaultSchemaRegistersTopAndCommonNodes() {
        #expect(schema.topNodeName == "doc")
        #expect(schema.nodeType("paragraph") != nil)
        #expect(schema.nodeType("heading") != nil)
        #expect(schema.nodeType("table_cell") != nil)
        #expect(schema.markType("strong") != nil)
        #expect(schema.markType("link")?.attrs.contains { $0.name == "href" } == true)
    }

    @Test
    func paragraphAllowsInlineChildren() {
        let para = schema.nodeType("paragraph")!
        #expect(para.content?.allows(child: "text") == true)
        #expect(para.content?.allows(child: "table_cell") == false)
    }

    @Test
    func codeBlockDoesNotAllowMarks() {
        #expect(schema.nodeType("code_block")?.allowedMarks == AllowedMarks.none)
        #expect(schema.nodeType("html_block")?.allowedMarks == AllowedMarks.none)
        #expect(schema.nodeType("paragraph")?.allowedMarks == AllowedMarks.all)
    }

    @Test
    func codeMarkExcludesAllOtherMarks() {
        // PM convention `excludes: "_"` — the code mark is exclusive with
        // every other mark, so adding `code` to a span that already has
        // strong/em/link drops those marks.
        let code = schema.markType("code")!
        #expect(code.excludesAll)
        #expect(code.excludes("strong"))
        #expect(code.excludes("em"))
        #expect(code.excludes("link"))
        #expect(!code.excludes("code"))
    }

    @Test
    func addingCodeMarkDropsStrongAndEmphasis() {
        // The Phase 2 exit criterion — adding `code` over a `strong em`
        // span leaves only `code`.
        let base = MarkSet()
            .adding(ProseMark(type: "strong"), in: schema)
            .adding(ProseMark(type: "em"), in: schema)
        let withCode = base.adding(ProseMark(type: "code"), in: schema)
        #expect(withCode.marks.map(\.type) == ["code"])
    }

    @Test
    func addingNonCodeMarkOverCodeDoesNotStick() {
        // Symmetric exclusion — when `code` is already present, adding
        // `strong` is a no-op (code excludes strong).
        let base = MarkSet().adding(ProseMark(type: "code"), in: schema)
        let attempt = base.adding(ProseMark(type: "strong"), in: schema)
        #expect(attempt.marks.map(\.type) == ["code"])
    }

    // MARK: - MarkSet semantics

    @Test
    func markSetDeduplicatesByType() {
        let ms = MarkSet([
            ProseMark(type: "strong"),
            ProseMark(type: "em"),
            ProseMark(type: "strong", attrs: ["x": .string("y")])
        ])
        #expect(ms.marks.count == 2)
        #expect(ms.contains(type: "strong"))
        #expect(ms.contains(type: "em"))
    }

    @Test
    func markSetAddingReplacesExistingType() {
        let base = MarkSet([ProseMark(type: "link", attrs: ["href": .string("a")])])
        let updated = base.adding(ProseMark(type: "link", attrs: ["href": .string("b")]))
        #expect(updated.marks.count == 1)
        #expect(updated.mark(of: "link")?.attrs["href"] == .string("b"))
    }

    @Test
    func markSetSortsByRankWhenAddingThroughSchema() {
        // em is declared before strong in the default schema (PM-basic
        // order); adding strong first then em should leave [em, strong].
        let s1 = MarkSet().adding(ProseMark(type: "strong"), in: schema)
        let s2 = s1.adding(ProseMark(type: "em"), in: schema)
        #expect(s2.marks.map(\.type) == ["em", "strong"])
    }

    @Test
    func markTypeInclusivityMatchesProseMirrorDefaults() {
        #expect(schema.markType("strong")?.inclusive == true)
        #expect(schema.markType("em")?.inclusive == true)
        #expect(schema.markType("link")?.inclusive == false)
    }

    @Test
    func nodeTypeDerivedFlagsMatchProseMirror() {
        let para = schema.nodeType("paragraph")!
        #expect(para.isBlock)
        #expect(para.isTextblock)
        #expect(!para.isInline)
        let blockquote = schema.nodeType("blockquote")!
        #expect(blockquote.isBlock)
        #expect(!blockquote.isTextblock)
        let text = schema.nodeType("text")!
        #expect(text.isInline)
        #expect(!text.isBlock)
        #expect(text.isText)
        let hr = schema.nodeType("horizontal_rule")!
        #expect(hr.isLeaf)
        #expect(hr.isAtom)
        #expect(hr.isBlock)
    }

    @Test
    func tableCellDeclaresColspanRowspanForPMRoundTrip() {
        let cell = schema.nodeType("table_cell")!
        let attrNames = cell.attrs.map(\.name)
        #expect(attrNames.contains("colspan"))
        #expect(attrNames.contains("rowspan"))
        #expect(attrNames.contains("align"))
        let defaults = cell.defaultAttrs()
        #expect(defaults["colspan"] == .int(1))
        #expect(defaults["rowspan"] == .int(1))
    }

    @Test
    func markSetMergingPrefersOther() {
        let a = MarkSet([
            ProseMark(type: "strong"),
            ProseMark(type: "em")
        ])
        let b = MarkSet([
            ProseMark(type: "em", attrs: ["custom": .bool(true)]),
            ProseMark(type: "code")
        ])
        let merged = a.merging(b)
        #expect(merged.marks.count == 3)
        #expect(merged.mark(of: "em")?.attrs["custom"] == .bool(true))
        #expect(merged.contains(type: "code"))
    }

    // MARK: - NodePath semantics

    @Test
    func nodePathCommonPrefixComparesByID() {
        let doc = ProseNode(type: "doc")
        let para1 = ProseNode(type: "paragraph")
        let para2 = ProseNode(type: "paragraph")
        let p1 = NodePath([doc, para1])
        let p2 = NodePath([doc, para2])
        // Different paragraph IDs → only `doc` is shared.
        #expect(p1.commonPrefixDepth(with: p2) == 1)
        // Same path → full depth.
        #expect(p1.commonPrefixDepth(with: p1) == 2)
    }

    // MARK: - Projection: tree → storage

    @Test
    func projectsParagraphTextWithNodePathAndMarks() {
        let doc = ProseNode(type: "doc")
        let para = ProseNode(type: "paragraph")
        let tree: TreeNode = .structural(doc, [
            .structural(para, [
                .inline(text: "hello", marks: MarkSet())
            ])
        ])
        let document = ProseDocument(schema: schema, root: tree)
        let projected = document.project()
        #expect(projected.string == "hello\n")
        let path = projected.nodePath(at: 0)
        #expect(path?.depth == 2)
        #expect(path?.leaf?.type == "paragraph")
        #expect(path?.root?.type == "doc")
    }

    @Test
    func projectsBoldMarkOnInlineRun() {
        let doc = ProseNode(type: "doc")
        let para = ProseNode(type: "paragraph")
        let tree: TreeNode = .structural(doc, [
            .structural(para, [
                .inline(text: "bold", marks: MarkSet([ProseMark(type: "strong")]))
            ])
        ])
        let document = ProseDocument(schema: schema, root: tree)
        let projected = document.project()
        #expect(projected.string == "bold\n")
        let marks = projected.markSet(at: 0)
        #expect(marks?.contains(type: "strong") == true)
    }

    @Test
    func projectsBlockquoteWithNestedParagraphs() {
        let doc = ProseNode(type: "doc")
        let blockquote = ProseNode(type: "blockquote")
        let para1 = ProseNode(type: "paragraph")
        let para2 = ProseNode(type: "paragraph")
        let tree: TreeNode = .structural(doc, [
            .structural(blockquote, [
                .structural(para1, [.inline(text: "first", marks: MarkSet())]),
                .structural(para2, [.inline(text: "second", marks: MarkSet())])
            ])
        ])
        let document = ProseDocument(schema: schema, root: tree)
        let projected = document.project()
        // Two paragraphs joined by a newline, each followed by its own
        // closing newline.
        #expect(projected.string.contains("first"))
        #expect(projected.string.contains("second"))
        // Both paragraph runs share the same blockquote ancestor in their
        // path.
        let firstPath = projected.nodePath(at: 0)!
        let secondLoc = (projected.string as NSString).range(of: "second").location
        let secondPath = projected.nodePath(at: secondLoc)!
        #expect(firstPath.commonPrefixDepth(with: secondPath) == 2)
        // ... but their paragraph leaves differ.
        #expect(firstPath.leaf?.id != secondPath.leaf?.id)
    }

    @Test
    func projectsHorizontalRuleAsLeafCharacter() {
        let doc = ProseNode(type: "doc")
        let hr = ProseNode(type: "horizontal_rule")
        let tree: TreeNode = .structural(doc, [.leaf(hr)])
        let document = ProseDocument(schema: schema, root: tree)
        let projected = document.project()
        #expect(projected.length == 1)
        let path = projected.nodePath(at: 0)
        #expect(path?.leaf?.type == "horizontal_rule")
    }

    // MARK: - Round-trip: tree → storage → tree

    @Test
    func roundTripsParagraph() {
        let original = ProseDocument.make(schema: schema, children: [
            paragraph("a paragraph")
        ])
        let projected = original.project()
        let recovered = ProseDocument.from(storage: projected, schema: schema)
        assertEqualIgnoringIDs(original, recovered)
    }

    @Test
    func roundTripsHeading() {
        let original = ProseDocument.make(schema: schema, children: [
            heading(level: 2, text: "Title")
        ])
        let projected = original.project()
        let recovered = ProseDocument.from(storage: projected, schema: schema)
        assertEqualIgnoringIDs(original, recovered)
    }

    @Test
    func roundTripsBlockquoteWithNestedParagraphs() {
        let original = ProseDocument.make(schema: schema, children: [
            blockquote([
                paragraph("first"),
                paragraph("second")
            ])
        ])
        let projected = original.project()
        let recovered = ProseDocument.from(storage: projected, schema: schema)
        assertEqualIgnoringIDs(original, recovered)
    }

    @Test
    func roundTripsBulletList() {
        let original = ProseDocument.make(schema: schema, children: [
            list("bullet_list", items: [
                listItem([paragraph("one")]),
                listItem([paragraph("two")])
            ])
        ])
        let projected = original.project()
        let recovered = ProseDocument.from(storage: projected, schema: schema)
        assertEqualIgnoringIDs(original, recovered)
    }

    @Test
    func roundTripsTable() {
        let original = ProseDocument.make(schema: schema, children: [
            table([
                tableRow(header: true, cells: [
                    tableCell(align: "left", paragraph: "Command"),
                    tableCell(align: nil, paragraph: "Description")
                ]),
                tableRow(header: false, cells: [
                    tableCell(align: "left", paragraph: "git status"),
                    tableCell(align: nil, paragraph: "List files")
                ])
            ])
        ])
        let projected = original.project()
        let recovered = ProseDocument.from(storage: projected, schema: schema)
        assertEqualIgnoringIDs(original, recovered)
    }

    @Test
    func roundTripsHorizontalRule() {
        let original = ProseDocument.make(schema: schema, children: [
            paragraph("before"),
            .leaf(ProseNode(type: "horizontal_rule")),
            paragraph("after")
        ])
        let projected = original.project()
        let recovered = ProseDocument.from(storage: projected, schema: schema)
        assertEqualIgnoringIDs(original, recovered)
    }

    @Test
    func roundTripsMarksOnInlineRun() {
        let strong = MarkSet([ProseMark(type: "strong")])
        let para = ProseNode(type: "paragraph")
        let tree: TreeNode = .structural(ProseNode(type: "doc"), [
            .structural(para, [
                .inline(text: "plain ", marks: MarkSet()),
                .inline(text: "bold", marks: strong),
                .inline(text: " tail", marks: MarkSet())
            ])
        ])
        let original = ProseDocument(schema: schema, root: tree)
        let projected = original.project()
        let recovered = ProseDocument.from(storage: projected, schema: schema)
        // Walk the recovered paragraph and check that the bold run's mark
        // survived. The inline runs may be re-merged or split; what we
        // assert is presence of a strong mark on the "bold" substring.
        guard case .structural(_, let kids) = recovered.root,
              let firstBlock = kids.first,
              case .structural(_, let inlines) = firstBlock else {
            Issue.record("recovered tree shape did not match expectation")
            return
        }
        var sawStrong = false
        for child in inlines {
            if case .inline(let text, let marks) = child,
               text.contains("bold"),
               marks.contains(type: "strong") {
                sawStrong = true
            }
        }
        #expect(sawStrong)
    }

    // MARK: - Helpers

    private func paragraph(_ text: String) -> TreeNode {
        .structural(
            ProseNode(type: "paragraph"),
            [.inline(text: text, marks: MarkSet())]
        )
    }

    private func heading(level: Int, text: String) -> TreeNode {
        .structural(
            ProseNode(type: "heading", attrs: ["level": .int(level)]),
            [.inline(text: text, marks: MarkSet())]
        )
    }

    private func blockquote(_ children: [TreeNode]) -> TreeNode {
        .structural(ProseNode(type: "blockquote"), children)
    }

    private func list(_ type: String, items: [TreeNode]) -> TreeNode {
        .structural(ProseNode(type: type), items)
    }

    private func listItem(_ children: [TreeNode]) -> TreeNode {
        .structural(ProseNode(type: "list_item"), children)
    }

    private func table(_ rows: [TreeNode]) -> TreeNode {
        .structural(ProseNode(type: "table"), rows)
    }

    private func tableRow(header: Bool, cells: [TreeNode]) -> TreeNode {
        .structural(
            ProseNode(type: "table_row", attrs: ["header": .bool(header)]),
            cells
        )
    }

    private func tableCell(align: String?, paragraph: String) -> TreeNode {
        let alignAttr: ProseAttrValue = align.map { .string($0) } ?? .null
        return .structural(
            ProseNode(type: "table_cell", attrs: ["align": alignAttr]),
            [self.paragraph(paragraph)]
        )
    }

    /// Compare two trees ignoring per-instance NodeIDs but checking type,
    /// attrs, and inline text/marks — the meaningful structural shape.
    private func assertEqualIgnoringIDs(_ a: ProseDocument, _ b: ProseDocument) {
        let same = treesEqualIgnoringIDs(a.root, b.root)
        if !same {
            Issue.record("trees differ — original: \(describeTree(a.root))\n recovered: \(describeTree(b.root))")
        }
        #expect(same)
    }

    private func treesEqualIgnoringIDs(_ a: TreeNode, _ b: TreeNode) -> Bool {
        switch (a, b) {
        case (.inline(let ta, let ma), .inline(let tb, let mb)):
            return ta == tb && ma == mb
        case (.leaf(let na, let ma), .leaf(let nb, let mb)):
            return na.equalsIgnoringID(nb) && ma == mb
        case (.structural(let na, let ka), .structural(let nb, let kb)):
            guard na.equalsIgnoringID(nb) else { return false }
            // Allow merged-adjacent inline runs to be reshaped — compare
            // by canonicalizing to a flattened text+marks list when both
            // sides are inline-leaves only.
            let canA = canonicalize(ka)
            let canB = canonicalize(kb)
            guard canA.count == canB.count else { return false }
            for (x, y) in zip(canA, canB) where !treesEqualIgnoringIDs(x, y) {
                return false
            }
            return true
        default:
            return false
        }
    }

    /// Merge consecutive inline siblings sharing identical marks into one
    /// inline run, so the comparison doesn't fail on incidental run
    /// boundaries (the projector emits one run per inline child but the
    /// reverse projector may combine them when the storage representation
    /// happens to share an attribute run).
    private func canonicalize(_ children: [TreeNode]) -> [TreeNode] {
        var result: [TreeNode] = []
        for child in children {
            if case .inline(let text, let marks) = child,
               case .inline(let prevText, let prevMarks) = result.last ?? .leaf(ProseNode(type: "_")),
               marks == prevMarks {
                result[result.count - 1] = .inline(text: prevText + text, marks: marks)
            } else {
                result.append(child)
            }
        }
        return result
    }

    private func describeTree(_ tree: TreeNode, depth: Int = 0) -> String {
        let indent = String(repeating: "  ", count: depth)
        switch tree {
        case .inline(let text, let marks):
            return "\(indent)inline(\(text.debugDescription) marks=\(marks.marks.map(\.type)))"
        case .leaf(let node, _):
            return "\(indent)leaf(\(node.type))"
        case .structural(let node, let kids):
            let head = "\(indent)\(node.type) attrs=\(node.attrs)"
            let tail = kids.map { describeTree($0, depth: depth + 1) }.joined(separator: "\n")
            return tail.isEmpty ? head : "\(head)\n\(tail)"
        }
    }
}
