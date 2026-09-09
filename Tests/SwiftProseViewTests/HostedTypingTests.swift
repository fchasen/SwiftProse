import XCTest
import SwiftUI
import SwiftProseSyntax
@testable import SwiftProseView

#if canImport(AppKit) && os(macOS)
import AppKit

/// Types through `NSTextView.insertText` — AppKit's own input path, undo
/// coalescing included — instead of writing to storage. Storage writes
/// skip everything the view does around an edit.
///
/// XCTest, not Swift Testing: `swift test` runs this phase serially and
/// before the parallel Swift Testing phase. Driving AppKit on the main
/// thread while other suites allocate on background threads trips the
/// allocator's consistency check on current macOS; this suite needs the
/// process to itself.
@MainActor
final class HostedTypingTests: XCTestCase {

    private struct Host {
        let controller: EditorController
        let textView: ProseNSTextView
        let coordinator: ProseTextViewMac.Coordinator
    }

    /// Mirrors `ProseTextViewMac.makeNSView`.
    private func host(
        _ markdown: String,
        inlineContentRules: [InlineContentRule] = [],
        inlineContentProvider: ProseInlineContentProvider? = nil
    ) throws -> Host {
        let controller = try EditorController(
            initialMarkdown: markdown,
            theme: .default,
            inlineContentRules: inlineContentRules,
            inlineContentProvider: inlineContentProvider
        )
        let representable = ProseTextViewMac(controller: controller, text: .constant(markdown))
        let coordinator = representable.makeCoordinator()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let textView = ProseNSTextView(frame: frame, textContainer: controller.textContainer)
        textView.delegate = coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = controller.theme.textContainerInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        coordinator.textView = textView
        controller.hostTextView = textView
        textView.proseController = controller
        return Host(controller: controller, textView: textView, coordinator: coordinator)
    }

    private func type(_ text: String, into textView: NSTextView) async throws {
        for ch in text {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
        // Hosted drains run on the next tick.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    /// Characters TextKit 2 has laid out into line fragments — what the
    /// view will paint.
    private func laidOutCharacters(_ textView: NSTextView) -> Int {
        guard let layoutManager = textView.textLayoutManager else { return -1 }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var count = 0
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: []) { fragment in
            for line in fragment.textLineFragments where line.typographicBounds.width > 0 {
                count += line.characterRange.length
            }
            return true
        }
        return count
    }

    private func navHost(_ markdown: String) throws -> Host {
        let rule = InlineContentRule(
            id: "nav",
            pattern: #"\{nav(?:\s+|\s*,\s*)icon=([A-Za-z0-9_\-]+)\s*,\s*name=([^}\n]*)\}"#
        ) { match in
            guard let icon = match.capture(1), let name = match.capture(2) else { return nil }
            return .custom(kind: "navLabel", label: name, systemImage: icon)
        }
        return try host(
            markdown,
            inlineContentRules: [rule],
            inlineContentProvider: { _ in NSTextAttachment() }
        )
    }

    /// One `\u{FFFC}` is one character, so AppKit's own delete takes the
    /// whole token — no `.proseListMarker`-style special case.
    func testBackspaceRemovesAWholeInlineContentUnit() async throws {
        let h = try navHost("{nav,  icon=sticky-note, name=note:} looks good\n")
        XCTAssertEqual(h.controller.textStorage.string, "\u{FFFC} looks good\n")
        h.textView.setSelectedRange(NSRange(location: 1, length: 0))
        h.textView.deleteBackward(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.controller.markdown(), " looks good")
    }

    func testTypingBesideAnInlineContentIconKeepsTheSource() async throws {
        let h = try navHost("{nav,  icon=sticky-note, name=note:} looks good\n")
        h.textView.setSelectedRange(NSRange(location: 1, length: 0))
        try await type("!", into: h.textView)
        XCTAssertEqual(
            h.controller.markdown(),
            "{nav,  icon=sticky-note, name=note:}! looks good"
        )
    }

    func testUndoAfterEditingBesideAnIconRestoresTheSource() async throws {
        let source = "{nav,  icon=sticky-note, name=note:} looks good\n"
        let h = try navHost(source)
        // End of the paragraph's text, before its terminator.
        let end = (h.controller.textStorage.string as NSString).range(of: "\n").location
        h.textView.setSelectedRange(NSRange(location: end, length: 0))
        try await type("!", into: h.textView)
        XCTAssertEqual(h.controller.markdown(), "{nav,  icon=sticky-note, name=note:} looks good!")
        h.controller.undoManager.undo()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.controller.markdown(), "{nav,  icon=sticky-note, name=note:} looks good")
    }

    func testTypedCharactersLandInStorageAndLayout() async throws {
        let h = try host("")
        XCTAssertEqual(laidOutCharacters(h.textView), 0)
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("hello", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.string, "hello")
        XCTAssertEqual(h.controller.markdown(), "hello")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertEqual(laidOutCharacters(h.textView), 5)
    }

    func testTypingAppendsToAnExistingDocument() async throws {
        let h = try host("# Hello\n\nType into me.\n")
        let before = laidOutCharacters(h.textView)
        let end = h.controller.textStorage.length
        h.textView.setSelectedRange(NSRange(location: end, length: 0))
        try await type("new words", into: h.textView)
        XCTAssertEqual(h.controller.markdown(), "# Hello\n\nType into me.\n\nnew words")
        XCTAssertEqual(laidOutCharacters(h.textView), before + "new words".count)
    }

    /// AppKit's `insertText` brackets one character with attribute writes;
    /// that is still typing, so input rules fire and the burst is one
    /// undo unit.
    func testTypedCharactersClassifyAsTyping() async throws {
        let h = try host("")
        var classes: [EditorController.EditClass] = []
        h.controller.classificationProbe = { classes.append($0) }
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("ab", into: h.textView)
        XCTAssertEqual(classes, [.typing, .typing])
    }

    func testInputRulesFireForTypedText() async throws {
        let h = try host("")
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("# Title", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.blockSpec(at: 0)?.kind, .heading(level: 1))
        XCTAssertEqual(h.controller.markdown(), "# Title")
    }

    /// An inline mark rule leaves the caret immediately after the content
    /// it styled, not at the end of the line.
    func testInlineRulesLeaveTheCaretAfterTheStyledContent() async throws {
        for (trigger, markdown) in [
            ("**x**", "alpha **x**beta gamma"),
            ("*x*", "alpha *x*beta gamma"),
            ("~~x~~", "alpha ~~x~~beta gamma"),
            ("`x`", "alpha `x`beta gamma")
        ] {
            let h = try host("alpha beta gamma\n")
            h.textView.setSelectedRange(NSRange(location: 6, length: 0))
            // The controller re-resolves typing attributes on the next tick;
            // typing before it lands measures AppKit's defaults, not ours.
            try await Task.sleep(nanoseconds: 50_000_000)
            try await type(trigger, into: h.textView)
            XCTAssertEqual(h.controller.textStorage.string, "alpha xbeta gamma\n", trigger)
            XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 7, length: 0), trigger)
            XCTAssertEqual(h.controller.markdown(), markdown, trigger)
        }
    }

    /// The caret offset is the capture length, padding included — the
    /// compiler does not strip a code span's interior spaces.
    func testCodeSpanRuleWithPaddedContentLandsTheCaretAfterThePadding() async throws {
        let h = try host("alpha beta gamma\n")
        h.textView.setSelectedRange(NSRange(location: 6, length: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await type("` x `", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.string, "alpha  x beta gamma\n")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 9, length: 0))
    }

    /// Literal markup ahead of the match is content, and stays content.
    func testInlineRuleKeepsLiteralMarkupAheadOfTheMatch() async throws {
        let h = try host("")
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("see _em_ ", into: h.textView)
        try await type("`x`", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.string, "see _em_ x")
        XCTAssertEqual(h.controller.markdown(), "see _em_ `x`")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 10, length: 0))
    }

    /// A match that ends the line still collapses the caret to the end of
    /// the content.
    func testInlineRuleAtTheEndOfTheLineKeepsItsCaret() async throws {
        let empty = try host("")
        empty.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("**bold**", into: empty.textView)
        XCTAssertEqual(empty.controller.textStorage.string, "bold")
        XCTAssertEqual(empty.textView.selectedRange(), NSRange(location: 4, length: 0))

        let h = try host("alpha\n")
        h.textView.setSelectedRange(NSRange(location: 5, length: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await type(" **x**", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.string, "alpha x\n")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 7, length: 0))
    }

    func testAppKitRegistersNothingOnTheControllersUndoStack() async throws {
        let h = try host("")
        XCTAssertNil(h.textView.undoManager)
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("hello", into: h.textView)
        XCTAssertTrue(h.controller.undoManager.canUndo)
        // One burst, one unit: a second entry would mean the view
        // registered its own.
        h.controller.undoManager.undo()
        XCTAssertEqual(h.controller.textStorage.string, "")
        XCTAssertFalse(h.controller.undoManager.canUndo)
    }

    /// Typed characters share one mark run; a mark command over them
    /// serializes once, not per character.
    func testInlineMarkOverTypedTextSerializesOnce() async throws {
        let h = try host("")
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("this is a url to link to", into: h.textView)
        h.textView.setSelectedRange(NSRange(location: 10, length: 3))
        _ = h.controller.perform(.bold)
        XCTAssertEqual(h.controller.markdown(), "this is a **url** to link to")
        h.textView.undo(nil)
        h.textView.setSelectedRange(NSRange(location: 10, length: 3))
        _ = h.controller.perform(.link)
        XCTAssertEqual(h.controller.markdown(), "this is a [url](url) to link to")
        XCTAssertEqual(h.controller.linkMark(at: 11)?.range, NSRange(location: 10, length: 3))
    }

    /// Commands and undo change storage without a `textDidChange`; the
    /// binding follows them anyway.
    func testCommandsAndUndoPushTheTextBinding() async throws {
        var bound = ""
        let binding = Binding<String>(get: { bound }, set: { bound = $0 })
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        let representable = ProseTextViewMac(controller: controller, text: binding)
        let coordinator = representable.makeCoordinator()
        let textView = ProseNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: controller.textContainer)
        textView.delegate = coordinator
        textView.isEditable = true
        textView.allowsUndo = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        coordinator.textView = textView
        controller.hostTextView = textView
        textView.proseController = controller
        defer { withExtendedLifetime(coordinator) {} }

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("some url here", into: textView)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(bound, "some url here")

        textView.setSelectedRange(NSRange(location: 5, length: 3))
        _ = controller.perform(.bold)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(bound, "some **url** here")

        textView.undo(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(bound, "some url here")

        // A load is the host's own write; it must not bounce back.
        controller.setMarkdown("fresh\n", async: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(bound, "some url here")
    }

    func testMenuUndoAndRedoReachTheController() async throws {
        let h = try host("")
        let undoItem = NSMenuItem(title: "Undo", action: #selector(ProseNSTextView.undo(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(ProseNSTextView.redo(_:)), keyEquivalent: "Z")
        XCTAssertFalse(h.textView.validateUserInterfaceItem(undoItem))

        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await type("abc", into: h.textView)
        XCTAssertTrue(h.textView.validateUserInterfaceItem(undoItem))
        XCTAssertFalse(h.textView.validateUserInterfaceItem(redoItem))

        h.textView.undo(nil)
        XCTAssertEqual(h.controller.textStorage.string, "")
        XCTAssertTrue(h.textView.validateUserInterfaceItem(redoItem))

        h.textView.redo(nil)
        XCTAssertEqual(h.controller.textStorage.string, "abc")
    }

    func testTypingAtTheTrailingEdgeExtendsAnInclusiveMark() async throws {
        let host = try host("turn it **up** now\n")
        // Storage offset 10 is the trailing edge of the bold run.
        host.textView.setSelectedRange(NSRange(location: 10, length: 0))
        // The controller re-resolves typing attributes on the next tick;
        // typing before it lands measures AppKit's defaults, not ours.
        try await Task.sleep(nanoseconds: 50_000_000)
        try await type("per", into: host.textView)
        XCTAssertEqual(host.controller.markdown(), "turn it **upper** now")
    }

    func testTypingAtTheTrailingEdgeOfALinkDoesNotExtendIt() async throws {
        let host = try host("see [docs](https://example.com) now\n")
        let end = (host.controller.textStorage.string as NSString).range(of: "docs")
        host.textView.setSelectedRange(NSRange(location: end.location + end.length, length: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await type("X", into: host.textView)
        XCTAssertEqual(host.controller.markdown(), "see [docs](https://example.com)X now")
    }

    func testJoiningAHeadingIntoAParagraphDropsItsHeadingStyling() async throws {
        let h = try host("introduction\n\n# Heading\n")
        let heading = (h.controller.textStorage.string as NSString).range(of: "Heading")
        h.textView.setSelectedRange(NSRange(location: heading.location, length: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<2 {
            h.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        // The heading's display bold must not come back as a literal mark.
        XCTAssertEqual(h.controller.markdown(), "introductionHeading")
        let font = h.controller.textStorage
            .attribute(.font, at: heading.location - 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, h.controller.theme.bodyFont.pointSize)
    }

    func testACancelledCompositionLeavesNoBaselineBehind() async throws {
        let h = try host("Hello\n\nWorld\n")
        h.textView.setSelectedRange(NSRange(location: 5, length: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        h.textView.setMarkedText("z", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertNotNil(h.controller.compositionBaseline)

        // Escape's shape: empty the marked range, then unmark.
        h.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                                 replacementRange: h.textView.markedRange())
        h.textView.unmarkText()
        try await Task.sleep(nanoseconds: 60_000_000)

        // A baseline left open here is read as "already composing" by every
        // later composition, which then commits against a dead range.
        XCTAssertNil(h.controller.compositionBaseline)
        XCTAssertEqual(h.controller.markdown(), "Hello\n\nWorld")
    }

}
#endif
