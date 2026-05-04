import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct InputRuleTests {

    // MARK: - runner unit tests (no EditorController)

    @Test func runnerOnlyFiresWhenCursorAtMatchEnd() throws {
        let storage = NSTextStorage(string: "# ")
        let runner = InputRuleRunner()
        var fired = false
        runner.register(InputRule(
            id: "test.heading",
            pattern: "^# $"
        ) { _ in
            fired = true
            return Transaction(steps: [])
        })
        let env = StepEnvironment(
            compiler: try MarkdownAttributedCompiler(),
            serializer: AttributedMarkdownSerializer(),
            theme: .default
        )
        // Cursor in the middle of the match — no fire.
        _ = runner.evaluate(storage: storage, cursor: 1, env: env, apply: { _ in })
        #expect(fired == false)
        // Cursor at the match end — fires.
        _ = runner.evaluate(storage: storage, cursor: 2, env: env, apply: { _ in })
        #expect(fired == true)
    }

    @Test func runnerReentrancyGuardBlocksNestedEvaluate() throws {
        let storage = NSTextStorage(string: "# ")
        let runner = InputRuleRunner()
        var outerCalls = 0
        var innerFired = false
        runner.register(InputRule(
            id: "test.heading",
            pattern: "^# $"
        ) { _ in
            outerCalls += 1
            return Transaction(steps: [])
        })
        let env = StepEnvironment(
            compiler: try MarkdownAttributedCompiler(),
            serializer: AttributedMarkdownSerializer(),
            theme: .default
        )
        // Apply closure re-enters evaluate() — the guard must short-circuit.
        let dispatched = runner.evaluate(storage: storage, cursor: 2, env: env) { _ in
            innerFired = runner.evaluate(storage: storage, cursor: 2, env: env, apply: { _ in })
        }
        #expect(dispatched == true)
        #expect(outerCalls == 1)   // outer rule fired once
        #expect(innerFired == false) // re-entrant call returned false
    }

    @Test func runnerExposesCaptureGroups() throws {
        let storage = NSTextStorage(string: "42. ")
        let runner = InputRuleRunner()
        var capturedIndex: String?
        runner.register(InputRule(
            id: "test.ordered",
            pattern: "^(\\d+)\\. $"
        ) { match in
            capturedIndex = match.capture(1)
            return Transaction(steps: [])
        })
        let env = StepEnvironment(
            compiler: try MarkdownAttributedCompiler(),
            serializer: AttributedMarkdownSerializer(),
            theme: .default
        )
        _ = runner.evaluate(storage: storage, cursor: 4, env: env, apply: { _ in })
        #expect(capturedIndex == "42")
    }

    // MARK: - controller integration: block rules

    @Test func typingHashSpaceProducesHeading() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("# ", in: controller)
        #expect(controller.markdown().hasPrefix("# "))
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .heading(level: 1))
    }

    @Test func typingTripleHashSpaceProducesHeading3() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("### ", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .heading(level: 3))
    }

    @Test func typingGreaterThanSpaceProducesBlockquote() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("> ", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.blockquoteDepth == 1)
    }

    /// Bug: typing `> ` produces a blockquote, but the resulting line
    /// contains extra trailing newlines so the next typed character lands
    /// several lines below the quote marker. The line should be a single
    /// `> \n` (length 3) — one blockquote line ready for content.
    @Test func typingGreaterThanSpaceProducesSingleLine() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("> ", in: controller)
        let storage = controller.textStorage
        let text = storage.string
        // The line count (number of newlines) should be exactly one.
        let newlines = text.filter { $0 == "\n" }.count
        #expect(newlines == 1, "expected one trailing newline, got \(newlines) in \(String(reflecting: text))")
        // The body should be a single blockquote line, not a stack of them.
        let firstLineRange = (text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let everyLineSameSpec = storage.blockSpec(at: 0)?.blockquoteDepth == 1
        #expect(everyLineSameSpec)
        #expect(firstLineRange.length == storage.length, "first paragraph should span the whole storage; instead lineLength=\(firstLineRange.length) total=\(storage.length)")
    }

    /// Bug regression: after `> ` fires, typing another character should
    /// land on the same line (one row down from the empty state, NOT three
    /// rows down).
    @Test func typingAfterBlockquoteRuleStaysOnSameLine() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("> ", in: controller)
        type("h", in: controller)
        let storage = controller.textStorage
        // Storage should be `> h\n` — one paragraph, one newline.
        let text = storage.string
        let newlines = text.filter { $0 == "\n" }.count
        #expect(newlines == 1, "expected one newline after `> h`, got \(newlines) in \(String(reflecting: text))")
        // The `h` should be on the same line as the `> ` marker.
        let ns = text as NSString
        let lineCovering = ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0))
        // Whole content should be one paragraph.
        #expect(lineCovering.length == ns.length, "expected `h` on same line as `>`; got line range \(lineCovering) total=\(ns.length)")
    }

    /// After the blockquote rule fires, the cursor returned by `apply`
    /// must land at the start of the new blockquote line — position 0 in
    /// the empty-storage case. If it lands elsewhere (past the `\n`, or at
    /// some pre-rule offset), subsequent typing goes on the wrong line.
    @Test func blockquoteRuleLandsCursorAtStartOfBlockquoteLine() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("> ", in: controller)
        // Storage is `\n` length 1; the blockquote line is the only paragraph.
        let storage = controller.textStorage
        #expect(storage.length == 1)
        // Cursor (testSelection, which our test helper updates from apply's
        // returned range) should be at position 0 — before the trailing
        // newline that terminates the empty blockquote line.
        let cursor = controller.testSelection
        #expect(cursor?.location == 0, "expected cursor at start of blockquote line; got \(String(describing: cursor))")
    }

    /// `> ` typed after existing content should produce a blockquote line
    /// with no extra blank paragraphs between it and the previous line.
    @Test func blockquoteRuleAfterExistingContentProducesAdjacentLine() throws {
        let controller = try EditorController(initialMarkdown: "Hello\n")
        // Place cursor at end of storage (after the trailing \n).
        let initialLength = controller.textStorage.length
        controller.testSelection = NSRange(location: initialLength, length: 0)
        type("> ", in: controller)
        let storage = controller.textStorage
        let text = storage.string
        // Two newlines: end-of-line for "Hello" plus end-of-line for the
        // empty blockquote line. NOT four (which would indicate extra
        // blank lines were inserted).
        let newlines = text.filter { $0 == "\n" }.count
        #expect(newlines == 2, "expected 2 newlines after Hello+blockquote, got \(newlines) in \(String(reflecting: text))")
        // First line is paragraph; second line is blockquote.
        #expect(storage.blockSpec(at: 0)?.kind == .paragraph)
        #expect(storage.blockSpec(at: 0)?.blockquoteDepth == 0)
        let secondLineStart = (text as NSString).range(of: "\n").location + 1
        #expect(storage.blockSpec(at: secondLineStart)?.blockquoteDepth == 1)
    }

    @Test func typingDashSpaceProducesUnorderedList() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("- ", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .unorderedListItem)
    }

    @Test func typingNumberDotSpaceProducesOrderedList() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("1. ", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        if case .orderedListItem(let index) = spec?.kind {
            #expect(index == 1)
        } else {
            Issue.record("expected ordered list, got \(String(describing: spec?.kind))")
        }
    }

    @Test func typingTaskListShorthandProducesTaskItem() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("- [ ] ", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        if case .taskListItem(let checked) = spec?.kind {
            #expect(checked == false)
        } else {
            Issue.record("expected task list, got \(String(describing: spec?.kind))")
        }
    }

    @Test func typingCheckedTaskListShorthandProducesCheckedTaskItem() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("- [x] ", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        if case .taskListItem(let checked) = spec?.kind {
            #expect(checked == true)
        } else {
            Issue.record("expected checked task list, got \(String(describing: spec?.kind))")
        }
    }

    // MARK: - controller integration: inline rules

    @Test func typingDoubleStarBoldStarStarStylesInline() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("**bold**", in: controller)
        let md = controller.markdown()
        #expect(md.contains("**bold**"))
        // The compiler should have applied bold font to the inner text.
        let storage = controller.textStorage
        let innerLocation = 2  // after the leading "**"
        let font = storage.safeAttribute(.font, at: innerLocation) as? PlatformFont
        #expect(font != nil)
        #if canImport(AppKit) && os(macOS)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #else
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #endif
    }

    @Test func typingTildeStrikeTildeStylesInline() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("~~done~~", in: controller)
        let storage = controller.textStorage
        let innerLocation = 2
        let strikethrough = storage.safeAttribute(.strikethroughStyle, at: innerLocation) as? Int
        #expect(strikethrough != nil)
    }

    @Test func typingBacktickCodeBacktickStylesInline() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("`code`", in: controller)
        let storage = controller.textStorage
        let innerLocation = 1
        let inline = storage.safeAttribute(.proseInline, at: innerLocation) as? InlineTag
        #expect(inline == .codeSpan)
    }

    // MARK: - trigger gating

    @Test func setMarkdownDoesNotFireInputRules() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.setMarkdown("# heading\n")
        // setMarkdown takes the single-step compile path. The line should
        // already be a heading because it was compiled, not because a rule
        // fired. Either way, no double-application should have happened.
        let md = controller.markdown()
        #expect(md == "# heading\n" || md == "# heading")
    }

    @Test func multiCharacterPasteDoesNotFireInputRules() throws {
        let controller = try EditorController(initialMarkdown: "")
        let storage = controller.textStorage
        // Simulate paste: insert multiple characters in one edit cycle.
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                  with: NSAttributedString(string: "# pasted"))
        storage.endEditing()
        let spec = controller.textStorage.blockSpec(at: 0)
        // The rule must NOT fire on multi-char insert. The line stays a
        // paragraph containing the literal `# pasted` text.
        #expect(spec?.kind == .paragraph)
    }

    // MARK: - undo

    @Test func undoAfterHeadingRuleRestoresPlainTextAndParagraph() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("# ", in: controller)
        // Heading is now applied.
        #expect(controller.textStorage.blockSpec(at: 0)?.kind == .heading(level: 1))
        controller.undoManager.undo()
        // After undo, the rule's transaction is reversed. The line should
        // be back to a paragraph containing `# `.
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .paragraph)
    }

    // MARK: - helpers

    private func type(_ chars: String, in controller: EditorController) {
        for char in chars {
            insertSingleCharacter(String(char), in: controller)
        }
    }

    /// Simulate a single keystroke. Sets `testSelection` to the post-typing
    /// cursor position *before* `endEditing` so the storage observer's
    /// `evaluateInputRules` reads the right cursor — that's what a real
    /// host text view would have done before posting `didProcessEditing`.
    /// If a rule fires and re-renders the line (changing storage length),
    /// reposition the cursor to the end of the rendered content.
    private func insertSingleCharacter(_ char: String, in controller: EditorController) {
        let selection = controller.testSelection ?? NSRange(location: 0, length: 0)
        let storage = controller.textStorage
        let typedLength = (char as NSString).length
        let preLength = storage.length
        storage.beginEditing()
        storage.replaceCharacters(in: selection, with: char)
        controller.testSelection = NSRange(
            location: selection.location + typedLength,
            length: 0
        )
        storage.endEditing()
        // Input rules dispatch synchronously when no host text view is
        // attached (the headless path used by these tests). When a host
        // is attached they defer to the next runloop tick to avoid mid-
        // edit reentry into NSTextView/UITextView.
        // If a rule re-rendered the line, the storage length jumped beyond
        // the typed length. Place cursor at end of content (before any
        // trailing newline) so subsequent typed chars land in the right
        // spot.
        let postLength = storage.length
        if postLength != preLength + typedLength {
            let ns = storage.string as NSString
            let cursorPos = postLength > 0 && ns.character(at: postLength - 1) == 0x0A
                ? postLength - 1
                : postLength
            controller.testSelection = NSRange(location: cursorPos, length: 0)
        }
    }
}
