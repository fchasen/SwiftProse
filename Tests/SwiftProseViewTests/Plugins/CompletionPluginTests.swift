import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Completion plugin", .serialized)
@MainActor
struct CompletionPluginTests {
    private func makeEditor(_ markdown: String = "", allowedInCode: Bool = false) -> (HeadlessEditor, CompletionPlugin) {
        let editor = HeadlessEditor(markdown: markdown)
        let plugin = PluginFixtures.mentionPlugin(allowedInCode: allowedInCode)
        plugin.attach(to: editor.controller)
        return (editor, plugin)
    }

    @Test func attachRegistersOnce() {
        let (editor, plugin) = makeEditor()
        plugin.attach(to: editor.controller)
        #expect(editor.controller.plugins.count == 1)
        #expect(plugin.key.name == CompletionPlugin.keyName)
    }

    @Test func triggerOpensSessionAtDocumentStart() {
        let (editor, plugin) = makeEditor()
        var changes: [CompletionSession?] = []
        plugin.onSessionChanged = { changes.append($0) }
        editor.type("@")
        let session = plugin.session(controller: editor.controller)
        #expect(session?.context.triggerID == "mention")
        #expect(session?.context.query == "")
        #expect(session?.context.range == NSRange(location: 0, length: 1))
        #expect(changes.count == 1)
    }

    @Test func typingExtendsQuery() {
        let (editor, plugin) = makeEditor("hi")
        editor.typeEach(" @fre")
        let session = plugin.session(controller: editor.controller)
        #expect(session?.context.query == "fre")
        #expect(session?.context.range == NSRange(location: 3, length: 4))
    }

    @Test func committingAMentionReplacesTheTriggerAndQueryWithAnAtom() throws {
        let (editor, plugin) = makeEditor("hi")
        editor.typeEach(" @fr")
        let session = try #require(plugin.session(controller: editor.controller))
        editor.controller.insertInlineContent(
            .userMention(handle: "fred", displayName: "@fred"),
            markdownSource: "@fred",
            replacing: session.context.range
        )
        #expect(editor.string == "hi \u{FFFC} ")
        #expect(editor.selection == NSRange(location: 5, length: 0))
        #expect(editor.controller.inlineContentKind(at: 3) == "userMention")
        #expect(editor.controller.markdown().hasPrefix("hi @fred"))
    }

    @Test func whitespaceClosesSession() {
        let (editor, plugin) = makeEditor()
        editor.typeEach("@fr")
        editor.type(" ")
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func secondTriggerClosesSession() {
        let (editor, plugin) = makeEditor()
        editor.typeEach("@fr")
        editor.type("#")
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func triggerInsideWordDoesNotOpen() {
        let (editor, plugin) = makeEditor("mail")
        editor.type("@")
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func triggerAfterLineBreakOpens() {
        let (editor, plugin) = makeEditor("a")
        editor.type("\u{2028}")
        editor.type("@")
        #expect(plugin.session(controller: editor.controller)?.context.range.location == 2)
    }

    @Test func triggerInCodeBlockRespectsAllowedInCode() {
        let (editor, plugin) = makeEditor("```\nx \n```")
        editor.select(2)
        editor.type("@")
        #expect(plugin.session(controller: editor.controller) == nil)

        let (codeEditor, codePlugin) = makeEditor("```\nx \n```", allowedInCode: true)
        codeEditor.select(2)
        codeEditor.type("@")
        #expect(codePlugin.session(controller: codeEditor.controller) != nil)
    }

    @Test func backspaceShrinksQueryAndClosesAtTrigger() {
        let (editor, plugin) = makeEditor()
        editor.typeEach("@fre")
        editor.backspace()
        #expect(plugin.session(controller: editor.controller)?.context.query == "fr")
        #expect(plugin.session(controller: editor.controller)?.context.range == NSRange(location: 0, length: 3))
        editor.backspace()
        editor.backspace()
        #expect(plugin.session(controller: editor.controller)?.context.query == "")
        editor.backspace()
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func externalEditRederivesQuery() {
        let (editor, plugin) = makeEditor()
        editor.typeEach("@fr")
        editor.controller.textStorage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "e")
        editor.controller.flushDocumentChanges()
        #expect(plugin.session(controller: editor.controller)?.context.query == "fer")
        #expect(plugin.session(controller: editor.controller)?.context.range == NSRange(location: 0, length: 4))
        editor.controller.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "x")
        editor.controller.flushDocumentChanges()
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func setMarkdownCancelsSession() {
        let (editor, plugin) = makeEditor()
        editor.typeEach("@fr")
        editor.controller.setMarkdown("@fr")
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func arrowsMoveHighlightWithinItemCount() {
        let (editor, plugin) = makeEditor()
        editor.typeEach("@f")
        #expect(!editor.key(PluginKeyName.arrowDown))
        plugin.updateItemCount(3, controller: editor.controller)
        #expect(editor.key(PluginKeyName.arrowDown))
        #expect(editor.key(PluginKeyName.arrowDown))
        #expect(editor.key(PluginKeyName.arrowDown))
        #expect(plugin.session(controller: editor.controller)?.highlightedIndex == 2)
        #expect(editor.key(PluginKeyName.arrowUp))
        #expect(plugin.session(controller: editor.controller)?.highlightedIndex == 1)
        plugin.updateItemCount(1, controller: editor.controller)
        #expect(plugin.session(controller: editor.controller)?.highlightedIndex == 0)
    }

    @Test func escapeCancels() {
        let (editor, plugin) = makeEditor()
        editor.typeEach("@f")
        #expect(editor.key(PluginKeyName.escape))
        #expect(plugin.session(controller: editor.controller) == nil)
        #expect(!editor.key(PluginKeyName.escape))
    }

    @Test func enterKeyCommitsWhenItemsExist() {
        let (editor, plugin) = makeEditor()
        var committed: [CompletionSession] = []
        plugin.onCommit = { controller, session in
            committed.append(session)
            controller.replaceText(in: session.context.range, with: "@fred ")
        }
        editor.typeEach("@fr")
        plugin.updateItemCount(2, controller: editor.controller)
        plugin.updateHighlight(1, controller: editor.controller)
        #expect(editor.key(PluginKeyName.enter))
        #expect(committed.map(\.highlightedIndex) == [1])
        #expect(committed.first?.context.query == "fr")
        #expect(editor.string == "@fred ")
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func enterKeyWithoutItemsCancelsAndPassesThrough() {
        let (editor, plugin) = makeEditor()
        var committed = 0
        plugin.onCommit = { _, _ in committed += 1 }
        editor.typeEach("@fr")
        #expect(!editor.key(PluginKeyName.enter))
        #expect(committed == 0)
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func newlineTextInputCommitsWhenItemsExist() {
        let (editor, plugin) = makeEditor("hi")
        var committed: [CompletionSession] = []
        plugin.onCommit = { controller, session in
            committed.append(session)
            controller.replaceText(in: session.context.range, with: "@fred ")
        }
        editor.typeEach(" @fr")
        plugin.updateItemCount(1, controller: editor.controller)
        let inserted = editor.type("\n")
        #expect(!inserted)
        #expect(editor.string == "hi @fr")
        editor.settle()
        #expect(committed.count == 1)
        #expect(editor.string == "hi @fred ")
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func newlineTextInputWithoutItemsInsertsNewline() {
        let (editor, plugin) = makeEditor()
        var committed = 0
        plugin.onCommit = { _, _ in committed += 1 }
        editor.typeEach("@fr")
        #expect(editor.type("\n"))
        editor.settle()
        #expect(committed == 0)
        #expect(plugin.session(controller: editor.controller) == nil)
        #expect(editor.string == "@fr\n")
    }

    @Test func newlineCommitIsDroppedWhenSessionClosesFirst() {
        let (editor, plugin) = makeEditor()
        var committed = 0
        plugin.onCommit = { _, _ in committed += 1 }
        editor.typeEach("@fr")
        plugin.updateItemCount(1, controller: editor.controller)
        #expect(!editor.type("\n"))
        plugin.cancel(controller: editor.controller)
        editor.settle()
        #expect(committed == 0)
    }

    @Test func caretLeavingTheQueryCancelsTheSession() {
        let (editor, plugin) = makeEditor("hello world")
        var committed: [CompletionSession] = []
        plugin.onCommit = { _, session in committed.append(session) }
        editor.typeEach(" @fr")
        plugin.updateItemCount(3, controller: editor.controller)
        editor.select(2)
        editor.controller.selectionDidChange(NSRange(location: 2, length: 0))
        #expect(plugin.session(controller: editor.controller) == nil)
        #expect(!editor.key(PluginKeyName.enter))
        #expect(committed.isEmpty)
    }

    @Test func caretInsideTheQueryKeepsTheSession() {
        let (editor, plugin) = makeEditor("hello world")
        editor.typeEach(" @fr")
        editor.select(14)
        editor.controller.selectionDidChange(NSRange(location: 14, length: 0))
        #expect(plugin.session(controller: editor.controller)?.context.range == NSRange(location: 12, length: 3))
        editor.select(13)
        editor.controller.selectionDidChange(NSRange(location: 13, length: 0))
        #expect(plugin.session(controller: editor.controller) != nil)
        editor.select(12)
        editor.controller.selectionDidChange(NSRange(location: 12, length: 0))
        #expect(plugin.session(controller: editor.controller) == nil)
    }

    @Test func commitWithReplaceTextIsUndoable() {
        let (editor, plugin) = makeEditor()
        plugin.onCommit = { controller, session in
            controller.replaceText(in: session.context.range, with: "@fred ")
        }
        editor.typeEach("@fr")
        plugin.updateItemCount(1, controller: editor.controller)
        #expect(editor.key(PluginKeyName.enter))
        #expect(editor.string == "@fred ")
        editor.controller.undoManager.undo()
        #expect(editor.string == "@fr")
    }
}

#if canImport(AppKit) && os(macOS)
import AppKit

@Suite("Completion plugin host (macOS, .serialized)")
@MainActor
struct CompletionPluginHostTests {
    private func keyEvent(_ harness: EditorHarness, keyCode: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    private func makeHarness(_ markdown: String = "") -> (EditorHarness, CompletionPlugin) {
        let harness = EditorHarness(markdown: markdown)
        let plugin = PluginFixtures.mentionPlugin()
        plugin.attach(to: harness.controller)
        harness.select(harness.string.utf16.count)
        return (harness, plugin)
    }

    @Test func typingThroughTextViewOpensAndExtends() {
        let (harness, plugin) = makeHarness("hi")
        harness.typeEach(" @fre")
        #expect(plugin.session(controller: harness.controller)?.context.query == "fre")
        #expect(plugin.session(controller: harness.controller)?.context.range == NSRange(location: 3, length: 4))
        harness.deleteBackward()
        harness.settle()
        #expect(plugin.session(controller: harness.controller)?.context.query == "fr")
        harness.type(" ")
        #expect(plugin.session(controller: harness.controller) == nil)
    }

    @Test func returnKeyCommitsWithoutInsertingNewline() {
        let (harness, plugin) = makeHarness()
        plugin.onCommit = { controller, session in
            controller.replaceText(in: session.context.range, with: "@fred ")
        }
        harness.typeEach("@fr")
        plugin.updateItemCount(1, controller: harness.controller)
        harness.step { harness.textView.keyDown(with: keyEvent(harness, keyCode: 36, characters: "\r")) }
        harness.settle()
        #expect(harness.string == "@fred ")
        #expect(plugin.session(controller: harness.controller) == nil)
    }

    @Test func returnKeyWithoutItemsInsertsNewline() {
        let (harness, plugin) = makeHarness()
        harness.typeEach("@fr")
        harness.step { harness.textView.keyDown(with: keyEvent(harness, keyCode: 36, characters: "\r")) }
        harness.settle()
        #expect(plugin.session(controller: harness.controller) == nil)
        #expect(harness.string.hasPrefix("@fr\n"))
    }

    @Test func returnAfterMovingTheCaretInsertsANewline() {
        let (harness, plugin) = makeHarness("hello\n\nworld")
        var committed = 0
        plugin.onCommit = { _, _ in committed += 1 }
        harness.typeEach(" @fr")
        plugin.updateItemCount(1, controller: harness.controller)
        harness.select(2)
        #expect(plugin.session(controller: harness.controller) == nil)
        harness.step { harness.textView.keyDown(with: keyEvent(harness, keyCode: 36, characters: "\r")) }
        harness.settle()
        #expect(committed == 0)
        #expect(harness.string.hasPrefix("he\nllo"))
    }

    @Test func newlineInsertTextCommits() {
        let (harness, plugin) = makeHarness()
        var committed = 0
        plugin.onCommit = { controller, session in
            committed += 1
            controller.replaceText(in: session.context.range, with: "@fred ")
        }
        harness.typeEach("@fr")
        plugin.updateItemCount(1, controller: harness.controller)
        harness.type("\n")
        harness.settle()
        #expect(committed == 1)
        #expect(harness.string == "@fred ")
    }

    @Test func returnKeyCommitInsertsAMentionAtom() {
        let (harness, plugin) = makeHarness("hi")
        plugin.onCommit = { controller, session in
            controller.insertInlineContent(
                .userMention(handle: "fred", displayName: "@fred"),
                markdownSource: "@fred",
                replacing: session.context.range
            )
        }
        harness.typeEach(" @fre")
        plugin.updateItemCount(1, controller: harness.controller)
        harness.step { harness.textView.keyDown(with: keyEvent(harness, keyCode: 36, characters: "\r")) }
        harness.settle()
        #expect(harness.string == "hi \u{FFFC} ")
        #expect(harness.selection == NSRange(location: 5, length: 0))
        #expect(harness.controller.markdown().hasPrefix("hi @fred"))
        #expect(plugin.session(controller: harness.controller) == nil)
    }

    @Test func enterIsNotTakenWhileTextIsMarked() {
        let (harness, plugin) = makeHarness()
        var committed = 0
        plugin.onCommit = { _, _ in committed += 1 }
        harness.typeEach("@fr")
        plugin.updateItemCount(1, controller: harness.controller)
        harness.setMarkedText("に")
        #expect(harness.textView.hasMarkedText())
        #expect(plugin.props.handleKeyDown?(harness.controller, PluginKeyName.enter) == false)
        #expect(plugin.props.handleTextInput?(harness.controller, harness.selection, "\n") == false)
        harness.controller.drainDeferredEdits()
        #expect(committed == 0)
        harness.unmarkText()
        harness.settle()
        #expect(plugin.session(controller: harness.controller)?.context.query == "frに")
    }
}
#endif
