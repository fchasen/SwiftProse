#if canImport(AppKit) && os(macOS)
import XCTest
import SwiftUI
import AppKit
import SwiftProseSyntax
@testable import SwiftProseView

@MainActor
final class HostedTypingTests: XCTestCase {

    private final class BindingBox {
        var text = ""
    }

    private struct Host {
        let controller: EditorController
        let textView: ProseNSTextView
        let coordinator: ProseTextViewMac.Coordinator
        let window: NSWindow
        let binding: BindingBox
    }

    private var hosts: [Host] = []

    override func tearDown() async throws {
        for host in hosts { host.window.close() }
        hosts.removeAll()
    }

    private func host(
        _ markdown: String,
        inlineContentRules: [InlineContentRule] = [],
        inlineContentProvider: ProseInlineContentProvider? = nil
    ) -> Host {
        let box = BindingBox()
        box.text = markdown
        let binding = Binding<String>(get: { box.text }, set: { box.text = $0 })
        let controller = EditorController(
            markdown: markdown,
            inlineContentRules: inlineContentRules,
            inlineContentProvider: inlineContentProvider
        )
        let representable = ProseTextViewMac(controller: controller, text: binding)
        let coordinator = representable.makeCoordinator()
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.textContainer.size = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        let textView = ProseNSTextView(frame: frame, textContainer: controller.textContainer)
        textView.delegate = coordinator
        textView.applyEditorDefaults()
        textView.isEditable = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = controller.theme.textContainerInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        window.contentView = textView
        window.makeFirstResponder(textView)
        coordinator.textView = textView
        controller.hostTextView = textView
        textView.adoptSelection(controller.headlessSelection)
        textView.markdownController = controller
        controller.textSink = { [weak coordinator] markdown in coordinator?.push(markdown) }
        let host = Host(controller: controller, textView: textView, coordinator: coordinator, window: window, binding: box)
        hosts.append(host)
        return host
    }

    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func type(_ text: String, into textView: NSTextView) {
        for ch in text {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
            settle(0.005)
        }
        settle()
    }

    private func undoAll(_ h: Host) {
        while h.controller.undoManager.canUndo {
            h.textView.undo(nil)
            settle(0.005)
        }
    }

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

    private func navHost(_ markdown: String) -> Host {
        let rule = InlineContentRule(
            id: "nav",
            pattern: #"\{nav(?:\s+|\s*,\s*)icon=([A-Za-z0-9_\-]+)\s*,\s*name=([^}\n]*)\}"#
        ) { match in
            guard let icon = match.capture(1), let name = match.capture(2) else { return nil }
            return .custom(kind: "navLabel", label: name, systemImage: icon)
        }
        return host(
            markdown,
            inlineContentRules: [rule],
            inlineContentProvider: { ChipAttachment.make(for: $0) }
        )
    }

    private func linkRange(in storage: NSTextStorage, at index: Int) -> NSRange? {
        guard storage.markdownLink(at: index) != nil else { return nil }
        var effective = NSRange()
        _ = storage.attribute(.link, at: index, longestEffectiveRange: &effective, in: NSRange(location: 0, length: storage.length))
        return effective
    }

    func testBackspaceRemovesAWholeInlineContentUnit() {
        let h = navHost("{nav,  icon=sticky-note, name=note:} looks good\n")
        XCTAssertEqual(h.controller.textStorage.string, "\u{FFFC} looks good")
        h.textView.setSelectedRange(NSRange(location: 1, length: 0))
        h.textView.deleteBackward(nil)
        settle()
        XCTAssertEqual(h.controller.markdown(), " looks good")
    }

    func testTypingBesideAnInlineContentIconKeepsTheSource() {
        let h = navHost("{nav,  icon=sticky-note, name=note:} looks good\n")
        h.textView.setSelectedRange(NSRange(location: 1, length: 0))
        type("!", into: h.textView)
        XCTAssertEqual(
            h.controller.markdown(),
            "{nav,  icon=sticky-note, name=note:}! looks good"
        )
    }

    func testUndoAfterEditingBesideAnIconRestoresTheSource() {
        let source = "{nav,  icon=sticky-note, name=note:} looks good\n"
        let h = navHost(source)
        let end = h.controller.textStorage.length
        h.textView.setSelectedRange(NSRange(location: end, length: 0))
        type("!", into: h.textView)
        XCTAssertEqual(h.controller.markdown(), "{nav,  icon=sticky-note, name=note:} looks good!")
        h.textView.undo(nil)
        settle()
        XCTAssertEqual(h.controller.markdown(), source)
    }

    func testTypedCharactersLandInStorageAndLayout() {
        let h = host("")
        XCTAssertEqual(laidOutCharacters(h.textView), 0)
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("hello", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.string, "hello")
        XCTAssertEqual(h.controller.markdown(), "hello")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertEqual(laidOutCharacters(h.textView), 5)
    }

    func testTypingAppendsToAnExistingDocument() {
        let h = host("# Hello\n\nType into me.\n")
        let before = laidOutCharacters(h.textView)
        let end = h.controller.textStorage.length
        h.textView.setSelectedRange(NSRange(location: end, length: 0))
        h.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        type("new words", into: h.textView)
        XCTAssertEqual(h.controller.markdown(), "# Hello\n\nType into me.\n\nnew words")
        XCTAssertEqual(laidOutCharacters(h.textView), before + "\nnew words".count)
    }

    func testInputRulesFireForTypedText() {
        let h = host("")
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("# Title", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.markdownBlock(at: 0)?.headingLevel, 1)
        XCTAssertEqual(h.controller.markdown(), "# Title")
    }

    func testInlineRulesLeaveTheCaretAfterTheStyledContent() {
        for (trigger, markdown) in [
            ("**x**", "alpha **x**beta gamma"),
            ("*x*", "alpha *x*beta gamma"),
            ("~~x~~", "alpha ~~x~~beta gamma"),
            ("`x`", "alpha `x`beta gamma")
        ] {
            let h = host("alpha beta gamma\n")
            h.textView.setSelectedRange(NSRange(location: 6, length: 0))
            settle()
            type(trigger, into: h.textView)
            XCTAssertEqual(h.controller.textStorage.string, "alpha xbeta gamma", trigger)
            XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 7, length: 0), trigger)
            XCTAssertEqual(h.controller.markdown(), markdown, trigger)
        }
    }

    func testCodeSpanRuleWithPaddedContentLandsTheCaretAfterThePadding() {
        let h = host("alpha beta gamma\n")
        h.textView.setSelectedRange(NSRange(location: 6, length: 0))
        settle()
        type("` x `", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.string, "alpha  x beta gamma")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 9, length: 0))
    }

    func testInlineRuleKeepsAnEarlierStyledSpanAheadOfTheMatch() {
        let h = host("")
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("see _em_ ", into: h.textView)
        type("`x`", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.string, "see em x")
        XCTAssertEqual(h.controller.markdown(), "see *em* `x`")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 8, length: 0))
    }

    func testInlineRuleAtTheEndOfTheLineKeepsItsCaret() {
        let empty = host("")
        empty.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("**bold**", into: empty.textView)
        XCTAssertEqual(empty.controller.textStorage.string, "bold")
        XCTAssertEqual(empty.textView.selectedRange(), NSRange(location: 4, length: 0))

        let h = host("alpha\n")
        h.textView.setSelectedRange(NSRange(location: 5, length: 0))
        settle()
        type(" **x**", into: h.textView)
        XCTAssertEqual(h.controller.textStorage.string, "alpha x")
        XCTAssertEqual(h.textView.selectedRange(), NSRange(location: 7, length: 0))
    }

    func testTypingRegistersOnTheControllersUndoStack() {
        let h = host("")
        XCTAssertTrue(h.textView.undoManager === h.controller.undoManager)
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("hello", into: h.textView)
        XCTAssertTrue(h.controller.undoManager.canUndo)
        undoAll(h)
        XCTAssertEqual(h.controller.textStorage.string, "")
        XCTAssertFalse(h.controller.undoManager.canUndo)
    }

    func testInlineMarkOverTypedTextSerializesOnce() {
        let h = host("")
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("this is a url to link to", into: h.textView)
        h.textView.setSelectedRange(NSRange(location: 10, length: 3))
        h.controller.perform(.bold)
        XCTAssertEqual(h.controller.markdown(), "this is a **url** to link to")
        h.textView.undo(nil)
        settle()
        h.textView.setSelectedRange(NSRange(location: 10, length: 3))
        h.controller.perform(.link(url: "url"))
        XCTAssertEqual(h.controller.markdown(), "this is a [url](url) to link to")
        XCTAssertEqual(linkRange(in: h.controller.textStorage, at: 11), NSRange(location: 10, length: 3))
    }

    func testCommandsAndUndoPushTheTextBinding() {
        let h = host("")
        h.binding.text = ""
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("some url here", into: h.textView)
        XCTAssertEqual(h.binding.text, "some url here")

        h.textView.setSelectedRange(NSRange(location: 5, length: 3))
        h.controller.perform(.bold)
        XCTAssertEqual(h.binding.text, "some **url** here")

        h.textView.undo(nil)
        settle()
        XCTAssertEqual(h.binding.text, "some url here")

        h.controller.setMarkdown("fresh\n")
        settle()
        XCTAssertEqual(h.binding.text, "some url here")
    }

    func testMenuUndoAndRedoReachTheController() {
        let h = host("")
        let undoItem = NSMenuItem(title: "Undo", action: #selector(ProseNSTextView.undo(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(ProseNSTextView.redo(_:)), keyEquivalent: "Z")
        XCTAssertFalse(h.textView.validateUserInterfaceItem(undoItem))

        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("abc", into: h.textView)
        XCTAssertTrue(h.textView.validateUserInterfaceItem(undoItem))
        XCTAssertFalse(h.textView.validateUserInterfaceItem(redoItem))

        undoAll(h)
        XCTAssertEqual(h.controller.textStorage.string, "")
        XCTAssertFalse(h.textView.validateUserInterfaceItem(undoItem))
        XCTAssertTrue(h.textView.validateUserInterfaceItem(redoItem))

        while h.textView.validateUserInterfaceItem(redoItem) {
            h.textView.redo(nil)
            settle(0.005)
        }
        XCTAssertEqual(h.controller.textStorage.string, "abc")
    }

    func testTypingAtTheTrailingEdgeExtendsAnInclusiveMark() {
        let host = host("turn it **up** now\n")
        host.textView.setSelectedRange(NSRange(location: 10, length: 0))
        settle()
        type("per", into: host.textView)
        XCTAssertEqual(host.controller.markdown(), "turn it **upper** now")
    }

    func testTypingAtTheTrailingEdgeOfALinkDoesNotExtendIt() {
        let host = host("see [docs](https://example.com) now\n")
        let end = (host.controller.textStorage.string as NSString).range(of: "docs")
        host.textView.setSelectedRange(NSRange(location: end.location + end.length, length: 0))
        settle()
        type("X", into: host.textView)
        XCTAssertEqual(host.controller.markdown(), "see [docs](https://example.com)X now")
    }

    func testJoiningAHeadingIntoAParagraphDropsItsHeadingStyling() {
        let h = host("introduction\n\n# Heading\n")
        let heading = (h.controller.textStorage.string as NSString).range(of: "Heading")
        h.textView.setSelectedRange(NSRange(location: heading.location, length: 0))
        settle()
        h.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        settle()
        h.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        settle()
        XCTAssertEqual(h.controller.markdown(), "introductionHeading")
        let joined = (h.controller.textStorage.string as NSString).range(of: "Heading")
        let font = h.controller.textStorage
            .attribute(.font, at: joined.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, h.controller.theme.bodyFont.pointSize)
    }

    func testACancelledCompositionLeavesTheDocumentUnchanged() {
        let h = host("Hello\n\nWorld\n")
        h.textView.setSelectedRange(NSRange(location: 5, length: 0))
        settle()
        h.textView.setMarkedText("z", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        settle()
        h.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                                 replacementRange: h.textView.markedRange())
        h.textView.unmarkText()
        settle()
        XCTAssertEqual(h.controller.markdown(), "Hello\n\nWorld\n")
        h.textView.setSelectedRange(NSRange(location: 5, length: 0))
        type("!", into: h.textView)
        XCTAssertEqual(h.controller.markdown(), "Hello!\n\nWorld")
    }
}
#endif
