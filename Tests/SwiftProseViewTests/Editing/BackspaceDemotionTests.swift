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
struct BackspaceDemotionTests {
    @Test func backspaceAtStartOfBulletDemotesToParagraph() {
        let harness = EditorHarness(markdown: "- apple\n")
        harness.select(0)
        harness.deleteBackward()
        #expect(harness.string == "apple")
        #expect(harness.markdown == "apple")
        #expect(harness.block(at: 0)?.isListItem == false)
        #expect(harness.textLists(at: 0).isEmpty)
    }

    @Test func backspaceMidContentDoesNotDemote() {
        let editor = HeadlessEditor(markdown: "- apple\n")
        editor.select(4)
        #expect(!editor.controller.handleBackspace())
        #expect(editor.controller.markdown() == "- apple\n")
    }

    @Test func backspaceOnNonListReturnsFalse() {
        let editor = HeadlessEditor(markdown: "hello\n")
        editor.select(0)
        #expect(!editor.controller.handleBackspace())
        #expect(editor.controller.markdown() == "hello\n")
    }
}
#endif
