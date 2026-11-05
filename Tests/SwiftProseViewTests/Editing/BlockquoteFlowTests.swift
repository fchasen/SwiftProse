#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite(.serialized)
@MainActor
struct BlockquoteFlowTests {
    @Test func clickBlockquoteOnEmptyEditorRendersWithDepth() {
        let harness = EditorHarness(markdown: "")
        harness.step { harness.controller.perform(.blockquote) }
        #expect(harness.controller.paragraphInfo(at: 0).block.isInQuote)
        #expect(harness.controller.isActive(.blockquote))
        harness.type("f")
        #expect(harness.block(at: 0)?.quoteTokens.count == 1)
    }

    @Test func typingIntoBlockquotePreservesDepth() {
        let harness = EditorHarness(markdown: "")
        harness.step { harness.controller.perform(.blockquote) }
        harness.type("fred")
        let tokens = harness.block(at: 0)?.quoteTokens ?? []
        #expect(tokens.count == 1)
        for index in 0..<harness.storage.length {
            #expect(harness.block(at: index)?.quoteTokens == tokens, "char at \(index)")
        }
        #expect(harness.markdown == "> fred")
    }
}
#endif
