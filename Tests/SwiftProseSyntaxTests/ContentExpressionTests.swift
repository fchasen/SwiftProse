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
}
