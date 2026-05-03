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
        return StepEnvironment(compiler: compiler, serializer: serializer, theme: .default, mode: .rich)
    }

    private func storage(from markdown: String) throws -> NSTextStorage {
        let compiler = try MarkdownAttributedCompiler()
        let attributed = compiler.compile(markdown, mode: .rich, theme: .default)
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
}
