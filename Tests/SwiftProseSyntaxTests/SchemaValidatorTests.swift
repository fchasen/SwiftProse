import Testing
import Foundation
@testable import SwiftProseSyntax

@Suite("SchemaValidator")
struct SchemaValidatorTests {

    private let schema = Schema.defaultMarkdown

    private func makeParagraph(_ text: String) -> TreeNode {
        .structural(
            ProseNode(type: "paragraph"),
            [.inline(text: text, marks: MarkSet())]
        )
    }

    private func makeDoc(_ children: [TreeNode]) -> ProseDocument {
        ProseDocument.make(schema: schema, children: children)
    }

    @Test
    func validParagraphDocPasses() {
        let doc = makeDoc([makeParagraph("hello")])
        #expect(SchemaValidator.validate(doc).isEmpty)
    }

    @Test
    func emptyDocFailsRequiredContent() {
        let doc = makeDoc([])
        let diagnostics = SchemaValidator.validate(doc)
        #expect(!diagnostics.isEmpty)
    }

    @Test
    func bulletListMustContainListItems() {
        let badList = TreeNode.structural(
            ProseNode(type: "bullet_list"),
            [makeParagraph("not a list item")]
        )
        let doc = makeDoc([badList])
        let diagnostics = SchemaValidator.validate(doc)
        let hasInvalidContent = diagnostics.contains { diagnostic in
            if case .invalidContent(let parent, _, _) = diagnostic {
                return parent == "bullet_list"
            }
            return false
        }
        #expect(hasInvalidContent)
    }

    @Test
    func unknownNodeTypeIsReported() {
        let doc = makeDoc([
            .structural(ProseNode(type: "made_up_node"), [])
        ])
        let diagnostics = SchemaValidator.validate(doc)
        let hasUnknown = diagnostics.contains { diagnostic in
            if case .unknownNodeType(let name) = diagnostic {
                return name == "made_up_node"
            }
            return false
        }
        #expect(hasUnknown)
    }

    @Test
    func headingWithInlineChildrenPasses() {
        let doc = makeDoc([
            .structural(
                ProseNode(type: "heading", attrs: ["level": .int(2)]),
                [.inline(text: "Title", marks: MarkSet())]
            )
        ])
        #expect(SchemaValidator.validate(doc).isEmpty)
    }

    @Test
    func nestedBulletListPasses() {
        let listItemKid = TreeNode.structural(
            ProseNode(type: "list_item"),
            [makeParagraph("one")]
        )
        let bulletList = TreeNode.structural(
            ProseNode(type: "bullet_list"),
            [listItemKid]
        )
        let doc = makeDoc([bulletList])
        #expect(SchemaValidator.validate(doc).isEmpty)
    }
}
