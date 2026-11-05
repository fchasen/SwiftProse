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
struct BlockquoteDepthTests {
    @Test func setSpecRaisesBlockquoteDepth() {
        let harness = EditorHarness(markdown: "hello\n")
        harness.select(0)
        harness.step { harness.controller.perform(.blockquote) }
        #expect(harness.block(at: 0)?.quoteTokens.count == 1)
        #expect(harness.markdown == "> hello")
    }

    @Test func toggleBlockquoteCommandRoundTripsThroughMarkdown() {
        let harness = EditorHarness(markdown: "**bold** text\n")
        harness.select(0)
        harness.step { harness.controller.perform(.blockquote) }
        #expect(harness.markdown == "> **bold** text")
        #expect(harness.storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
        harness.select(0)
        harness.step { harness.controller.perform(.blockquote) }
        #expect(harness.block(at: 0)?.quoteTokens.isEmpty == true)
        #expect(harness.markdown == "**bold** text\n")
    }

    @Test func nestedDepthTwoIsRepresentable() {
        let harness = EditorHarness(markdown: "> > x\n")
        let tokens = harness.block(at: 0)?.quoteTokens ?? []
        #expect(tokens.count == 2)
        #expect(Set(tokens).count == 2)
        #expect(harness.markdown == "> > x\n")
        harness.select(1)
        harness.type("y")
        #expect(harness.block(at: 0)?.quoteTokens == tokens)
        #expect(harness.markdown == "> > xy")
    }
}
#endif
