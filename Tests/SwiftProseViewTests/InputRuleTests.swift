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

    @Test func completingInlineCodeDoesNotAppendANewLine() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("`code`", in: controller)

        let text = controller.textStorage.string
        #expect(text == "code", "expected inline code re-render to preserve unterminated line, got \(String(reflecting: text))")
    }

    @Test func completingInlineCodeBeforeFollowingLineKeepsExistingLineBreak() throws {
        let controller = try EditorController(initialMarkdown: "hello \nnext\n")
        controller.testSelection = NSRange(location: 6, length: 0)
        type("`code`", in: controller)

        let text = controller.textStorage.string
        #expect(text == "hello code\nnext\n")
        #expect((text.filter { $0 == "\n" }).count == 2)
    }

    @Test func typingOpeningBacktickDoesNotCreateAnotherLine() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 5, length: 0)
        type(" `", in: controller)

        let text = controller.textStorage.string
        let newlines = text.filter { $0 == "\n" }.count
        #expect(newlines == 1, "expected one newline after opening inline code, got \(newlines) in \(String(reflecting: text))")
        #expect(controller.textStorage.blockSpec(at: 0)?.kind == .paragraph)
    }

    @Test func typingOpeningBacktickBeforeFollowingLineDoesNotInsertBlankLine() throws {
        let controller = try EditorController(initialMarkdown: "hello\nnext\n")
        controller.testSelection = NSRange(location: 5, length: 0)
        type(" `", in: controller)

        let text = controller.textStorage.string
        let newlines = text.filter { $0 == "\n" }.count
        #expect(newlines == 2, "expected existing two newlines, got \(newlines) in \(String(reflecting: text))")
        #expect(text == "hello `\nnext\n")
    }

    @Test func roundTrippingOpeningBacktickDoesNotCreateAnotherLine() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 5, length: 0)
        type(" `", in: controller)

        let markdown = controller.markdown()
        controller.setMarkdown(markdown, async: false)

        let text = controller.textStorage.string
        let newlines = text.filter { $0 == "\n" }.count
        #expect(markdown == "hello `")
        #expect(newlines == 1, "expected one newline after markdown round trip, got \(newlines) in \(String(reflecting: text))")
    }

    #if canImport(AppKit) && os(macOS)
    @MainActor
    @Test func deferredOpeningBacktickDoesNotCreateAnotherLine() async throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let textView = NSTextView(frame: .zero, textContainer: controller.textContainer)
        controller.hostTextView = textView
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        typeThroughHost(" `", controller: controller, textView: textView)
        try await Task.sleep(nanoseconds: 50_000_000)

        let text = controller.textStorage.string
        let newlines = text.filter { $0 == "\n" }.count
        #expect(newlines == 1, "expected one newline after deferred opening inline code, got \(newlines) in \(String(reflecting: text))")
    }

    @MainActor
    @Test func deferredCompletingInlineCodeDoesNotAppendANewLine() async throws {
        let controller = try EditorController(initialMarkdown: "")
        let textView = NSTextView(frame: .zero, textContainer: controller.textContainer)
        controller.hostTextView = textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        typeThroughHost("`code`", controller: controller, textView: textView)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(controller.textStorage.string == "code")
        #expect(textView.selectedRange().location == 4)
    }
    #endif

    // MARK: - controller integration: inline rules, mid-line

    /// The delimiters are deleted and the capture is marked; nothing else
    /// on the line is re-rendered.
    @Test func inlineRulesMidLineMarkTheCaptureAndConsumeTheDelimiters() throws {
        let cases: [(trigger: String, mark: String, markdown: String)] = [
            ("**x**", "strong", "alpha **x**beta gamma"),
            ("*x*", "em", "alpha *x*beta gamma"),
            ("~~x~~", "strike", "alpha ~~x~~beta gamma"),
            ("`x`", "code", "alpha `x`beta gamma")
        ]
        for (trigger, mark, markdown) in cases {
            let controller = try EditorController(initialMarkdown: "alpha beta gamma\n")
            controller.testSelection = NSRange(location: 6, length: 0)
            type(trigger, in: controller)
            #expect(controller.textStorage.string == "alpha xbeta gamma\n",
                    "\(trigger) left \(String(reflecting: controller.textStorage.string))")
            #expect(marks(in: controller, at: 6) == [mark],
                    "\(trigger) stamped \(marks(in: controller, at: 6))")
            #expect(marks(in: controller, at: 7) == [],
                    "\(trigger) leaked onto the character after the capture")
            #expect(controller.markdown() == markdown,
                    "\(trigger) serialized \(String(reflecting: controller.markdown()))")
        }
    }

    /// Reloading the emitted markdown emits the same markdown.
    @Test func inlineRulesMidLineLeaveAMarkdownFixpoint() throws {
        for trigger in ["**x**", "*x*", "~~x~~", "`x`"] {
            let controller = try EditorController(initialMarkdown: "alpha beta gamma\n")
            controller.testSelection = NSRange(location: 6, length: 0)
            type(trigger, in: controller)
            let markdown = controller.markdown()
            let reloaded = try EditorController(initialMarkdown: markdown)
            #expect(reloaded.markdown() == markdown,
                    "\(trigger) round-tripped \(String(reflecting: markdown)) to \(String(reflecting: reloaded.markdown()))")
        }
    }

    /// Underscore emphasis has no input rule, so `_em_` sits in storage
    /// literally. A rule firing later on the line must not consume it.
    @Test func inlineRuleKeepsLiteralMarkupAheadOfTheMatch() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        type("see _em_ ", in: controller)
        #expect(controller.textStorage.string == "see _em_ ")
        type("`x`", in: controller)
        #expect(controller.textStorage.string == "see _em_ x",
                "expected the underscores to survive, got \(String(reflecting: controller.textStorage.string))")
        #expect(controller.markdown() == "see _em_ `x`",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// A line whose text literally starts with `> ` — written straight
    /// into storage, so the marker is content rather than a spec — keeps
    /// those characters when a rule fires on it.
    @Test func inlineRuleKeepsALiteralQuoteMarkerOnTheLine() throws {
        let controller = try EditorController(initialMarkdown: "")
        let storage = controller.textStorage
        controller.proseStorage.withOrigin(.load) {
            storage.replaceCharacters(
                in: NSRange(location: 0, length: 0),
                with: NSAttributedString(string: "> alpha beta")
            )
        }
        controller.testSelection = NSRange(location: 8, length: 0)
        type("`x`", in: controller)
        #expect(controller.textStorage.string == "> alpha xbeta",
                "expected the literal marker to survive, got \(String(reflecting: controller.textStorage.string))")
        #expect(controller.markdown() == "> alpha `x`beta")
    }

    /// A rule firing on the second line of a soft-broken paragraph leaves
    /// one block. The delimiters are written under `.load` so the envelope
    /// pipeline plays no part — this pins the rule's own steps.
    @Test func inlineRuleOnASoftBrokenParagraphKeepsOneBlock() throws {
        let controller = try EditorController(initialMarkdown: "one two\nthree four\n")
        let storage = controller.textStorage
        let four = (storage.string as NSString).range(of: "four").location
        let donor = storage.attributes(at: four, effectiveRange: nil)
        controller.proseStorage.withOrigin(.load) {
            storage.replaceCharacters(
                in: NSRange(location: four, length: 0),
                with: NSAttributedString(string: "`x`", attributes: donor)
            )
        }
        controller.testSelection = NSRange(location: four + 3, length: 0)
        #expect(controller.evaluateInputRules() == true)
        #expect(controller.textStorage.string == "one two\nthree xfour\n")
        #expect(marks(in: controller, at: four) == ["code"])
        #expect(controller.markdown() == "one two\nthree `x`four",
                "expected one paragraph over two lines, got \(String(reflecting: controller.markdown()))")
        guard case .structural(_, let blocks) = controller.document.root else {
            Issue.record("expected a structural root")
            return
        }
        #expect(blocks.count == 1, "expected one top-level block, got \(blocks.count)")
    }

    /// `code` is `excludesAll`, so marking a strong span as code drops the
    /// strong mark rather than nesting the two.
    @Test func codeSpanRuleOverAStrongSpanExcludesStrong() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        type("**bold**", in: controller)
        #expect(marks(in: controller, at: 0) == ["strong"])
        controller.testSelection = NSRange(location: 0, length: 0)
        type("`", in: controller)
        controller.testSelection = NSRange(location: controller.textStorage.length, length: 0)
        type("`", in: controller)
        #expect(controller.textStorage.string == "bold")
        #expect(marks(in: controller, at: 0) == ["code"],
                "expected code to exclude strong, got \(marks(in: controller, at: 0))")
        #expect(controller.markdown() == "`bold`")
    }

    /// The mark lands inside a nested list item too, delimiters gone.
    @Test func inlineRuleInsideANestedListItemAppliesTheMark() throws {
        let controller = try EditorController(initialMarkdown: "- alpha\n  - beta gamma\n")
        let gamma = (controller.textStorage.string as NSString).range(of: "gamma").location
        #expect(controller.textStorage.blockSpec(at: gamma)?.listLevel == 1)
        controller.testSelection = NSRange(location: gamma, length: 0)
        type("`x`", in: controller)
        #expect(controller.textStorage.string == "\u{FFFC} alpha\n\u{FFFC} beta xgamma\n",
                "expected the delimiters gone, got \(String(reflecting: controller.textStorage.string))")
        #expect(marks(in: controller, at: gamma) == ["code"],
                "expected the code mark inside a nested item, got \(marks(in: controller, at: gamma))")
        #expect(controller.markdown() == "- alpha\n  - beta `x`gamma")
    }

    /// The rule is its own undo unit: one undo puts the delimiters back
    /// and takes the mark off.
    @Test func undoAfterAnInlineRuleRestoresTheDelimitersAndDropsTheMark() throws {
        let controller = try EditorController(initialMarkdown: "alpha beta gamma\n")
        controller.testSelection = NSRange(location: 6, length: 0)
        type("**x**", in: controller)
        #expect(controller.textStorage.string == "alpha xbeta gamma\n")
        controller.undoManager.undo()
        #expect(controller.textStorage.string == "alpha **x**beta gamma\n",
                "got \(String(reflecting: controller.textStorage.string))")
        #expect(marks(in: controller, at: 8) == [],
                "expected no mark after undo, got \(marks(in: controller, at: 8))")
    }

    /// `addMark`'s typed inverse only removes its own type, so a mark the
    /// new one excluded has to come off as its own `removeMark` step —
    /// that inverse re-adds it, and undo to the bottom lands on the
    /// document that was loaded.
    @Test func undoAfterAnInlineRuleRestoresAMarkTheNewOneExcluded() throws {
        let controller = try EditorController(initialMarkdown: "hello **bold** world")
        #expect(marks(in: controller, at: 6) == ["strong"])
        wrapInBackticks("bold", in: controller)
        #expect(marks(in: controller, at: 6) == ["code"],
                "expected code to exclude strong, got \(marks(in: controller, at: 6))")
        #expect(controller.markdown() == "hello `bold` world")
        undoToTheBottom(controller)
        #expect(controller.textStorage.string == "hello bold world\n",
                "got \(String(reflecting: controller.textStorage.string))")
        #expect(marks(in: controller, at: 6) == ["strong"],
                "expected strong back, got \(marks(in: controller, at: 6))")
        #expect(controller.markdown() == "hello **bold** world",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// The restored mark keeps its attrs — `removeMark` captures the
    /// placement it took off, href and all.
    @Test func undoAfterAnInlineRuleRestoresALinkWithItsHref() throws {
        let controller = try EditorController(initialMarkdown: "[lbl](https://e.com)")
        #expect(mark("link", in: controller, at: 0)?.attrs["href"]?.stringValue == "https://e.com")
        wrapInBackticks("lbl", in: controller)
        #expect(marks(in: controller, at: 0) == ["code"])
        undoToTheBottom(controller)
        #expect(marks(in: controller, at: 0) == ["link"],
                "expected the link back, got \(marks(in: controller, at: 0))")
        #expect(mark("link", in: controller, at: 0)?.attrs["href"]?.stringValue == "https://e.com",
                "expected the href back, got \(String(describing: mark("link", in: controller, at: 0)?.attrs))")
        #expect(controller.markdown() == "[lbl](https://e.com)",
                "got \(String(reflecting: controller.markdown()))")
    }

    /// A dropped mark takes its rendering projection with it. `code` over
    /// a struck run must not keep painting the strikethrough, and over a
    /// link must not keep the link's URL or underline.
    @Test func aMarkTheNewOneExcludedLeavesNoRenderingAttribute() throws {
        let struck = try EditorController(initialMarkdown: "~~s~~ tail")
        #expect(marks(in: struck, at: 0) == ["strike"])
        #expect(struck.textStorage.safeAttribute(.strikethroughStyle, at: 0) != nil)
        wrapInBackticks("s", in: struck)
        #expect(marks(in: struck, at: 0) == ["code"])
        #expect(struck.textStorage.safeAttribute(.strikethroughStyle, at: 0) == nil,
                "strikethrough survived under code: \(String(describing: struck.textStorage.safeAttribute(.strikethroughStyle, at: 0)))")

        let linked = try EditorController(initialMarkdown: "[lbl](https://e.com)")
        #expect(linked.textStorage.safeAttribute(.proseLink, at: 0) != nil)
        wrapInBackticks("lbl", in: linked)
        #expect(marks(in: linked, at: 0) == ["code"])
        #expect(linked.textStorage.safeAttribute(.proseLink, at: 0) == nil,
                "proseLink survived under code: \(String(describing: linked.textStorage.safeAttribute(.proseLink, at: 0)))")
        #expect(linked.textStorage.safeAttribute(.underlineStyle, at: 0) == nil,
                "underline survived under code: \(String(describing: linked.textStorage.safeAttribute(.underlineStyle, at: 0)))")
    }

    /// An emphasis capture that opens or closes on whitespace compiles to
    /// literal text, so the rule leaves the typed characters alone. A code
    /// span keeps its padding verbatim, so there it fires.
    @Test func inlineRuleFlankingMatchesTheCompiler() throws {
        for trigger in ["** **", "**  **", "**x **", "** x **", "*  *", "~~x ~~"] {
            let controller = try EditorController(initialMarkdown: "alpha beta gamma\n")
            controller.testSelection = NSRange(location: 6, length: 0)
            type(trigger, in: controller)
            #expect(controller.textStorage.string == "alpha \(trigger)beta gamma\n",
                    "\(trigger) left \(String(reflecting: controller.textStorage.string))")
            #expect(allMarks(in: controller) == [],
                    "\(trigger) marked \(allMarks(in: controller))")
        }
        for (trigger, storage, marked) in [
            ("` x `", "alpha  x beta gamma\n", NSRange(location: 6, length: 3)),
            ("` `", "alpha  beta gamma\n", NSRange(location: 6, length: 1))
        ] {
            let controller = try EditorController(initialMarkdown: "alpha beta gamma\n")
            controller.testSelection = NSRange(location: 6, length: 0)
            type(trigger, in: controller)
            #expect(controller.textStorage.string == storage,
                    "\(trigger) left \(String(reflecting: controller.textStorage.string))")
            #expect(allMarks(in: controller) == ["code@\(marked.location),\(marked.length)"],
                    "\(trigger) marked \(allMarks(in: controller))")
            #expect(controller.markdown() == "alpha \(trigger)beta gamma",
                    "\(trigger) serialized \(String(reflecting: controller.markdown()))")
        }
    }

    // MARK: - fenced code block

    /// Typing ` ```Enter ` opens an empty fenced code block. The rule waits
    /// for the newline so the user can type a language tag first.
    @Test func typingTripleBacktickThenEnterOpensEmptyFencedBlock() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("```\n", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        guard case .fencedCode(let lang) = spec?.kind else {
            Issue.record("expected fenced code spec, got \(String(describing: spec?.kind))")
            return
        }
        #expect(lang == nil)
        // Storage holds the empty body (`\n`) plus the trailing-paragraph
        // sentinel that lets the user move past atomic blocks.
        #expect(controller.textStorage.length == 2)
        let trailing = controller.textStorage.blockSpec(at: 1)
        #expect(trailing?.kind == .paragraph,
                "expected trailing paragraph sentinel, got \(String(describing: trailing?.kind))")
    }

    /// Typing ` ```js ` then Enter opens a fenced block with language "js".
    @Test func typingFenceWithLanguageCapturesLanguage() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("```js\n", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        guard case .fencedCode(let lang) = spec?.kind else {
            Issue.record("expected fenced code spec, got \(String(describing: spec?.kind))")
            return
        }
        #expect(lang == "js")
    }

    /// Typing only ` ``` ` (no Enter) leaves the line as a plain paragraph —
    /// the rule waits for the newline that signals the user is done typing.
    @Test func typingTripleBacktickAloneStaysParagraph() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("```", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        #expect(spec?.kind == .paragraph)
    }

    /// The rule bails when the line is already a fenced block — typing
    /// ` ```\n ` to "close" an unclosed fence above must not splice a fresh
    /// block on top.
    @Test func fencedCodeRuleBailsWhenLineAlreadyFenced() throws {
        let storage = NSTextStorage(string: "```\n")
        let spec = BlockSpec(kind: .fencedCode(language: "swift"))
        storage.setBlockSpec(spec, in: NSRange(location: 0, length: storage.length))
        let runner = InputRuleRunner(rules: [InputRule.fencedCodeBlock])
        let env = StepEnvironment(
            compiler: try MarkdownAttributedCompiler(),
            serializer: AttributedMarkdownSerializer(),
            theme: .default
        )
        var dispatched = false
        let fired = runner.evaluate(storage: storage, cursor: 4, env: env) { _ in
            dispatched = true
        }
        #expect(fired == false)
        #expect(dispatched == false)
    }

    /// Sanity check: same input, but with the line classified as a
    /// paragraph. The rule fires and dispatches a transaction.
    @Test func fencedCodeRuleFiresOnPlainParagraphLine() throws {
        let storage = NSTextStorage(string: "```\n")
        let spec = BlockSpec(kind: .paragraph)
        storage.setBlockSpec(spec, in: NSRange(location: 0, length: storage.length))
        let runner = InputRuleRunner(rules: [InputRule.fencedCodeBlock])
        let env = StepEnvironment(
            compiler: try MarkdownAttributedCompiler(),
            serializer: AttributedMarkdownSerializer(),
            theme: .default
        )
        var dispatched = false
        let fired = runner.evaluate(storage: storage, cursor: 4, env: env) { _ in
            dispatched = true
        }
        #expect(fired == true)
        #expect(dispatched == true)
    }

    /// Enter on a paragraph that *isn't* a `` ```<lang> `` shape must fall
    /// through to the default Enter handling (no fenced conversion).
    @Test func enterOnPlainParagraphDoesNotOpenFencedBlock() throws {
        let controller = try EditorController(initialMarkdown: "")
        type("hello", in: controller)
        controller.testSelection = NSRange(location: 5, length: 0)
        _ = controller.handleNewline()
        // The line is still a paragraph.
        #expect(controller.textStorage.blockSpec(at: 0)?.kind == .paragraph)
    }

    /// Pasted ` ```swift ` followed by Enter — the multi-char insert skips
    /// the rule, but the trailing single-char Enter then triggers it and
    /// the captured language survives into the leaf attrs.
    @Test func pastedLanguageTagThenEnterCapturesLanguage() throws {
        let controller = try EditorController(initialMarkdown: "")
        let storage = controller.textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                  with: NSAttributedString(string: "```swift"))
        storage.endEditing()
        #expect(storage.blockSpec(at: 0)?.kind == .paragraph)

        controller.testSelection = NSRange(location: 8, length: 0)
        type("\n", in: controller)
        let spec = controller.textStorage.blockSpec(at: 0)
        guard case .fencedCode(let lang) = spec?.kind else {
            Issue.record("expected fenced code spec after Enter, got \(String(describing: spec?.kind))")
            return
        }
        #expect(lang == "swift")
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

    /// A typed code span derives its font from the block's base run, the
    /// way the compiler does. In a heading that is heading-sized and bold;
    /// the whole-line recompile used to get this free from the compiler.
    @Test func typedCodeSpanInAHeadingKeepsTheHeadingFont() throws {
        let theme = ProseTheme.default
        let controller = try EditorController(initialMarkdown: "# Title code end\n", theme: theme)
        wrapInBackticks("code", in: controller)
        let at = (controller.textStorage.string as NSString).range(of: "code").location
        let font = try #require(
            controller.textStorage.attribute(.font, at: at, effectiveRange: nil) as? PlatformFont
        )
        let expected = theme.bodyFont.pointSize * (theme.headingScale[1] ?? 1.0)
        #expect(font.isMonospace, "got \(font.fontName)")
        #expect(abs(font.pointSize - expected) < 0.01,
                "expected heading size \(expected), got \(font.pointSize)")
        let compiled = try EditorController(initialMarkdown: "# Title `code` end\n", theme: theme)
        let compiledFont = try #require(
            compiled.textStorage.attribute(
                .font,
                at: (compiled.textStorage.string as NSString).range(of: "code").location,
                effectiveRange: nil
            ) as? PlatformFont
        )
        #expect(font.pointSize == compiledFont.pointSize,
                "typed \(font.pointSize) vs compiled \(compiledFont.pointSize)")
        #expect(font.fontName == compiledFont.fontName,
                "typed \(font.fontName) vs compiled \(compiledFont.fontName)")
    }

    /// Undoing the rule restores the heading's own font, not the body font.
    @Test func undoOfACodeSpanInAHeadingRestoresTheHeadingFont() throws {
        let theme = ProseTheme.default
        let controller = try EditorController(initialMarkdown: "# Title code end\n", theme: theme)
        let before = try #require(
            controller.textStorage.attribute(
                .font,
                at: (controller.textStorage.string as NSString).range(of: "code").location,
                effectiveRange: nil
            ) as? PlatformFont
        )
        wrapInBackticks("code", in: controller)
        undoToTheBottom(controller)
        let at = (controller.textStorage.string as NSString).range(of: "code").location
        let after = try #require(
            controller.textStorage.attribute(.font, at: at, effectiveRange: nil) as? PlatformFont
        )
        #expect(after.pointSize == before.pointSize,
                "expected \(before.pointSize) back, got \(after.pointSize)")
        #expect(after.fontName == before.fontName,
                "expected \(before.fontName) back, got \(after.fontName)")
    }

    private func marks(in controller: EditorController, at location: Int) -> [MarkType.Name] {
        let box = controller.textStorage.safeAttribute(.proseMarks, at: location) as? MarkSetBox
        return (box?.marks.marks ?? []).map(\.type)
    }

    private func mark(
        _ type: MarkType.Name,
        in controller: EditorController,
        at location: Int
    ) -> ProseMark? {
        let box = controller.textStorage.safeAttribute(.proseMarks, at: location) as? MarkSetBox
        return box?.marks.mark(of: type)
    }

    /// Every mark on the document as `type@location,length`.
    private func allMarks(in controller: EditorController) -> [String] {
        let storage = controller.textStorage
        var found: [String] = []
        storage.enumerateAttribute(
            .proseMarks,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, _ in
            for mark in (value as? MarkSetBox)?.marks.marks ?? [] {
                found.append("\(mark.type)@\(range.location),\(range.length)")
            }
        }
        return found
    }

    /// Types a backtick before and after `substring`, closing the pair so
    /// the code-span rule fires.
    private func wrapInBackticks(_ substring: String, in controller: EditorController) {
        let opening = (controller.textStorage.string as NSString).range(of: substring)
        controller.testSelection = NSRange(location: opening.location, length: 0)
        type("`", in: controller)
        let closing = (controller.textStorage.string as NSString).range(of: substring)
        controller.testSelection = NSRange(location: closing.location + closing.length, length: 0)
        type("`", in: controller)
    }

    private func undoToTheBottom(_ controller: EditorController, limit: Int = 16) {
        var steps = 0
        while controller.undoManager.canUndo, steps < limit {
            controller.undoManager.undo()
            steps += 1
        }
    }

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

    #if canImport(AppKit) && os(macOS)
    @MainActor
    private func typeThroughHost(_ chars: String, controller: EditorController, textView: NSTextView) {
        for char in chars {
            let selection = textView.selectedRange()
            let typedLength = (String(char) as NSString).length
            let storage = controller.textStorage
            storage.beginEditing()
            storage.replaceCharacters(in: selection, with: String(char))
            textView.setSelectedRange(NSRange(location: selection.location + typedLength, length: 0))
            storage.endEditing()
        }
    }
    #endif
}
