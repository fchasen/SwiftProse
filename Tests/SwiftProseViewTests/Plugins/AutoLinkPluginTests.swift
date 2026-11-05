import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Auto-link plugin", .serialized)
@MainActor
struct AutoLinkPluginTests {
    private func makeEditor(_ markdown: String = "", rules: [AutoLinkRule] = [.url, .email]) -> HeadlessEditor {
        let editor = HeadlessEditor(markdown: markdown)
        editor.controller.register(plugin: AutoLinkPlugin(rules: rules))
        return editor
    }

    @Test func keyNameMatchesKey() {
        #expect(AutoLinkPlugin(rules: []).key.name == AutoLinkPlugin.keyName)
    }

    @Test func wordInProgressIsNotLinked() {
        let editor = makeEditor()
        editor.type("see https://example.com")
        editor.settle()
        #expect(editor.link(at: 6) == nil)
    }

    @Test func trailingSpaceLinksPreviousWord() {
        let editor = makeEditor()
        editor.type("see https://example.com")
        editor.settle()
        editor.type(" ")
        editor.settle()
        #expect(editor.link(at: 6) == "https://example.com")
        #expect(editor.linkRange(at: 6) == NSRange(location: 4, length: 19))
        #expect(editor.link(at: 23) == nil)
        #expect(editor.controller.markdown() == "see https://example.com ")
    }

    @Test func editBeforePendingBoundaryStillLinks() {
        let editor = makeEditor()
        editor.type("see https://example.com")
        editor.settle()
        editor.type(" ")
        editor.select(0)
        editor.type("an insertion longer than the link ")
        editor.settle()
        #expect(editor.link(at: 40) == "https://example.com")
        #expect(editor.linkRange(at: 40) == NSRange(location: 38, length: 19))
    }

    @Test func trailingPunctuationStaysOutsideLink() {
        let editor = makeEditor()
        editor.type("go to https://example.com/a.")
        editor.settle()
        editor.type(" ")
        editor.settle()
        #expect(editor.linkRange(at: 7) == NSRange(location: 6, length: 21))
    }

    @Test func typingCharacterByCharacterLinksOnlyAtBoundary() {
        let editor = makeEditor(rules: PluginFixtures.referenceRules)
        editor.typeEach("D12")
        #expect(editor.link(at: 0) == nil)
        editor.typeEach("3 ")
        #expect(editor.link(at: 0) == "https://phabricator.services.mozilla.com/D123")
        #expect(editor.linkRange(at: 0) == NSRange(location: 0, length: 4))
    }

    @Test(arguments: [
        ("q https://example.com/s?q=1 now", 2, "https://example.com/s?q=1"),
        ("go http://localhost:8080/x now", 3, "http://localhost:8080/x"),
        ("mail fred@mail.example.com now", 5, "mailto:fred@mail.example.com"),
        ("see https://example.com/a.b/c now", 4, "https://example.com/a.b/c"),
    ])
    func typingCharacterByCharacterLinksTheWholeRun(text: String, start: Int, href: String) {
        let editor = makeEditor()
        editor.typeEach(text)
        editor.settle()
        #expect(editor.link(at: start) == href)
        let length = href.hasPrefix("mailto:") ? href.utf16.count - 7 : href.utf16.count
        #expect(editor.linkRange(at: start) == NSRange(location: start, length: length))
    }

    @Test(arguments: [
        ("see https://en.wikipedia.org/wiki/Foo_(bar) ok", ["https://en.wikipedia.org/wiki/Foo_(bar)"]),
        ("(see https://en.wikipedia.org/wiki/Foo_(bar))", ["https://en.wikipedia.org/wiki/Foo_(bar)"]),
        ("(https://example.com)", ["https://example.com"]),
        ("\"https://example.com\" ok", ["https://example.com"]),
        ("'https://example.com' ok", ["https://example.com"]),
        ("https://example.com/'x' ok", ["https://example.com/"]),
        ("**https://example.com**", ["https://example.com"]),
        ("https://example.com/a.", ["https://example.com/a"]),
        ("https://x.example/a(b c", ["https://x.example/a(b"]),
    ])
    func urlRuleTrimsQuotesAndUnbalancedParentheses(text: String, expected: [String]) {
        let ns = text as NSString
        let matches = AutoLinkRule.url.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        #expect(matches.map { ns.substring(with: $0.range(at: 1)) } == expected)
    }

    @Test func typingAURLWithBalancedParenthesesLinksTheWholeURL() {
        let editor = makeEditor()
        editor.typeEach("see https://en.wikipedia.org/wiki/Foo_(bar) ")
        editor.settle()
        #expect(editor.link(at: 4) == "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    @Test func captureRulesLinkOnlyTheLinkCapture() {
        let editor = makeEditor(rules: PluginFixtures.referenceRules)
        editor.typeEach("see bug 42, ok")
        #expect(editor.link(at: 3) == nil)
        #expect(editor.link(at: 4) == "https://bugzilla.mozilla.org/show_bug.cgi?id=42")
        #expect(editor.linkRange(at: 4) == NSRange(location: 4, length: 6))
        #expect(editor.controller.markdown() == "see [bug 42](https://bugzilla.mozilla.org/show_bug.cgi?id=42), ok")
    }

    @Test func leadingWordCharacterBlocksMatch() {
        let editor = makeEditor()
        editor.type("xhttps://example.com")
        editor.settle()
        editor.type(" ")
        editor.settle()
        #expect(editor.link(at: 3) == nil)
    }

    @Test func emailLinksWithMailto() {
        let editor = makeEditor()
        editor.type("mail a@example.org")
        editor.settle()
        editor.type(" ")
        editor.settle()
        #expect(editor.link(at: 6) == "mailto:a@example.org")
    }

    @Test func codeBlockIsSkipped() {
        let editor = makeEditor("```\nx\n```")
        editor.select(1)
        editor.type(" https://example.com ")
        editor.settle()
        #expect(editor.link(at: 5) == nil)
    }

    @Test func inlineCodeIsSkipped() {
        let editor = makeEditor("`https://example.com` and")
        editor.select(editor.controller.textStorage.length)
        editor.type(" ")
        editor.settle()
        #expect(editor.link(at: 3) == nil)
    }

    @Test func existingLinkIsLeftAlone() {
        let editor = makeEditor("[https://example.com](https://other.example)")
        editor.select(editor.controller.textStorage.length)
        editor.type(" ")
        editor.settle()
        #expect(editor.link(at: 3) == "https://other.example")
        #expect(editor.linkRange(at: 3) == NSRange(location: 0, length: 19))
    }

    @Test func unlinkedTextIsNotRelinkedByDistantEdits() {
        let editor = makeEditor("https://example.com and")
        #expect(editor.link(at: 3) != nil)
        editor.controller.setLink(nil, in: NSRange(location: 0, length: 19))
        editor.settle()
        #expect(editor.link(at: 3) == nil)
        editor.select(editor.controller.textStorage.length)
        editor.type(" more")
        editor.settle()
        #expect(editor.link(at: 3) == nil)
    }

    @Test func commandInsertLinksWithoutBoundary() {
        let editor = makeEditor(rules: PluginFixtures.referenceRules)
        editor.controller.replaceText(in: NSRange(location: 0, length: 0), with: "see D45")
        editor.settle()
        #expect(editor.link(at: 4) == "https://phabricator.services.mozilla.com/D45")
    }

    @Test func autoLinkIsItsOwnUndoStep() {
        let editor = makeEditor(rules: PluginFixtures.referenceRules)
        editor.controller.replaceText(in: NSRange(location: 0, length: 0), with: "see D45")
        editor.settle()
        #expect(editor.link(at: 4) != nil)
        editor.controller.undoManager.undo()
        editor.settle()
        #expect(editor.string == "see D45")
        #expect(editor.link(at: 4) == nil)
        editor.controller.undoManager.undo()
        editor.settle()
        #expect(editor.string == "")
    }

    @Test func multipleMatchesInOneEditShareOneStep() {
        let editor = makeEditor()
        editor.controller.replaceText(in: NSRange(location: 0, length: 0), with: "https://a.example and https://b.example")
        editor.settle()
        #expect(editor.link(at: 2) == "https://a.example")
        #expect(editor.link(at: 25) == "https://b.example")
        editor.controller.undoManager.undo()
        #expect(editor.link(at: 2) == nil)
        #expect(editor.link(at: 25) == nil)
        #expect(editor.string == "https://a.example and https://b.example")
    }

    @Test func emailPatternStaysLinearOnLongLocalPartRuns() {
        let line = String(repeating: "a", count: 20_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = AutoLinkRule.email.pattern.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        }
        #expect(elapsed < .milliseconds(200), "took \(elapsed)")
    }

    @Test func emailPatternStillMatchesAfterPunctuation() {
        let line = "(fred.x+y@example.org) and -a@b.co"
        let matches = AutoLinkRule.email.pattern.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        #expect(matches.map { (line as NSString).substring(with: $0.range(at: 1)) } == ["fred.x+y@example.org", "-a@b.co"])
    }

    @Test func keystrokeInALongParagraphScansOnlyNearTheEdit() throws {
        let words = Array(repeating: "word", count: 40_000).joined(separator: " ")
        let editor = makeEditor(words)
        let plugin = try #require(editor.controller.plugins.first as? AutoLinkPlugin)
        let end = editor.controller.textStorage.length
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<50 {
                _ = plugin.matches(around: NSRange(location: end - 1, length: 1), origin: .user, controller: editor.controller)
            }
        }
        #expect(elapsed < .milliseconds(100), "took \(elapsed)")
    }

    @Test func multiWordRuleStillLinksWhenTheEditIsOnTheLastWord() {
        let editor = makeEditor("see bug    42", rules: PluginFixtures.referenceRules)
        editor.select(editor.controller.textStorage.length)
        editor.type(" ")
        editor.settle()
        #expect(editor.link(at: 4) == "https://bugzilla.mozilla.org/show_bug.cgi?id=42")
    }

    private func paste(_ text: String, into editor: HeadlessEditor) {
        _ = editor.controller.dispatchPaste(PasteEvent(text: text, selection: editor.controller.currentSelection))
        editor.settle()
    }

    @Test func pasteOfPlainURLBecomesLink() {
        let editor = makeEditor(rules: [.url])
        paste("https://example.com", into: editor)
        #expect(editor.link(at: 0) == "https://example.com")
        #expect(editor.linkRange(at: 0) == NSRange(location: 0, length: 19))
    }

    @Test func pasteOfTextWithURLLinksOnlyTheURL() {
        let editor = makeEditor(rules: [.url])
        paste("see https://example.com for details", into: editor)
        #expect(editor.link(at: 4) == "https://example.com")
        #expect(editor.linkRange(at: 4) == NSRange(location: 4, length: 19))
        #expect(editor.link(at: 0) == nil)
        #expect(editor.link(at: 23) == nil)
    }

    @Test func trailingPunctuationIsExcluded() throws {
        let editor = makeEditor(rules: [.url])
        paste("visit https://example.com.", into: editor)
        #expect(editor.link(at: 6) == "https://example.com")
        let range = try #require(editor.linkRange(at: 6))
        #expect((editor.string as NSString).substring(with: range) == "https://example.com")
    }

    @Test func urlInCodeBlockIsLeftAlone() {
        let editor = makeEditor("```\nhttps://example.com\n```", rules: [.url])
        #expect(editor.controller.textStorage.markdownBlock(at: 0)?.isCode == true)
        #expect(editor.link(at: 0) == nil)
        #expect(editor.link(at: 5) == nil)
    }

    @Test func alreadyLinkedTextIsntDoubleLinked() {
        let editor = makeEditor("[https://example.com](https://other.example) trailing", rules: [.url])
        #expect(editor.link(at: 0) == "https://other.example")
        editor.select(editor.controller.textStorage.length)
        paste(" visit https://added.example", into: editor)
        #expect(editor.link(at: 0) == "https://other.example")
        #expect(editor.linkRange(at: 0) == NSRange(location: 0, length: 19))
        let added = (editor.string as NSString).range(of: "https://added.example").location
        #expect(editor.link(at: added) == "https://added.example")
    }

    @Test func multipleURLsInOnePasteAllGetLinked() {
        let editor = makeEditor(rules: [.url])
        paste("https://a.com and https://b.com", into: editor)
        #expect(editor.link(at: 0) == "https://a.com")
        let second = (editor.string as NSString).range(of: "https://b.com").location
        #expect(editor.link(at: second) == "https://b.com")
    }

    @Test func emailRuleProducesMailtoLink() {
        let editor = makeEditor(rules: [.email])
        paste("reach me at user@example.com please", into: editor)
        let start = (editor.string as NSString).range(of: "user@example.com").location
        #expect(editor.link(at: start) == "mailto:user@example.com")
    }

    @Test func notEditableDoesNothing() {
        let editor = makeEditor()
        editor.type("https://example.com")
        editor.controller.isEditable = false
        editor.type(" ")
        editor.settle()
        #expect(editor.link(at: 3) == nil)
    }
}

#if canImport(AppKit) && os(macOS)
import AppKit

@Suite("Auto-link plugin host (macOS, .serialized)")
@MainActor
struct AutoLinkPluginHostTests {
    private func makeHarness(_ markdown: String = "") -> EditorHarness {
        let harness = EditorHarness(markdown: markdown)
        harness.controller.register(plugin: AutoLinkPlugin(rules: [.url] + PluginFixtures.referenceRules))
        harness.select(harness.string.utf16.count)
        return harness
    }

    @Test func spaceAfterURLLinksAndUndoRemovesOnlyTheLink() {
        let harness = makeHarness()
        harness.type("see https://example.com")
        harness.settle()
        #expect(harness.storage.markdownLink(at: 6) == nil)
        harness.type(" ")
        harness.settle()
        #expect(harness.storage.markdownLink(at: 6) == "https://example.com")
        #expect(harness.textView.typingAttributes[.link] == nil)
        harness.undo()
        #expect(harness.storage.markdownLink(at: 6) == nil)
        #expect(harness.string == "see https://example.com ")
    }

    @Test func returnAfterReferenceLinksIt() {
        let harness = makeHarness()
        harness.typeEach("fixed in D77")
        #expect(harness.storage.markdownLink(at: 9) == nil)
        harness.insertNewline()
        harness.settle()
        #expect(harness.storage.markdownLink(at: 9) == "https://phabricator.services.mozilla.com/D77")
        #expect(harness.markdown == "fixed in [D77](https://phabricator.services.mozilla.com/D77)")
    }

    @Test func typingInsideMarkedTextDoesNotLink() {
        let harness = makeHarness("D12")
        harness.setMarkedText(" ")
        harness.settle()
        #expect(harness.storage.markdownLink(at: 0) == nil)
        #expect(harness.textView.hasMarkedText())
    }
}
#endif
