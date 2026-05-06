import Testing
import Foundation
import AppKit
@testable import SwiftProseView
@testable import SwiftProseSyntax

@Suite("Step inverse round-trip")
struct StepInverseRoundTripTests {

    private func makeController() throws -> EditorController {
        try EditorController(initialMarkdown: "Hello world\n")
    }

    private func snapshot(_ storage: NSTextStorage) -> NSAttributedString {
        NSAttributedString(attributedString: storage)
    }

    private func equalIgnoringNodeIDs(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        guard a.length == b.length, a.string == b.string else { return false }
        return true
    }

    @Test
    func replaceTextRoundTrips() throws {
        let controller = try makeController()
        let pre = snapshot(controller.textStorage)
        let env = controller.makeStepEnvironment()
        let insert = NSAttributedString(string: "X", attributes: [:])
        let step = Step.replaceText(range: NSRange(location: 5, length: 0), with: insert)
        let applied = step.apply(to: controller.textStorage, env: env)
        #expect(controller.textStorage.string == "HelloX world\n")
        _ = applied.inverse.apply(to: controller.textStorage, env: env)
        #expect(equalIgnoringNodeIDs(controller.textStorage, pre))
    }

    @Test
    func addMarkInverseIsRemoveMark() throws {
        let controller = try makeController()
        let env = controller.makeStepEnvironment()
        let range = NSRange(location: 0, length: 5)
        let step = Step.addMark(range: range, mark: ProseMark(type: "strong"))
        let applied = step.apply(to: controller.textStorage, env: env)
        // Inverse must be removeMark of the same type.
        if case .removeMark(_, let markType) = applied.inverse {
            #expect(markType == "strong")
        } else {
            Issue.record("addMark inverse should be removeMark; got \(applied.inverse)")
        }
        // Storage no longer carries the mark after inverse applies.
        _ = applied.inverse.apply(to: controller.textStorage, env: env)
        var sawStrong = false
        controller.textStorage.enumerateAttribute(.proseMarks, in: range) { value, _, _ in
            if let box = value as? MarkSetBox, box.marks.contains(type: "strong") {
                sawStrong = true
            }
        }
        #expect(!sawStrong)
    }

    @Test
    func removeMarkInverseIsAddMark() throws {
        let controller = try makeController()
        let env = controller.makeStepEnvironment()
        let range = NSRange(location: 0, length: 5)
        // Stamp a link mark first so the remove has something to invert.
        let linkMark = ProseMark(type: "link", attrs: ["href": .string("https://x")])
        _ = Step.addMark(range: range, mark: linkMark).apply(to: controller.textStorage, env: env)
        let step = Step.removeMark(range: range, markType: "link")
        let applied = step.apply(to: controller.textStorage, env: env)
        if case .addMark(_, let mark) = applied.inverse {
            #expect(mark.type == "link")
            #expect(mark.attrs["href"]?.stringValue == "https://x")
        } else {
            Issue.record("removeMark inverse should be addMark; got \(applied.inverse)")
        }
    }

    @Test
    func setSpecInverseIsSetSpec() throws {
        let controller = try makeController()
        let env = controller.makeStepEnvironment()
        let lineRange = NSRange(location: 0, length: controller.textStorage.length)
        let step = Step.setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 2)))
        let applied = step.apply(to: controller.textStorage, env: env)
        // Inverse should be a typed setSpec (or a replaceText fallback).
        switch applied.inverse {
        case .setSpec, .replaceText: break
        default: Issue.record("setSpec inverse should be setSpec or replaceText; got \(applied.inverse)")
        }
    }

    @Test
    func setNodeAttrsInverseIsSetNodeAttrs() throws {
        let controller = try makeController()
        let env = controller.makeStepEnvironment()
        // Use the existing paragraph leaf in the controller.
        guard let path = controller.textStorage.nodePath(at: 0) else {
            Issue.record("expected a node path at offset 0")
            return
        }
        let step = Step.setNodeAttrs(path: path, attrs: ["fenced": .bool(false)])
        let applied = step.apply(to: controller.textStorage, env: env)
        if case .setNodeAttrs = applied.inverse {} else {
            Issue.record("setNodeAttrs inverse should be setNodeAttrs; got \(applied.inverse)")
        }
    }

    @Test
    func canApplyRejectsOutOfBoundsRange() throws {
        let controller = try makeController()
        let oob = NSRange(location: controller.textStorage.length + 100, length: 0)
        let step = Step.replaceText(range: oob, with: NSAttributedString(string: "x"))
        if case .rangeOutOfBounds = step.canApply(to: controller.textStorage) {} else {
            Issue.record("expected rangeOutOfBounds for OOB range")
        }
    }

    @Test
    func transactionApplySkipsIllegalSteps() throws {
        let controller = try makeController()
        let env = controller.makeStepEnvironment()
        let pre = controller.textStorage.string
        let oob = NSRange(location: controller.textStorage.length + 100, length: 0)
        let tx = Transaction(steps: [
            .replaceText(range: oob, with: NSAttributedString(string: "x")),
            .replaceText(range: NSRange(location: 0, length: 0), with: NSAttributedString(string: "Y"))
        ])
        _ = tx.apply(to: controller.textStorage, env: env)
        // The illegal step is skipped; the legal one applies.
        #expect(controller.textStorage.string == "Y" + pre)
    }
}
