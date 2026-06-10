import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct ReplaceRangeStepTests {

    private func env(for controller: EditorController) -> StepEnvironment {
        controller.makeStepEnvironment()
    }

    @Test func replaceRangeInsertsSliceAndProducesInverse() throws {
        let controller = try EditorController(initialMarkdown: "hello world", theme: .default)
        let storage = controller.textStorage
        let inserted = Slice(
            content: Fragment([.inline(text: "X", marks: MarkSet())]),
            openStart: 1, openEnd: 1
        )
        let step = Step.replaceRange(from: 5, to: 5, slice: inserted)
        #expect(step.canApply(to: storage) == nil)
        #expect(step.isStructural)
        let applied = step.apply(to: storage, env: env(for: controller))
        #expect(controller.markdown() == "helloX world")
        // Inverse rebuilds the original storage.
        let priorStep = applied.inverse
        _ = priorStep.apply(to: storage, env: env(for: controller))
        #expect(controller.markdown() == "hello world")
    }

    @Test func replaceRangeReplacesRangeContent() throws {
        let controller = try EditorController(initialMarkdown: "abc def", theme: .default)
        let storage = controller.textStorage
        let slice = Slice(
            content: Fragment([.inline(text: "XYZ", marks: MarkSet())]),
            openStart: 1, openEnd: 1
        )
        let step = Step.replaceRange(from: 4, to: 7, slice: slice)
        _ = step.apply(to: storage, env: env(for: controller))
        #expect(controller.markdown() == "abc XYZ")
    }

    @Test func replaceRangeInsertsClosedBlockSlice() throws {
        let controller = try EditorController(initialMarkdown: "before", theme: .default)
        let storage = controller.textStorage
        let blockSlice = Slice(
            content: Fragment([
                .structural(
                    ProseNode(type: "heading", attrs: ["level": .int(2)]),
                    [.inline(text: "Title", marks: MarkSet())]
                )
            ]),
            openStart: 0, openEnd: 0
        )
        let step = Step.replaceRange(from: storage.length, to: storage.length, slice: blockSlice)
        _ = step.apply(to: storage, env: env(for: controller))
        let md = controller.markdown()
        #expect(md.contains("before"))
        #expect(md.contains("## Title"))
    }

    @Test func dispatchPasteUsesReplaceRangeStep() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        controller.testSelection = NSRange(location: 0, length: 0)
        let event = PasteEvent(
            text: nil,
            html: "<p><strong>bold</strong></p>",
            selection: NSRange(location: 0, length: 0)
        )
        _ = controller.dispatchPaste(event)
        #expect(controller.markdown().contains("**bold**"))
        // Single transaction → single undo step.
        #expect(controller.undoManager.canUndo)
        controller.undoManager.undo()
        // Undo restores empty doc.
        #expect(controller.markdown() == "" || controller.markdown() == "\n")
    }

    @Test func replaceRangeOutOfBoundsReportsError() throws {
        let controller = try EditorController(initialMarkdown: "abc", theme: .default)
        let slice = Slice(content: Fragment([.inline(text: "x", marks: MarkSet())]),
                          openStart: 1, openEnd: 1)
        let step = Step.replaceRange(from: 100, to: 200, slice: slice)
        let legality = step.canApply(to: controller.textStorage)
        guard case .some(.rangeOutOfBounds) = legality else {
            Issue.record("expected rangeOutOfBounds, got \(String(describing: legality))")
            return
        }
    }

    @Test func replaceRangeMappingShiftsThroughEarlierSteps() throws {
        let controller = try EditorController(initialMarkdown: "abcdef", theme: .default)
        var mapping = Mapping.empty
        // Simulate a prior step that inserted 3 chars at position 0.
        mapping.append(StepMap(oldRange: NSRange(location: 0, length: 0), newLength: 3))
        let slice = Slice(content: Fragment([.inline(text: "x", marks: MarkSet())]),
                          openStart: 1, openEnd: 1)
        let step = Step.replaceRange(from: 2, to: 4, slice: slice)
        let mapped = step.mapped(through: mapping)
        if case .replaceRange(let from, let to, _) = mapped {
            #expect(from == 5)
            #expect(to == 7)
        } else {
            Issue.record("expected replaceRange after mapping")
        }
        _ = controller // silence unused-let warning
    }
}
