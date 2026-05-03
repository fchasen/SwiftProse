import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct StepTests {

    private func env() throws -> StepEnvironment {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        return StepEnvironment(
            compiler: compiler,
            serializer: serializer,
            theme: .default,
            dialect: .commonMark,
            mode: .rich
        )
    }

    private func storage(from md: String) throws -> NSTextStorage {
        let env = try env()
        let attr = env.compiler.compile(md, dialect: .commonMark, mode: .rich, theme: .default)
        return NSTextStorage(attributedString: attr)
    }

    @Test func replaceTextStepInsertsAndInverts() throws {
        let env = try env()
        let storage = try storage(from: "hello\n")
        let step = Step.replaceText(range: NSRange(location: 5, length: 0), with: NSAttributedString(string: "!"))
        let applied = step.apply(to: storage, env: env)
        #expect(storage.string == "hello!\n")
        #expect(applied.mappedRange == NSRange(location: 5, length: 1))
        let undone = applied.inverse.apply(to: storage, env: env)
        #expect(storage.string == "hello\n")
        _ = undone
    }

    @Test func setSpecParagraphToHeadingPromotes() throws {
        let env = try env()
        let storage = try storage(from: "hello\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 2)))
        _ = step.apply(to: storage, env: env)
        #expect(env.serializer.serialize(storage, dialect: .commonMark) == "## hello\n")
        let spec = storage.blockSpec(at: 0)
        #expect(spec?.kind == .heading(level: 2))
    }

    @Test func setSpecHeadingToParagraphStrips() throws {
        let env = try env()
        let storage = try storage(from: "## title\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(lineRange: lineRange, .paragraph)
        _ = step.apply(to: storage, env: env)
        #expect(env.serializer.serialize(storage, dialect: .commonMark) == "title\n")
    }

    @Test func setSpecParagraphToBlockquote() throws {
        let env = try env()
        let storage = try storage(from: "hello\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(lineRange: lineRange, BlockSpec(kind: .paragraph, blockquoteDepth: 1))
        _ = step.apply(to: storage, env: env)
        #expect(env.serializer.serialize(storage, dialect: .commonMark) == "> hello\n")
        for i in 0..<storage.length {
            #expect(storage.blockSpec(at: i)?.blockquoteDepth == 1, "char \(i) should have depth 1")
        }
    }

    @Test func setSpecParagraphToBullet() throws {
        let env = try env()
        let storage = try storage(from: "alpha\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(lineRange: lineRange, BlockSpec(kind: .unorderedListItem))
        _ = step.apply(to: storage, env: env)
        #expect(env.serializer.serialize(storage, dialect: .commonMark) == "- alpha\n")
    }

    @Test func setSpecBulletToParagraph() throws {
        let env = try env()
        let storage = try storage(from: "- alpha\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(lineRange: lineRange, .paragraph)
        _ = step.apply(to: storage, env: env)
        #expect(env.serializer.serialize(storage, dialect: .commonMark) == "alpha\n")
    }

    @Test func setSpecInverseRoundTrips() throws {
        let env = try env()
        let storage = try storage(from: "hello\n")
        let originalMarkdown = env.serializer.serialize(storage, dialect: .commonMark)
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 1)))
        let applied = step.apply(to: storage, env: env)
        #expect(env.serializer.serialize(storage, dialect: .commonMark) == "# hello\n")
        _ = applied.inverse.apply(to: storage, env: env)
        #expect(env.serializer.serialize(storage, dialect: .commonMark) == originalMarkdown)
    }

    @Test func transactionAppliesAllStepsInOrder() throws {
        let env = try env()
        let storage = try storage(from: "hello\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let transaction = Transaction(steps: [
            .setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 1)))
        ])
        let applied = transaction.apply(to: storage, env: env)
        #expect(env.serializer.serialize(storage, dialect: .commonMark) == "# hello\n")
        _ = applied
    }

    @Test func setSpecParagraphToNestedBullet() throws {
        let env = try env()
        let storage = try storage(from: "alpha\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(
            lineRange: lineRange,
            BlockSpec(kind: .unorderedListItem, listLevel: 2)
        )
        _ = step.apply(to: storage, env: env)
        let spec = try #require(storage.blockSpec(at: 0))
        #expect(spec.kind == .unorderedListItem,
                "expected nested bullet, got \(spec.kind)")
        #expect(spec.listLevel == 2,
                "expected listLevel 2, got \(spec.listLevel)")
    }

    @Test func setSpecParagraphToNestedOrdered() throws {
        let env = try env()
        let storage = try storage(from: "alpha\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(
            lineRange: lineRange,
            BlockSpec(kind: .orderedListItem(index: 1), listLevel: 1)
        )
        _ = step.apply(to: storage, env: env)
        let spec = try #require(storage.blockSpec(at: 0))
        if case .orderedListItem = spec.kind {
            #expect(spec.listLevel == 1)
        } else {
            Issue.record("expected ordered list item at level 1, got \(spec)")
        }
    }

    @Test func setSpecParagraphToNestedTask() throws {
        let env = try env()
        let storage = try storage(from: "alpha\n")
        let lineRange = NSRange(location: 0, length: storage.length)
        let step = Step.setSpec(
            lineRange: lineRange,
            BlockSpec(kind: .taskListItem(checked: true), listLevel: 1)
        )
        _ = step.apply(to: storage, env: env)
        let spec = try #require(storage.blockSpec(at: 0))
        #expect(spec.kind == .taskListItem(checked: true))
        #expect(spec.listLevel == 1)
    }

    @Test func controllerApplyWiresUndo() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n")
        let lineRange = NSRange(location: 0, length: controller.textStorage.length)
        controller.apply(Transaction(steps: [
            .setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 2)))
        ]))
        #expect(controller.markdown() == "## alpha\n")
        controller.undoManager.undo()
        #expect(controller.markdown() == "alpha\n")
        controller.undoManager.redo()
        #expect(controller.markdown() == "## alpha\n")
    }
}
