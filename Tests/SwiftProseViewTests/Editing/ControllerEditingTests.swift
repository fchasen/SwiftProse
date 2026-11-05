#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
extension EditorHarness {
    func typeEach(_ text: String) {
        for character in text {
            type(String(character))
            settle()
        }
    }

    func settle() {
        controller.flushDocumentChanges()
        controller.drainDeferredEdits()
    }

    var markdown: String { controller.markdown() }

    func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("mek-test-\(UUID().uuidString)"))
    }
}

@Suite("Controller key rules (macOS, .serialized)")
@MainActor
struct ControllerKeyRuleTests {
    @Test func tabNestsAnywhereInItemAndShiftTabOutdents() {
        let harness = EditorHarness(markdown: "- one\n- two")
        harness.select(6)
        harness.insertTab()
        #expect(harness.string == "one\ntwo")
        #expect(harness.textLists(at: 4).count == 2)
        #expect(harness.block(at: 4)?.containers == [.listItem, .listItem])
        #expect(harness.markdown == "- one\n  - two")

        harness.insertBacktab()
        #expect(harness.textLists(at: 4).count == 1)
        #expect(harness.markdown == "- one\n- two")

        harness.insertBacktab()
        #expect(harness.textLists(at: 4).isEmpty)
        #expect(harness.block(at: 4) == .paragraph)
        #expect(harness.markdown == "- one\n\ntwo")
    }

    @Test func tabReusesPreviousSiblingSublist() {
        let harness = EditorHarness(markdown: "- a\n  - b\n- c")
        harness.select(5)
        harness.insertTab()
        let bLists = harness.textLists(at: 2)
        let cLists = harness.textLists(at: 4)
        #expect(cLists.count == 2)
        #expect(cLists[1] === bLists[1])
        #expect(harness.markdown == "- a\n  - b\n  - c")
    }

    @Test func tabAndShiftTabMoveContinuationsWithTheirItem() {
        let harness = EditorHarness(markdown: "- a\n- b\n\n  cont")
        let b = (harness.string as NSString).range(of: "b").location
        harness.select(NSRange(location: b, length: harness.storage.length - b))
        harness.insertTab()
        #expect(harness.markdown == "- a\n  - b\n\n    cont")
        harness.insertBacktab()
        #expect(harness.markdown == "- a\n- b\n\n  cont")

        let caret = EditorHarness(markdown: "- a\n  - b\n\n    cont\n- c")
        caret.select((caret.string as NSString).range(of: "b").location)
        caret.insertBacktab()
        #expect(caret.markdown == "- a\n- b\n\n  cont\n- c")

        let inContinuation = EditorHarness(markdown: "- a\n- b\n\n  cont")
        inContinuation.select(inContinuation.storage.length)
        inContinuation.insertTab()
        #expect(inContinuation.markdown == "- a\n  - b\n\n    cont")
    }

    @Test func sharedBackspaceOutdentKeepsContinuations() {
        let harness = EditorHarness(markdown: "- a\n  - b\n\n    cont\n- c")
        harness.controller.usesNativeListEditing = false
        harness.select((harness.string as NSString).range(of: "b").location)
        harness.deleteBackward()
        #expect(harness.markdown == "- a\n- b\n\n  cont\n- c")
    }

    @Test func tabOutsideListInsertsTabCharacter() {
        let harness = EditorHarness(markdown: "plain")
        harness.select(5)
        harness.insertTab()
        #expect(harness.string == "plain\t")
    }

    @Test func nativeListReturnAtDocumentEndContinuesList() {
        let harness = EditorHarness(markdown: "- one")
        harness.select(3)
        harness.insertNewline()
        #expect(harness.markdown == "- one")
        harness.type("two")
        #expect(harness.markdown == "- one\n- two")
    }

    @Test func sharedListRulesSplitOutdentAndBackspace() {
        let harness = EditorHarness(markdown: "- one\n- two")
        harness.controller.usesNativeListEditing = false
        harness.select(3)
        harness.insertNewline()
        #expect(harness.paragraphTexts == ["one", "", "two"])
        #expect(harness.block(at: 4)?.isListItemStart == true)
        #expect(harness.textLists(at: 4).first === harness.textLists(at: 0).first)

        harness.insertNewline()
        #expect(harness.textLists(at: 4).isEmpty)
        #expect(harness.block(at: 4) == .paragraph)

        harness.undo()
        #expect(harness.block(at: 4)?.isListItemStart == true)

        harness.select(5)
        harness.deleteBackward()
        #expect(harness.textLists(at: 5).isEmpty)
        #expect(harness.markdown == "- one\n-\n\ntwo")
    }

    @Test func headingReturnAtEndStartsPlainParagraph() {
        let harness = EditorHarness(markdown: "# Title\n\nbody")
        harness.select(5)
        harness.insertNewline()
        #expect(harness.paragraphTexts == ["Title", "", "body"])
        #expect(harness.block(at: 6) == .paragraph)
        harness.type("x")
        #expect(harness.markdown == "# Title\n\nx\n\nbody")
    }

    @Test func headingReturnAtDocumentEnd() {
        let harness = EditorHarness(markdown: "# Title")
        harness.select(5)
        harness.insertNewline()
        harness.type("x")
        #expect(harness.markdown == "# Title\n\nx")
        harness.undo()
        harness.undo()
        #expect(harness.markdown == "# Title")
    }

    @Test func headingBackspaceAtStartMakesParagraph() {
        let harness = EditorHarness(markdown: "## Title")
        harness.select(0)
        harness.deleteBackward()
        #expect(harness.string == "Title")
        #expect(harness.markdown == "Title")
        harness.undo()
        #expect(harness.markdown == "## Title")
    }

    @Test func quoteReturnOnEmptyLineLeavesQuote() {
        let harness = EditorHarness(markdown: "> a")
        harness.select(1)
        harness.insertNewline()
        harness.insertNewline()
        harness.type("b")
        #expect(harness.markdown == "> a\n\nb")
    }

    @Test func quoteBackspaceAtStartRemovesQuote() {
        let harness = EditorHarness(markdown: "> a\n> \n> b")
        let start = (harness.string as NSString).range(of: "b").location
        harness.select(start)
        harness.deleteBackward()
        #expect(harness.block(at: start)?.isInQuote == false)
        #expect(harness.markdown == "> a\n\nb")
    }

    @Test func quoteReturnOnEmptyMiddleLineTypesOutsideQuote() {
        let harness = EditorHarness(markdown: "> a\n>\n> b")
        harness.select(1)
        harness.insertNewline()
        harness.insertNewline()
        harness.type("x")
        let x = (harness.string as NSString).range(of: "x").location
        #expect(harness.block(at: x)?.isInQuote == false)
        #expect(harness.markdown == "> a\n\nx\n\n> b")
    }

    @Test func headingBackspaceOnEmptyLineTypesParagraph() {
        let harness = EditorHarness(markdown: "# Title")
        harness.select(0)
        harness.insertNewline()
        harness.select(0)
        harness.deleteBackward()
        harness.type("x")
        #expect(harness.markdown == "x\n\n# Title")
    }

    @Test func tabOnEmptyMiddleItemTypesNestedItem() {
        let harness = EditorHarness(markdown: "- a\n- b")
        harness.select(1)
        harness.insertNewline()
        harness.insertTab()
        harness.type("x")
        #expect(harness.markdown == "- a\n  - x\n- b")
    }

    @Test func codeReturnContinuesAndSecondEmptyLineExits() {
        let harness = EditorHarness(markdown: "```\nx\n```")
        harness.select(1)
        harness.insertNewline()
        harness.type("y")
        #expect(harness.markdown == "```\nx\ny\n```")
        harness.insertNewline()
        harness.insertNewline()
        harness.type("z")
        #expect(harness.markdown == "```\nx\ny\n```\n\nz")
    }

    @Test func indentedCodeReturnKeepsIndentation() {
        let harness = EditorHarness(markdown: "    x")
        harness.select(1)
        harness.insertNewline()
        harness.type("y")
        #expect(harness.block(at: 2)?.codeStyle == .indented)
        #expect(harness.markdown == "    x\n    y")
    }

    @Test func commandReturnExitsCodeBlock() {
        let harness = EditorHarness(markdown: "```\nx\ny\n```\n\nafter")
        harness.select(1)
        harness.step { _ = harness.controller.exitCodeBlock() }
        #expect(harness.selection.location == 4)
        harness.type("p")
        #expect(harness.markdown == "```\nx\ny\n```\n\np\n\nafter")
    }

    @Test func backspaceAtFirstCodeLineMakesParagraph() {
        let harness = EditorHarness(markdown: "```\nx\ny\n```")
        harness.select(0)
        harness.deleteBackward()
        #expect(harness.block(at: 0) == .paragraph)
        #expect(harness.block(at: 2)?.isCode == true)
        #expect(harness.markdown == "x\n\n```\ny\n```")
    }

    @Test func fenceReturnCreatesCodeBlock() {
        let harness = EditorHarness(markdown: "")
        harness.type("```swift")
        harness.insertNewline()
        #expect(harness.controller.paragraphInfo(at: harness.selection.location).block.codeLanguage == "swift")
        harness.type("let a")
        #expect(harness.markdown == "```swift\nlet a\n```")
        harness.undo()
        harness.undo()
        #expect(harness.string == "```swift")
    }

    @Test func thematicBreakReturnInsertsRule() {
        let harness = EditorHarness(markdown: "intro")
        harness.select(5)
        harness.insertNewline()
        harness.type("---")
        harness.insertNewline()
        #expect(harness.storage.proseSourceAttachment(at: 6)?.contentKind == AtomKind.thematicBreak)
        harness.type("x")
        #expect(harness.markdown == "intro\n\n---\n\nx")
    }

    @Test func shiftReturnInsertsHardBreak() {
        let harness = EditorHarness(markdown: "ab")
        harness.select(1)
        harness.insertLineBreak()
        #expect(harness.string == "a\u{2028}b")
        #expect(harness.markdown == "a  \nb")
    }

    @Test func taskToggleAndBackspaceRemovesTask() {
        let harness = EditorHarness(markdown: "- [ ] a\n- [x] b")
        #expect(harness.controller.toggleCheckbox(at: 0))
        #expect(harness.markdown == "- [x] a\n- [x] b")
        harness.undo()
        #expect(harness.markdown == "- [ ] a\n- [x] b")
        #expect(!harness.controller.toggleCheckbox(at: 1))

        harness.select(2)
        harness.deleteBackward()
        #expect(harness.markdown == "- [ ] a\n- b")
    }

    @Test func coalescedReturnUndoesWithItsTaskNormalization() {
        let harness = EditorHarness(markdown: "- [x] done\n\nafter")
        harness.undoManager.groupsByEvent = true
        harness.select(4)
        harness.spin()
        for text in ["x", "\n", "a", "b"] {
            if text == "\n" {
                harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                harness.textView.insertText(text, replacementRange: harness.textView.selectedRange())
            }
            harness.spin()
        }
        #expect(harness.markdown == "- [x] donex\n- [ ] ab\n\nafter")
        var states: [String] = []
        while harness.undoManager.canUndo, states.count < 6 {
            harness.undoManager.undo()
            harness.spin()
            states.append(harness.markdown)
        }
        #expect(states == [
            "- [x] donex\n- [ ] a\n\nafter",
            "- [x] donex\n- [ ]\n\nafter",
            "- [x] donex\n\nafter",
            "- [x] done\n\nafter",
        ])
    }

    @Test func returnAfterCheckedTaskCreatesUncheckedItem() {
        let harness = EditorHarness(markdown: "- [x] done")
        harness.select(4)
        harness.insertNewline()
        harness.type("next")
        #expect(harness.markdown == "- [x] done\n- [ ] next")
    }

    @Test func typingIntoAtomParagraphRedirects() {
        let harness = EditorHarness(markdown: "a\n\n---")
        harness.select(3)
        harness.type("x")
        #expect(harness.paragraphTexts == ["a", "\u{FFFC}", "x"])
        #expect(harness.markdown == "a\n\n---\n\nx")

        harness.select(2)
        harness.type("y")
        #expect(harness.paragraphTexts == ["a", "y", "\u{FFFC}", "x"])
        #expect(harness.block(at: 2) == .paragraph)
    }

    @Test func backspaceDeletesAtomAsUnit() {
        let harness = EditorHarness(markdown: "a\n\n---\n\nb")
        harness.select(3)
        harness.deleteBackward()
        #expect(harness.markdown == "a\n\nb")
        harness.undo()
        #expect(harness.markdown == "a\n\n---\n\nb")

        harness.select(4)
        harness.deleteBackward()
        #expect(harness.markdown == "a\n\nb")
    }

    @Test func returnBesideAtomInsertsParagraph() {
        let harness = EditorHarness(markdown: "---")
        harness.select(1)
        harness.insertNewline()
        harness.type("x")
        #expect(harness.markdown == "---\n\nx")
    }

    @Test func markedTextBlocksKeyRulesAndPush() {
        let harness = EditorHarness(markdown: "# Title")
        harness.select(5)
        harness.clearPushes()
        harness.setMarkedText("に")
        #expect(harness.pushes.isEmpty)
        #expect(!harness.controller.handleNewline())
        #expect(!harness.controller.handleBackspace())
        harness.unmarkText()
        #expect(harness.pushes == ["# Titleに"])
    }
}

@Suite("Controller input rules (macOS, .serialized)")
@MainActor
struct ControllerInputRuleTests {
    private func check(_ typed: String, expected: String, literal: String? = nil, initial: String = "") {
        let harness = EditorHarness(markdown: initial)
        harness.select(harness.string.utf16.count)
        harness.typeEach(typed)
        harness.settle()
        #expect(harness.markdown == expected, "\(typed)")
        harness.undo()
        harness.settle()
        #expect(harness.string == (literal ?? initial + typed), "undo \(typed)")
    }

    @Test func headingRule() { check("## ", expected: "", literal: "## ") }
    @Test func headingRuleKeepsText() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("# ")
        harness.settle()
        harness.type("Title")
        #expect(harness.markdown == "# Title")
    }
    @Test func bulletRule() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("- ")
        harness.settle()
        harness.type("item")
        #expect(harness.markdown == "- item")
        #expect(harness.textLists(at: 0).count == 1)
    }
    @Test func orderedRule() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("3. ")
        harness.settle()
        harness.type("item")
        #expect(harness.markdown == "3. item")
    }
    @Test func quoteRule() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("> ")
        harness.settle()
        harness.type("q")
        #expect(harness.markdown == "> q")
    }
    @Test func taskRule() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("[ ] ")
        harness.settle()
        harness.type("todo")
        #expect(harness.markdown == "- [ ] todo")
    }
    @Test func blockRuleUndoRestoresTypedMarker() {
        check("- ", expected: "", literal: "- ")
    }
    @Test func boldCloser() { check("a **b**", expected: "a **b**", literal: "a **b**") }
    @Test func italicCloser() { check("a *b*", expected: "a *b*", literal: "a *b*") }
    @Test func underscoreCloser() { check("a _b_", expected: "a *b*", literal: "a _b_") }
    @Test func strikeCloser() { check("a ~~b~~", expected: "a ~~b~~", literal: "a ~~b~~") }
    @Test func codeCloser() { check("a `b`", expected: "a `b`", literal: "a `b`") }

    @Test func closerAppliesMarkAndStopsIt() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("**b**")
        harness.settle()
        #expect(harness.string == "b")
        #expect(harness.storage.markdownInlineIntent(at: 0) == .stronglyEmphasized)
        harness.type("c")
        #expect(harness.markdown == "**b**c")
    }

    @Test func intrawordUnderscoreDoesNotClose() {
        let harness = EditorHarness(markdown: "")
        harness.typeEach("snake_case_")
        harness.settle()
        #expect(harness.string == "snake_case_")
    }

    @Test func rulesSkipCode() {
        let harness = EditorHarness(markdown: "```\nx\n```")
        harness.select(1)
        harness.typeEach(" **b**")
        harness.settle()
        #expect(harness.string == "x **b**")
    }
}

@Suite("Controller clipboard (macOS, .serialized)")
@MainActor
struct ControllerClipboardTests {
    @Test func plainPasteParsesMarkdown() {
        let harness = EditorHarness(markdown: "")
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("# Head\n\n- **a**\n- b", forType: .string)
        harness.step { _ = harness.textView.readSelection(from: pasteboard, type: .string) }
        #expect(harness.markdown == "# Head\n\n- **a**\n- b")
        #expect(harness.selection.location == harness.storage.length)
        harness.undo()
        #expect(harness.string.isEmpty)
    }

    @Test func inlinePasteKeepsParagraphBlock() {
        let harness = EditorHarness(markdown: "# Title")
        harness.select(2)
        #expect(harness.controller.paste(PastePayload(plainText: "**x** "), replacing: harness.selection))
        #expect(harness.markdown == "# Ti**x** tle")
    }

    @Test func pasteIntoListItemKeepsContext() {
        let harness = EditorHarness(markdown: "- a")
        harness.select(1)
        #expect(harness.controller.paste(PastePayload(plainText: "b\n\nc"), replacing: harness.selection))
        #expect(harness.markdown == "- ab\n\n  c")
    }

    @Test func htmlPasteIsSanitized() {
        let harness = EditorHarness(markdown: "")
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<p>Hello <b>bold</b></p><ul><li>one</li><li>two</li></ul>", forType: .html)
        pasteboard.setString("Hello bold\none\ntwo", forType: .string)
        harness.step { _ = harness.textView.readSelection(from: pasteboard, type: .html) }
        #expect(harness.markdown == "Hello **bold**\n\n- one\n- two")
        #expect(harness.isTextKit2)
    }

    @Test func pasteInCodeInsertsLiteralLines() {
        let harness = EditorHarness(markdown: "```\nx\n```")
        harness.select(1)
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("\n**a**\n- b", forType: .string)
        harness.step { _ = harness.textView.readSelection(from: pasteboard, type: .string) }
        #expect(harness.markdown == "```\nx\n**a**\n- b\n```")
    }

    @Test func pasteAsPlainTextIsLiteral() {
        let harness = EditorHarness(markdown: "")
        #expect(harness.controller.paste(PastePayload(plainText: "**x**\n# y", forcePlain: true), replacing: harness.selection))
        #expect(harness.string == "**x**\n# y")
        #expect(harness.storage.markdownInlineIntent(at: 2).isEmpty)
        #expect(harness.block(at: 6) == .paragraph)
    }

    @Test func copyWritesMarkdown() {
        let harness = EditorHarness(markdown: "# Head\n\nsome **bold** text")
        let pasteboard = harness.privatePasteboard()
        harness.select(NSRange(location: 0, length: harness.storage.length))
        pasteboard.declareTypes([.string], owner: nil)
        #expect(harness.textView.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "# Head\n\nsome **bold** text")

        let start = (harness.string as NSString).range(of: "bold").location
        harness.select(NSRange(location: start - 2, length: 7))
        pasteboard.declareTypes([.string], owner: nil)
        #expect(harness.textView.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "e **bold** ")

        harness.select(NSRange(location: 0, length: 3))
        pasteboard.declareTypes([.string], owner: nil)
        #expect(harness.textView.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "Hea")
    }

    @Test func copiedMarkdownTypeRoundTrips() {
        let source = EditorHarness(markdown: "- [ ] task\n\n> quote")
        let pasteboard = source.privatePasteboard()
        source.select(NSRange(location: 0, length: source.storage.length))
        #expect(source.textView.writeSelection(to: pasteboard, types: source.textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: ProseNSTextView.markdownType) == "- [ ] task\n\n> quote")

        let target = EditorHarness(markdown: "")
        target.step { _ = target.textView.readSelection(from: pasteboard, type: .rtf) }
        #expect(target.markdown == "- [ ] task\n\n> quote")
    }

    @Test func insertMarkdownLabelKeepsTrailingSpace() {
        let harness = EditorHarness(markdown: "text")
        harness.select(0)
        harness.step { _ = harness.controller.insertMarkdown("**x** ", label: "Insert") }
        #expect(harness.markdown == "**x** text")
        #expect(harness.controller.undoManager.undoActionName == "Insert")
    }

    @Test func insertLinkAndReplaceText() {
        let harness = EditorHarness(markdown: "see")
        harness.select(3)
        harness.type(" ")
        harness.step { _ = harness.controller.insertLink(label: "bug 1", url: "https://bugzilla.mozilla.org/show_bug.cgi?id=1") }
        #expect(harness.markdown == "see [bug 1](https://bugzilla.mozilla.org/show_bug.cgi?id=1)")
        harness.type(" ok")
        #expect(harness.markdown.hasSuffix(") ok"))

        let mention = EditorHarness(markdown: "hi @fr")
        mention.step { _ = mention.controller.replaceText(in: NSRange(location: 3, length: 3), with: "@fred ") }
        #expect(mention.string == "hi @fred ")
        #expect(mention.selection.location == 9)
    }

    @Test func pastedListJoinsSurroundingList() {
        let empty = EditorHarness(markdown: "- one")
        empty.select(3)
        empty.insertNewline()
        #expect(empty.controller.paste(PastePayload(plainText: "- a\n- b"), replacing: empty.selection))
        #expect(empty.markdown == "- one\n- a\n- b")

        let end = EditorHarness(markdown: "- one")
        end.select(3)
        #expect(end.controller.paste(PastePayload(plainText: "- a\n- b"), replacing: end.selection))
        #expect(end.markdown == "- onea\n- b")

        let source = EditorHarness(markdown: "- a\n- b\n- c")
        let copied = source.controller.markdownForCopy(range: NSRange(location: 2, length: 3))
        #expect(copied == "- b\n- c")
        source.select(source.storage.length)
        source.insertNewline()
        #expect(source.controller.paste(PastePayload(markdown: copied), replacing: source.selection))
        #expect(source.markdown == "- a\n- b\n- c\n- b\n- c")

        let nested = EditorHarness(markdown: "- one\n  - two")
        nested.select(nested.storage.length)
        nested.insertNewline()
        #expect(nested.controller.paste(PastePayload(plainText: "- a\n  - b"), replacing: nested.selection))
        #expect(nested.markdown == "- one\n  - two\n  - a\n    - b")
    }

    @Test func pasteInsideInlineCodeStaysInSpan() {
        let pasted = EditorHarness(markdown: "a `xy` b")
        pasted.select(3)
        #expect(pasted.controller.paste(PastePayload(plainText: "Q"), replacing: pasted.selection))
        #expect(pasted.markdown == "a `xQy` b")

        let inserted = EditorHarness(markdown: "a `xy` b")
        inserted.select(3)
        inserted.step { _ = inserted.controller.insertMarkdown("**Q**") }
        #expect(inserted.markdown == "a `x**Q**y` b")
    }

    @Test func plainPasteMidParagraphKeepsBlockMarkerText() {
        for (pasted, expected) in [
            ("1. Introduction", "see 1. Introduction now"),
            ("> quoted", "see > quoted now"),
            ("- [ ] **task**", "see - [ ] **task** now"),
            ("## Title", "see ## Title now")
        ] {
            let harness = EditorHarness(markdown: "see  now")
            harness.select(4)
            #expect(harness.controller.paste(PastePayload(plainText: pasted), replacing: harness.selection))
            #expect(harness.string == expected.replacingOccurrences(of: "**", with: ""))
            #expect(harness.paragraphBlocks == [.paragraph])
            #expect(harness.markdown == expected)
        }

        let start = EditorHarness(markdown: "abc")
        #expect(start.controller.paste(PastePayload(plainText: "1. x"), replacing: start.selection))
        #expect(start.string == "1. xabc")
        #expect(start.markdown == "1\\. xabc")

        let whole = EditorHarness(markdown: "")
        #expect(whole.controller.paste(PastePayload(plainText: "> quoted"), replacing: whole.selection))
        #expect(whole.markdown == "> quoted")
    }

    @Test func copyFromNestedItemStartsAtSelectedItem() {
        let harness = EditorHarness(markdown: "- a\n  - b\n  - c\n- d")
        let ns = harness.string as NSString
        #expect(harness.controller.markdownForCopy(range: NSRange(location: ns.range(of: "b").location, length: 3)) == "- b\n- c")
        let mixed = NSRange(location: ns.range(of: "c").location, length: ns.length - ns.range(of: "c").location)
        #expect(harness.controller.markdownForCopy(range: mixed) == "- - c\n- d")
        #expect(harness.controller.markdownForCopy(range: NSRange(location: ns.range(of: "b").location, length: 1)) == "- b")
        #expect(harness.controller.markdownForCopy(range: NSRange(location: 0, length: 3)) == "- a\n  - b")

        let quoted = EditorHarness(markdown: "> - a\n>   1. b\n>   2. c")
        let qs = quoted.string as NSString
        #expect(quoted.controller.markdownForCopy(range: NSRange(location: qs.range(of: "b").location, length: 3)) == "> 1. b\n> 2. c")
    }

    @Test func copyMultipleRangesSerializesEachRange() {
        let harness = EditorHarness(markdown: "a**bc**\n\ndef\n\nghi")
        harness.textView.selectedRanges = [
            NSValue(range: NSRange(location: 1, length: 2)),
            NSValue(range: NSRange(location: 5, length: 0)),
            NSValue(range: NSRange(location: 9, length: 2))
        ]
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        #expect(harness.textView.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "**bc**\nhi")
    }
}

@Suite("Controller format commands (macOS, .serialized)")
@MainActor
struct ControllerFormatCommandTests {
    @Test func boldTogglesSelection() {
        let harness = EditorHarness(markdown: "one two")
        harness.select(NSRange(location: 4, length: 3))
        harness.step { harness.controller.perform(.bold) }
        #expect(harness.markdown == "one **two**")
        #expect(harness.controller.isActive(.bold))
        harness.step { harness.controller.perform(.bold) }
        #expect(harness.markdown == "one two")
        harness.undo()
        #expect(harness.markdown == "one **two**")
    }

    @Test func boldWithEmptySelectionAffectsTyping() {
        let harness = EditorHarness(markdown: "a")
        harness.select(1)
        harness.controller.perform(.bold)
        #expect(harness.controller.isActive(.bold))
        harness.type("b")
        #expect(harness.markdown == "a**b**")
    }

    @Test func keymapShortcutRunsThroughKeyDown() {
        let harness = EditorHarness(markdown: "word")
        harness.select(NSRange(location: 0, length: 4))
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil,
            characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34
        )
        harness.step { harness.textView.keyDown(with: event!) }
        #expect(harness.markdown == "*word*")
    }

    @Test func fontTraitConversionMapsToMarks() {
        let harness = EditorHarness(markdown: "word")
        let controller = harness.controller
        #expect(controller.fontTraitActions { $0.withFontTraits($0.fontTraits.union(.bold)) } == [.bold])
        #expect(controller.fontTraitActions { $0.withFontTraits($0.fontTraits.subtracting(.italic)) } == [.italic])
        #expect(controller.fontTraitActions { NSFont.systemFont(ofSize: $0.pointSize * 2).withFontTraits($0.fontTraits) }.isEmpty)
    }

    @Test func underlineIsRefused() {
        let harness = EditorHarness(markdown: "word")
        harness.select(NSRange(location: 0, length: 4))
        harness.step { harness.textView.underline(nil) }
        #expect(harness.storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
        #expect(harness.pushes.isEmpty)
    }

    @Test func blockCommands() {
        let harness = EditorHarness(markdown: "a\n\nb")
        harness.select(NSRange(location: 0, length: 3))
        harness.step { harness.controller.perform(.unorderedList) }
        #expect(harness.markdown == "- a\n- b")
        harness.step { harness.controller.perform(.orderedList) }
        #expect(harness.markdown == "1. a\n2. b")
        harness.step { harness.controller.perform(.orderedList) }
        #expect(harness.markdown == "a\n\nb")
        harness.step { harness.controller.perform(.blockquote) }
        #expect(harness.markdown == "> a\n>\n> b")
        harness.step { harness.controller.perform(.blockquote) }
        harness.step { harness.controller.perform(.heading(level: 2)) }
        #expect(harness.markdown == "## a\n\n## b")
        harness.step { harness.controller.perform(.codeBlock) }
        #expect(harness.markdown == "```\na\nb\n```")
        harness.step { harness.controller.perform(.taskList) }
        #expect(harness.markdown == "- [ ] a\n- [ ] b")
    }

    @Test func blockCommandOnEmptyMiddleParagraphAppliesToTyping() {
        let list = EditorHarness(markdown: "a\n\nb")
        list.select(1)
        list.insertNewline()
        list.step { list.controller.perform(.unorderedList) }
        list.type("x")
        #expect(list.markdown == "a\n\n- x\n\nb")

        let heading = EditorHarness(markdown: "a\n\nb")
        heading.select(1)
        heading.insertNewline()
        heading.step { heading.controller.perform(.heading(level: 2)) }
        heading.type("x")
        #expect(heading.markdown == "a\n\n## x\n\nb")
    }

    @Test func blockCommandKeepsPendingInlineMarks() {
        let harness = EditorHarness(markdown: "a")
        harness.select(1)
        harness.step { harness.controller.perform(.bold) }
        harness.step { harness.controller.perform(.heading(level: 1)) }
        harness.type("b")
        #expect(harness.markdown == "# a**b**")
    }

    @Test func listToggleRetypesTopLevelAndKeepsNestedLists() {
        let harness = EditorHarness(markdown: "- a\n  - b\n- c")
        harness.select(NSRange(location: 0, length: harness.storage.length))
        harness.step { harness.controller.perform(.orderedList) }
        #expect(harness.markdown == "1. a\n   - b\n2. c")
        harness.undo()
        #expect(harness.markdown == "- a\n  - b\n- c")
        harness.redo()
        harness.select(NSRange(location: 0, length: harness.storage.length))
        harness.step { harness.controller.perform(.orderedList) }
        #expect(harness.markdown == "a\n\n- b\n\nc")
    }

    @Test func listToggleKeepsContinuationsAndWrapsPlainParagraphs() {
        let continued = EditorHarness(markdown: "- a\n\n  cont")
        continued.select(NSRange(location: 0, length: continued.storage.length))
        continued.step { continued.controller.perform(.orderedList) }
        #expect(continued.markdown == "1. a\n\n   cont")

        let mixed = EditorHarness(markdown: "p\n\n1. a\n   1. b")
        mixed.select(NSRange(location: 0, length: mixed.storage.length))
        mixed.step { mixed.controller.perform(.unorderedList) }
        #expect(mixed.markdown == "- p\n- a\n  1. b")
    }

    @Test func listToggleCoversWholeItems() {
        let partial = EditorHarness(markdown: "- a\n  - b\n- c")
        let b = (partial.string as NSString).range(of: "b").location
        partial.select(NSRange(location: b, length: partial.storage.length - b))
        partial.step { partial.controller.perform(.orderedList) }
        #expect(partial.markdown == "1. a\n   - b\n2. c")

        let head = EditorHarness(markdown: "- a\n  - b\n- c")
        head.select(0)
        head.step { head.controller.perform(.orderedList) }
        #expect(head.markdown == "1. a\n   - b\n\n- c")

        let continuation = EditorHarness(markdown: "- a\n\n  cont")
        continuation.select(continuation.storage.length)
        continuation.step { continuation.controller.perform(.orderedList) }
        #expect(continuation.markdown == "1. a\n\n   cont")
    }

    @Test func bulletedListOnTaskListConvertsToPlainBullets() {
        let harness = EditorHarness(markdown: "- [ ] a\n- [x] b")
        harness.select(NSRange(location: 0, length: harness.storage.length))
        #expect(!harness.controller.isActive(.unorderedList))
        harness.step { harness.controller.perform(.unorderedList) }
        #expect(harness.markdown == "- a\n- b")
        #expect(harness.controller.isActive(.unorderedList))
        harness.step { harness.controller.perform(.unorderedList) }
        #expect(harness.markdown == "a\n\nb")
    }

    @Test func codeBlockOverMixedSelectionKeepsLanguage() {
        let harness = EditorHarness(markdown: "```swift\nx\n```\n\np")
        harness.select(NSRange(location: 0, length: harness.storage.length))
        harness.step { harness.controller.perform(.codeBlock) }
        #expect(harness.markdown == "```swift\nx\np\n```")

        let partial = EditorHarness(markdown: "```swift\nx\ny\n```\n\np")
        let ns = partial.string as NSString
        partial.select(NSRange(location: ns.range(of: "y").location, length: ns.length - ns.range(of: "y").location))
        partial.step { partial.controller.perform(.codeBlock) }
        #expect(partial.markdown == "```swift\nx\ny\np\n```")
    }

    @Test func headingOnTaskItemDropsTheCheckbox() {
        let harness = EditorHarness(markdown: "- [ ] h")
        harness.select(0)
        harness.step { harness.controller.perform(.heading(level: 2)) }
        #expect(harness.block(at: 0)?.task == nil)
        #expect(harness.markdown == "- ## h")
        let reloaded = LoaderFixture.paragraphs(MarkdownLoader().load(harness.markdown))
        #expect(reloaded.map(\.text) == ["h"])
        #expect(reloaded.first?.block?.headingLevel == 2)
        harness.step { harness.controller.perform(.taskList) }
        #expect(harness.markdown == "- [ ] h")
    }

    @Test func horizontalRuleCommand() {
        let harness = EditorHarness(markdown: "a")
        harness.select(1)
        harness.step { harness.controller.perform(.horizontalRule) }
        harness.type("b")
        #expect(harness.markdown == "a\n\n---\n\nb")
    }

    @Test func linkCommandAppliesAndRemoves() {
        let harness = EditorHarness(markdown: "go here")
        harness.select(NSRange(location: 3, length: 4))
        harness.step { harness.controller.perform(.link(url: "https://x.org", label: nil)) }
        #expect(harness.markdown == "go [here](https://x.org)")
        harness.select(5)
        harness.step { harness.controller.perform(.link) }
        #expect(harness.markdown == "go here")
    }

    @Test func linkCommandWithoutURLInsertsAnEditableLink() {
        let harness = EditorHarness(markdown: "go here")
        harness.select(NSRange(location: 3, length: 4))
        harness.step { harness.controller.perform(.link) }
        #expect(harness.markdown == "go [here](url)")
        let url = EditorHarness(markdown: "see")
        url.select(3)
        url.type(" https://x.org")
        #expect(url.storage.markdownLink(at: 5) == nil)
        url.select(NSRange(location: 4, length: 13))
        url.step { url.controller.perform(.link) }
        #expect(url.storage.markdownLink(at: 5) == "https://x.org")
        #expect(url.markdown == "see https://x.org")
        let empty = EditorHarness(markdown: "a")
        empty.select(1)
        empty.step { empty.controller.perform(.link) }
        #expect(empty.markdown == "a[link](url)")
    }

    @Test func writingToolsIgnoredRangesCoverCodeAndAtoms() {
        let harness = EditorHarness(markdown: "a `b` c\n\n---\n\n```\nx\n```")
        let ranges = harness.controller.writingToolsIgnoredRanges(in: NSRange(location: 0, length: harness.storage.length))
        let ns = harness.string as NSString
        #expect(ranges.map { ns.substring(with: $0) } == ["b", "\u{FFFC}\nx"])
    }

    @Test func editorDefaultsApplyPlanSettings() {
        let textView = ProseNSTextView(frame: .zero)
        textView.applyEditorDefaults()
        #expect(textView.isRichText)
        #expect(!textView.importsGraphics)
        #expect(!textView.usesFontPanel)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
        #expect(textView.allowedWritingToolsResultOptions == [.plainText])
    }
}

#endif
