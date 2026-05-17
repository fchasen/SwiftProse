import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct ReadOnlyModeTests {

    @Test func performNoOpsWhenNotEditable() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.isEditable = false
        let before = controller.markdown()
        controller.perform(.bold)
        controller.perform(.heading(level: 2))
        #expect(controller.markdown() == before)
    }

    @Test func canPerformReturnsFalseWhenNotEditable() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.isEditable = false
        #expect(controller.canPerform(.bold) == false)
        #expect(controller.canPerform(.heading(level: 1)) == false)
    }

    @Test func toggleCheckboxBlockedWhenNotEditable() throws {
        let controller = try EditorController(initialMarkdown: "- [ ] task\n")
        controller.isEditable = false
        // Cursor at the checkbox glyph (location 0 carries the attachment).
        let before = controller.markdown()
        let didToggle = controller.toggleCheckbox(at: 0)
        #expect(didToggle == false)
        #expect(controller.markdown() == before)
    }

    @Test func toggleCheckboxAllowedWhenOptInEvenIfNotEditable() throws {
        let controller = try EditorController(initialMarkdown: "- [ ] task\n")
        controller.isEditable = false
        controller.allowsCheckboxToggle = true
        let didToggle = controller.toggleCheckbox(at: 0)
        #expect(didToggle == true)
        #expect(controller.markdown() == "- [x] task\n")
        // perform(_:) is still gated — toolbar / keymap mutations stay off.
        controller.perform(.bold)
        #expect(controller.markdown() == "- [x] task\n")
    }

    @Test func programmaticApplyStillWorksWhenNotEditable() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.isEditable = false
        controller.setMarkdown("world\n")
        #expect(controller.markdown() == "world\n")
    }

    @Test func reEnablingRestoresEditing() throws {
        let controller = try EditorController(initialMarkdown: "hi\n")
        controller.isEditable = false
        controller.perform(.heading(level: 1))
        #expect(controller.markdown() == "hi\n")
        controller.isEditable = true
        controller.perform(.heading(level: 1))
        #expect(controller.markdown() == "# hi\n")
    }
}
