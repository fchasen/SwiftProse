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

    // MARK: - code block: cursor-position consistency

    /// Cursor anywhere inside a single paragraph should produce identical
    /// markdown — the line is what matters, not the column.
    @Test(arguments: [0, 1, 3, 5, 6])
    func toggleCodeBlockIsStableAcrossCursorColumns(cursor: Int) throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: cursor, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "```\nhello\n```\n",
                "cursor=\(cursor) produced \(String(reflecting: controller.markdown()))")
    }

    /// Multi-paragraph document: cursor in the second paragraph should
    /// fence only that paragraph and leave the others untouched.
    @Test func toggleCodeBlockOnSecondOfThreeParagraphs() throws {
        let controller = try EditorController(initialMarkdown: "first\n\nsecond\n\nthird\n")
        // "first\n\nsecond" — cursor inside "second"
        controller.testSelection = NSRange(location: 9, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "first\n\n```\nsecond\n```\n\nthird\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor in the third paragraph — the one without a trailing newline
    /// before EOF was a likely off-by-one in `paragraphRanges`.
    @Test func toggleCodeBlockOnLastParagraphNoTrailingNewline() throws {
        let controller = try EditorController(initialMarkdown: "first\n\nsecond")
        // cursor inside "second"
        controller.testSelection = NSRange(location: 10, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "first\n\n```\nsecond\n```\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor on the line break between two paragraphs — the user's intent
    /// is on the visible paragraph the cursor *is currently in*. Whether
    /// that's the line the `\n` terminates or the empty line that follows,
    /// the behavior must be deterministic.
    @Test func toggleCodeBlockAtParagraphTerminator() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n\nbeta\n")
        // position 5 = the `\n` after "alpha" (still in line 1 per NSString)
        controller.testSelection = NSRange(location: 5, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "```\nalpha\n```\n\nbeta\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor at the start of paragraph 2 (index 7 in "alpha\n\nbeta\n").
    @Test func toggleCodeBlockAtStartOfSecondParagraph() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n\nbeta\n")
        controller.testSelection = NSRange(location: 7, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "alpha\n\n```\nbeta\n```\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Cursor on the empty separator line between two paragraphs. There's no
    /// "right" answer at this position, but the behavior must be stable —
    /// pin it so it can't silently regress.
    @Test func toggleCodeBlockOnBlankSeparatorLine() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n\nbeta\n")
        // location 6 = the second `\n` (the blank line)
        controller.testSelection = NSRange(location: 6, length: 0)
        _ = controller.perform(.codeBlock)
        // The blank line itself becomes an empty fenced block sandwiched
        // between the two paragraphs.
        #expect(controller.markdown() == "alpha\n\n```\n\n```\n\nbeta\n",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// Selection spanning two consecutive paragraphs should fence both.
    @Test func toggleCodeBlockSelectionAcrossTwoParagraphs() throws {
        let controller = try EditorController(initialMarkdown: "alpha\nbeta\n")
        // select "lpha\nbet" — touches both lines
        controller.testSelection = NSRange(location: 1, length: 8)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        #expect(md.contains("```\nalpha\n```"),
                "expected first line fenced, got \(String(reflecting: md))")
        #expect(md.contains("```\nbeta\n```"),
                "expected second line fenced, got \(String(reflecting: md))")
    }

    /// Toggle on a list item: the line should leave the list and become a
    /// fenced code block whose body is the bullet's body, not "- foo".
    @Test func toggleCodeBlockOnListItemKeepsItemBody() throws {
        let controller = try EditorController(initialMarkdown: "- foo\n")
        controller.testSelection = NSRange(location: 2, length: 0)
        _ = controller.perform(.codeBlock)
        #expect(controller.markdown() == "```\nfoo\n```\n",
                "got \(String(reflecting: controller.markdown()))")
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

    /// Round-trip: toggle on, then off, must restore the original line.
    @Test func toggleCodeBlockRoundTripRestoresParagraph() throws {
        let controller = try EditorController(initialMarkdown: "hello world\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.codeBlock)
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

    /// Toggle on a single-line blockquote should produce a fenced block
    /// not still inside the quote (we don't support quoted-code), and the
    /// body must not include the leading `> `.
    @Test func toggleCodeBlockOnBlockquoteStripsQuoteMarker() throws {
        let controller = try EditorController(initialMarkdown: "> hello\n")
        controller.testSelection = NSRange(location: 4, length: 0)
        _ = controller.perform(.codeBlock)
        let md = controller.markdown()
        #expect(!md.contains("> ```"),
                "fenced block must not be quoted; got \(String(reflecting: md))")
        #expect(md.contains("```\nhello\n```"),
                "expected stripped body fenced; got \(String(reflecting: md))")
    }

    /// Cursor anywhere inside a multi-paragraph doc must fence the *line
    /// the cursor is on*, never the wrong line. Drives a wide range of
    /// cursor positions through the same setup and verifies the right
    /// paragraph (and only that one) is fenced.
    @Test(arguments: [
        // (cursor, expected fenced paragraph)
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
        let expectedFence = "```\n\(expected)\n```"
        #expect(md.contains(expectedFence),
                "cursor=\(cursor) expected to fence \(expected); got \(String(reflecting: md))")
        // The other two paragraphs must remain plain text.
        for other in ["first", "second", "third"] where other != expected {
            #expect(!md.contains("```\n\(other)\n```"),
                    "cursor=\(cursor) unexpectedly fenced \(other); got \(String(reflecting: md))")
        }
    }
}
