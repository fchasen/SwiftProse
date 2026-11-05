import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Read-only mode")
@MainActor
struct ReadOnlyModeTests {
    private func readOnly(_ markdown: String) -> EditorController {
        let controller = HeadlessEditor(markdown: markdown).controller
        controller.setSelection(NSRange(location: 0, length: controller.textStorage.length))
        controller.isEditable = false
        return controller
    }

    @Test func performNoOpsWhenNotEditable() {
        let controller = readOnly("hello\n")
        let before = controller.markdown()
        controller.perform(.bold)
        controller.perform(.heading(level: 2))
        #expect(controller.markdown() == before)
        #expect(controller.textStorage.markdownInlineIntent(at: 0).isEmpty)
        #expect(controller.textStorage.markdownBlock(at: 0)?.headingLevel == nil)
    }

    @Test func canPerformReturnsFalseWhenNotEditable() {
        let controller = readOnly("hello\n")
        #expect(controller.canPerform(.bold) == false)
        #expect(controller.canPerform(.heading(level: 1)) == false)
    }

    @Test func toggleCheckboxAllowedWhenOptInEvenIfNotEditable() {
        let controller = readOnly("- [ ] task\n")
        controller.allowsCheckboxToggle = true
        #expect(controller.toggleCheckbox(at: 0))
        #expect(controller.markdown() == "- [x] task")
        controller.perform(.bold)
        #expect(controller.markdown() == "- [x] task")
    }

    @Test func programmaticApplyStillWorksWhenNotEditable() {
        let controller = readOnly("hello\n")
        controller.setMarkdown("world\n")
        #expect(controller.markdown() == "world\n")
    }

    @Test func reEnablingRestoresEditing() {
        let controller = readOnly("hi\n")
        controller.perform(.heading(level: 1))
        #expect(controller.markdown() == "hi\n")
        controller.isEditable = true
        controller.perform(.heading(level: 1))
        #expect(controller.markdown() == "# hi")
    }
}
