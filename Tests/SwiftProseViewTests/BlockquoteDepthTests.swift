import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct BlockquoteDepthTests {

    @Test func setSpecRaisesBlockquoteDepth() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let storage = controller.textStorage
        let env = controller.makeStepEnvironment()
        let lineRange = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let step = Step.setSpec(lineRange: lineRange, BlockSpec(kind: .paragraph, blockquoteDepth: 1))
        _ = step.apply(to: storage, env: env)
        let spec = storage.blockSpec(at: 0)
        #expect(spec?.blockquoteDepth == 1)
        #expect(controller.markdown().contains("> hello"))
    }

    @Test func toggleBlockquoteCommandRoundTripsThroughMarkdown() throws {
        let controller = try EditorController(initialMarkdown: "**bold** text\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.blockquote)
        #expect(controller.markdown().contains("> "))
        #expect(controller.markdown().contains("**bold**"))
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.blockquote)
        let after = controller.markdown()
        #expect(after.hasPrefix("**bold**") || after.hasPrefix("bold"))
    }

    @Test func nestedDepthTwoIsRepresentable() throws {
        let controller = try EditorController(initialMarkdown: "x\n")
        let storage = controller.textStorage
        let env = controller.makeStepEnvironment()
        let lineRange = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let step = Step.setSpec(lineRange: lineRange, BlockSpec(kind: .paragraph, blockquoteDepth: 2))
        _ = step.apply(to: storage, env: env)
        #expect(storage.blockSpec(at: 0)?.blockquoteDepth == 2)
        #expect(controller.markdown().contains("> > "))
    }
}
