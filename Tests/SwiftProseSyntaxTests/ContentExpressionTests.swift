import Testing
import Foundation
@testable import SwiftProseSyntax

@Suite("ContentExpression cardinality matcher")
struct ContentExpressionTests {

    @Test
    func plusRequiresOneOrMore() {
        let expr = ContentExpression("block+", allowedNodes: ["paragraph", "heading"])
        #expect(expr.matches(childTypes: ["paragraph"]))
        #expect(expr.matches(childTypes: ["paragraph", "heading"]))
        #expect(!expr.matches(childTypes: []))
    }

    @Test
    func starAllowsZeroOrMore() {
        let expr = ContentExpression("inline*", allowedNodes: ["text", "hard_break"])
        #expect(expr.matches(childTypes: []))
        #expect(expr.matches(childTypes: ["text"]))
        #expect(expr.matches(childTypes: ["text", "hard_break", "text"]))
    }

    @Test
    func questionMarkAllowsZeroOrOne() {
        let expr = ContentExpression("paragraph?", allowedNodes: ["paragraph"])
        #expect(expr.matches(childTypes: []))
        #expect(expr.matches(childTypes: ["paragraph"]))
        #expect(!expr.matches(childTypes: ["paragraph", "paragraph"]))
    }

    @Test
    func bareNameRequiresExactlyOne() {
        let expr = ContentExpression("paragraph", allowedNodes: ["paragraph"])
        #expect(expr.matches(childTypes: ["paragraph"]))
        #expect(!expr.matches(childTypes: []))
        #expect(!expr.matches(childTypes: ["paragraph", "paragraph"]))
    }

    @Test
    func disallowedTypeFails() {
        let expr = ContentExpression("list_item+", allowedNodes: ["list_item"])
        #expect(!expr.matches(childTypes: ["paragraph"]))
        #expect(!expr.matches(childTypes: ["list_item", "paragraph"]))
    }

    @Test
    func choiceExpressionAcceptsAnyAllowed() {
        let expr = ContentExpression(
            "(table_cell | table_header)+",
            allowedNodes: ["table_cell", "table_header"]
        )
        #expect(expr.matches(childTypes: ["table_cell"]))
        #expect(expr.matches(childTypes: ["table_header", "table_cell"]))
        #expect(!expr.matches(childTypes: ["paragraph"]))
        #expect(!expr.matches(childTypes: []))
    }

    // MARK: - sequence patterns (powered by ContentMatch)

    @Test
    func sequenceExpressionRequiresLeadingParagraphThenAnyBlock() {
        // PM list_item content rule. Must start with paragraph; subsequent
        // children may be any block-group node.
        let expr = ContentExpression(
            "paragraph block*",
            allowedNodes: ["paragraph", "bullet_list", "ordered_list"]
        )
        #expect(expr.matches(childTypes: ["paragraph"]))
        #expect(expr.matches(childTypes: ["paragraph", "bullet_list"]))
        #expect(expr.matches(childTypes: ["paragraph", "bullet_list", "ordered_list"]))
        #expect(!expr.matches(childTypes: []))
    }

    @Test
    func contentMatchAdvancesByType() {
        let expr = ContentExpression(
            "paragraph block*",
            allowedNodes: ["paragraph", "bullet_list"]
        )
        let s0 = expr.match.initialState
        #expect(!expr.match.validEnd(at: s0))
        let s1 = expr.match.matchType("paragraph", from: s0)
        #expect(s1 != nil)
        #expect(expr.match.validEnd(at: s1!))
        let s2 = expr.match.matchType("bullet_list", from: s1!)
        #expect(s2 != nil)
        #expect(expr.match.validEnd(at: s2!))
    }

    @Test
    func contentMatchDefaultTypePicksFirstRequired() {
        let expr = ContentExpression(
            "paragraph block*",
            allowedNodes: ["paragraph", "bullet_list"]
        )
        #expect(expr.match.defaultType() == "paragraph")
    }
}
