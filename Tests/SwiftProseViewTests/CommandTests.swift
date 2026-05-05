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

    @Test func toggleCodeBlockOnEmptyDocInsertsEmptyBlock() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.codeBlock)
        let spec = controller.textStorage.blockSpec(at: 0)
        if case .fencedCode = spec?.kind {
            // ok
        } else {
            Issue.record("expected fenced code spec, got \(String(describing: spec?.kind))")
        }
        #expect(controller.markdown() == "```\n\n```\n",
                "expected canonical empty fence, got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor on a non-empty paragraph: the existing text stays put and a
    /// fresh empty code block is inserted after it.
    @Test func toggleCodeBlockOnNonEmptyParagraphInsertsAfter() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "hello\n\n```\n\n```\n",
                "got \(String(reflecting: controller.markdown()))")
        let firstSpec = controller.textStorage.blockSpec(at: 0)
        #expect(firstSpec?.kind == .paragraph,
                "first paragraph must stay plain, got \(String(describing: firstSpec?.kind))")
    }

    @Test func toggleCodeBlockAtCursorEndOfContentInsertsAfter() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 6, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "hello\n\n```\n\n```\n")
    }

    // MARK: - code block: cursor-position consistency

    /// Cursor anywhere inside a non-empty paragraph: same insert-after
    /// outcome regardless of column.
    @Test(arguments: [0, 1, 3, 5, 6])
    func toggleCodeBlockIsStableAcrossCursorColumns(cursor: Int) throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: cursor, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "hello\n\n```\n\n```\n",
                "cursor=\(cursor) produced \(String(reflecting: controller.markdown()))")
    }

    /// Multi-paragraph document: the existing paragraphs stay intact and a
    /// fresh empty block lands immediately after the cursor's paragraph.
    @Test func toggleCodeBlockOnSecondOfThreeParagraphsInsertsAfter() throws {
        let controller = try EditorController(initialMarkdown: "first\n\nsecond\n\nthird\n")
        controller.testSelection = NSRange(location: 9, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "first\n\nsecond\n\n```\n\n```\n\nthird\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor in a final paragraph without a trailing newline still produces
    /// canonical block separation in the round-tripped markdown.
    @Test func toggleCodeBlockOnLastParagraphNoTrailingNewlineInsertsAfter() throws {
        let controller = try EditorController(initialMarkdown: "first\n\nsecond")
        controller.testSelection = NSRange(location: 10, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "first\n\nsecond\n\n```\n\n```\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor on a paragraph terminator: the cursor's paragraph still gets
    /// the block inserted right after it, with the prose untouched.
    @Test func toggleCodeBlockAtParagraphTerminatorInsertsAfter() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n\nbeta\n")
        controller.testSelection = NSRange(location: 5, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "alpha\n\n```\n\n```\n\nbeta\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor at the start of paragraph 2: insert after that paragraph.
    @Test func toggleCodeBlockAtStartOfSecondParagraphInsertsAfter() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n\nbeta\n")
        controller.testSelection = NSRange(location: 7, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "alpha\n\nbeta\n\n```\n\n```\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor on an empty separator line: this line has no text, so the
    /// "convert" branch fires — the empty line becomes a code block.
    @Test func toggleCodeBlockOnBlankSeparatorLine() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n\nbeta\n")
        // location 6 = the second `\n` (the blank line)
        controller.testSelection = NSRange(location: 6, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "alpha\n\n```\n\n```\n\nbeta\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Selection spanning two consecutive paragraphs: existing text isn't
    /// converted; a fresh empty block lands after the selection's anchor
    /// paragraph.
    @Test func toggleCodeBlockSelectionAcrossTwoParagraphs() throws {
        let controller = try EditorController(initialMarkdown: "alpha\nbeta\n")
        // select "lpha\nbet" — touches both lines
        controller.testSelection = NSRange(location: 1, length: 8)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        #expect(md.contains("alpha\n"), "alpha must remain plain, got \(String(reflecting: md))")
        #expect(md.contains("beta\n"), "beta must remain plain, got \(String(reflecting: md))")
        #expect(md.contains("```\n\n```"),
                "expected empty fence inserted, got \(String(reflecting: md))")
        #expect(!md.contains("```\nalpha"),
                "alpha must not be wrapped, got \(String(reflecting: md))")
        #expect(!md.contains("```\nbeta"),
                "beta must not be wrapped, got \(String(reflecting: md))")
    }

    /// Cursor in a list item: the bullet keeps its body, an empty block is
    /// inserted after it.
    @Test func toggleCodeBlockOnListItemKeepsItemBody() throws {
        let controller = try EditorController(initialMarkdown: "- foo\n")
        controller.testSelection = NSRange(location: 2, length: 0)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        #expect(md.hasPrefix("- foo\n"),
                "list item must remain intact, got \(String(reflecting: md))")
        #expect(md.contains("```\n\n```"),
                "expected empty fence inserted, got \(String(reflecting: md))")
    }

    /// Toggle off again: the fenced block should become a plain paragraph
    /// with the same body.
    @Test func toggleCodeBlockTogglesOffToParagraph() throws {
        let controller = try EditorController(initialMarkdown: "```\nhello\n```\n")
        controller.testSelection = NSRange(location: 5, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "hello\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Toggle off must clear an existing fence — start from a code-block
    /// document, position the cursor inside it, and verify the markdown is
    /// just the body as a paragraph.
    @Test func toggleCodeBlockOffOnExistingFence() throws {
        let controller = try EditorController(initialMarkdown: "```\nhello world\n```\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "hello world\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Multi-line code block: toggling on any one body line should turn the
    /// whole block back into separate paragraphs — *not* split the block in
    /// half (one half code, one half paragraph).
    @Test func toggleCodeBlockOnMiddleLineOfMultilineBlock() throws {
        let controller = try EditorController(initialMarkdown: "```\nline1\nline2\nline3\n```\n")
        // storage strips fences — body is "line1\nline2\nline3\n"
        // cursor on "line2" (middle line)
        let cursor = controller.textStorage.string.range(of: "line2").map {
            controller.textStorage.string.distance(from: controller.textStorage.string.startIndex, to: $0.lowerBound)
        } ?? 0
        controller.testSelection = NSRange(location: cursor, length: 0)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        // After toggling off, the whole block should be plain paragraphs.
        // The bug: only line2 toggles, leaving line1+line3 as fenced halves.
        #expect(!md.contains("```"),
                "expected no fences after toggle-off; got \(String(reflecting: md))")
    }

    /// Cursor on the first line of a multi-line code block: same expectation.
    @Test func toggleCodeBlockOnFirstLineOfMultilineBlock() throws {
        let controller = try EditorController(initialMarkdown: "```\nline1\nline2\nline3\n```\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        #expect(!md.contains("```"),
                "expected no fences after toggle-off; got \(String(reflecting: md))")
    }

    /// Toggle inside a single-line blockquote: the quote keeps its text,
    /// and an empty fenced block lands AFTER the quote (not inside it).
    @Test func toggleCodeBlockOnBlockquoteInsertsAfter() throws {
        let controller = try EditorController(initialMarkdown: "> hello\n")
        controller.testSelection = NSRange(location: 4, length: 0)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        #expect(md.hasPrefix("> hello\n"),
                "blockquote must remain intact, got \(String(reflecting: md))")
        #expect(md.contains("```\n\n```"),
                "expected empty fence inserted, got \(String(reflecting: md))")
        #expect(!md.contains("> ```"),
                "fence must not be quoted, got \(String(reflecting: md))")
    }

    /// Cursor anywhere inside a multi-paragraph doc: prose stays untouched,
    /// the empty block lands after the cursor's paragraph.
    @Test(arguments: [
        // (cursor, expected anchor paragraph the block lands after)
        (0, "first"),    // start of first
        (3, "first"),    // middle of first
        (5, "first"),    // end of first (on `\n`)
        (7, "second"),   // start of second
        (10, "second"),  // middle of second
        (13, "second"),  // end of second (on `\n`)
        (15, "third"),   // start of third
        (17, "third"),   // middle of third
    ])
    func toggleCodeBlockTargetsCursorParagraph(cursor: Int, expected: String) throws {
        let controller = try EditorController(initialMarkdown: "first\n\nsecond\n\nthird\n")
        controller.testSelection = NSRange(location: cursor, length: 0)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        // Existing prose stays as plain paragraphs.
        for word in ["first", "second", "third"] {
            #expect(!md.contains("```\n\(word)\n```"),
                    "cursor=\(cursor) unexpectedly wrapped \(word); got \(String(reflecting: md))")
        }
        // The empty fence lands immediately after the anchor paragraph.
        let needle = "\(expected)\n\n```\n\n```\n"
        #expect(md.contains(needle),
                "cursor=\(cursor) expected empty fence after \(expected); got \(String(reflecting: md))")
    }
}
