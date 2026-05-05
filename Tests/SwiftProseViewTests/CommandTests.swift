import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct CommandTests {

    private func makeEnv() throws -> StepEnvironment {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        return StepEnvironment(compiler: compiler, serializer: serializer, theme: .default)
    }

    private func storage(from markdown: String) throws -> NSTextStorage {
        let compiler = try MarkdownAttributedCompiler()
        let attributed = compiler.compile(markdown, theme: .default)
        let storage = NSTextStorage()
        storage.append(attributed)
        return storage
    }

    @Test func registryDefaultsExposeEveryAction() {
        let registry = CommandRegistry.makeDefault()
        let actions: [EditorAction] = [
            .bold, .italic, .strikethrough, .codeSpan,
            .heading(level: 1), .heading(level: 2), .heading(level: 3),
            .heading(level: 4), .heading(level: 5), .heading(level: 6),
            .unorderedList, .orderedList, .taskList,
            .blockquote, .codeBlock, .horizontalRule, .indent, .outdent
        ]
        for action in actions {
            #expect(registry.command(for: action) != nil, "missing command for \(action)")
        }
    }

    @Test func inlineCommandsBuildToggleStep() throws {
        let env = try makeEnv()
        let storage = try storage(from: "hello\n")
        let selection = NSRange(location: 0, length: 5)
        let bold = ToggleBoldCommand().transaction(storage: storage, selection: selection, env: env)
        #expect(bold?.steps.count == 1)
        if case .toggleInlineMark(_, let mark) = bold?.steps.first {
            #expect(mark == .bold)
        } else {
            Issue.record("expected toggleInlineMark step")
        }
    }

    @Test func headingCommandProducesOneStepPerParagraph() throws {
        let env = try makeEnv()
        let storage = try storage(from: "first\n\nsecond\n\nthird\n")
        let selection = NSRange(location: 0, length: storage.length)
        let tx = SetHeadingCommand(level: 2).transaction(storage: storage, selection: selection, env: env)
        #expect((tx?.steps.count ?? 0) >= 3)
        for step in tx?.steps ?? [] {
            if case .setSpec(_, let spec) = step {
                if case .heading(let level) = spec.kind {
                    #expect(level == 2)
                } else {
                    Issue.record("expected heading spec, got \(spec.kind)")
                }
            }
        }
    }

    @Test func outdentCanExecuteOnlyWhenNested() throws {
        let plain = try storage(from: "paragraph\n")
        let quoted = try storage(from: "> quoted\n")
        let probe = NSRange(location: 0, length: 0)
        let outdent = OutdentCommand()
        #expect(outdent.canExecute(storage: plain, selection: probe) == false)
        #expect(outdent.canExecute(storage: quoted, selection: probe) == true)
    }

    @Test func emptyStorageBlockCommandStillProducesAStep() throws {
        let env = try makeEnv()
        let storage = NSTextStorage()
        let tx = ToggleUnorderedListCommand().transaction(
            storage: storage,
            selection: NSRange(location: 0, length: 0),
            env: env
        )
        #expect(tx?.steps.count == 1)
        if case .setSpec(_, let spec) = tx?.steps.first {
            #expect(spec.kind == BlockSpec.Kind.unorderedListItem)
        } else {
            Issue.record("expected setSpec step on empty storage")
        }
    }

    @Test func toggleCodeBlockOnEmptyParagraphProducesEmptyBody() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.codeBlock)
        // A freshly-toggled empty code block should hold a single-line empty
        // body (just "\n"), not two empty lines.
        #expect(controller.textStorage.length == 1)
        let spec = controller.textStorage.blockSpec(at: 0)
        if case .fencedCode = spec?.kind {
            // ok
        } else {
            Issue.record("expected fenced code spec, got \(String(describing: spec?.kind))")
        }
    }

    @Test func toggleCodeBlockOnNonEmptyParagraphKeepsContent() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.codeBlock)
        // The block's body should be just "hello\n" — the original line —
        // not "hello\n\n" (extra blank tail).
        #expect(controller.textStorage.length == 6,
                "expected single-line body, got length \(controller.textStorage.length): \(String(reflecting: controller.textStorage.string))")
        #expect(controller.textStorage.string == "hello\n")
        let spec = controller.textStorage.blockSpec(at: 0)
        if case .fencedCode = spec?.kind {
            // ok
        } else {
            Issue.record("expected fenced code spec, got \(String(describing: spec?.kind))")
        }
    }

    @Test func toggleCodeBlockSerializesWithoutExtraBlankLine() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        #expect(md == "```\nhello\n```\n",
                "expected canonical fenced output, got \(String(reflecting: md))")
    }

    @Test func toggleCodeBlockAtCursorEndOfContent() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 6, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "```\nhello\n```\n")
    }
}
