import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
final class SourceTyping {
    let controller: SourceEditorController

    init(_ controller: SourceEditorController) {
        self.controller = controller
    }

    @discardableResult
    func type(_ text: String) -> Bool {
        let range = controller.currentSelection
        guard controller.hostShouldChangeText(in: range, replacement: text) else { return false }
        controller.textStorage.replaceCharacters(in: range, with: text)
        controller.setSelection(NSRange(location: range.location + (text as NSString).length, length: 0))
        controller.selectionDidChange(controller.currentSelection)
        controller.flushDocumentChanges()
        return true
    }

    func typeEach(_ text: String) {
        for character in text { type(String(character)) }
    }

    func key(_ name: String) -> Bool {
        controller.dispatchKey(name)
    }

    func settle() {
        controller.flushDocumentChanges()
        controller.drainDeferredEdits()
    }
}

@Suite("Source controller")
@MainActor
struct SourceControllerTests {
    @Test func formatterEditsAreSingleUndoStepsWithRedo() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let controller = SourceEditorController(text: "a word b", undoManager: manager)
        controller.setSelection(NSRange(location: 2, length: 4))
        #expect(controller.perform(.bold))
        #expect(controller.text == "a **word** b")
        #expect(controller.currentSelection == NSRange(location: 4, length: 4))
        #expect(controller.undoManager.undoActionName == "Bold")
        controller.setSelection(NSRange(location: 0, length: 0))
        #expect(controller.perform(.heading(level: 2)))
        #expect(controller.text == "## a **word** b")
        controller.undoManager.undo()
        #expect(controller.text == "a **word** b")
        controller.undoManager.undo()
        #expect(controller.text == "a word b")
        #expect(controller.currentSelection == NSRange(location: 2, length: 4))
        controller.undoManager.redo()
        #expect(controller.text == "a **word** b")
        #expect(controller.currentSelection == NSRange(location: 4, length: 4))
        controller.undoManager.redo()
        #expect(controller.text == "## a **word** b")
    }

    @Test func undoRestylesTheRestoredLines() {
        let controller = SourceEditorController(text: "title")
        controller.perform(.heading(level: 1))
        #expect(controller.textStorage.markdownBlock(at: 0) == nil)
        let probeFont = { (controller.textStorage.attribute(.font, at: controller.text.utf16.count - 1, effectiveRange: nil) as? PlatformFont)?.fontTraits ?? [] }
        #expect(probeFont().contains(.bold))
        controller.undoManager.undo()
        #expect(controller.text == "title")
        #expect(!probeFont().contains(.bold))
    }

    @Test func toolbarStatesFollowTheSelectionAndEditability() {
        let controller = SourceEditorController(text: "## **bold** plain")
        controller.setSelection(NSRange(location: 6, length: 2))
        let actions: [EditorAction] = [.bold, .heading(level: 2), .indent, .insertTable(rows: 2, columns: 3), .deleteTableRow]
        let states = controller.actionStates(for: actions)
        #expect(states.isActive(.bold))
        #expect(states.isActive(.heading(level: 2)))
        #expect(!states.canPerform(.indent))
        #expect(states.canPerform(.insertTable(rows: 2, columns: 3)))
        #expect(!states.canPerform(.deleteTableRow))
        controller.isEditable = false
        #expect(controller.actionStates(for: actions).disabled == Set(actions.map(\.stableID)))
        #expect(!controller.perform(.bold))
    }

    @Test func insertionsReplaceTheGivenRange() {
        let controller = SourceEditorController(text: "one two")
        controller.insertMarkdown("![img](zilla-upload://1) ", replacing: NSRange(location: 4, length: 0), label: "Insert Image")
        #expect(controller.text == "one ![img](zilla-upload://1) two")
        #expect(controller.currentSelection == NSRange(location: 29, length: 0))
        controller.undoManager.undo()
        #expect(controller.text == "one two")
    }

    @Test func insertLinkUsesTheSelectionAsLabel() {
        let controller = SourceEditorController(text: "see this")
        controller.setSelection(NSRange(location: 4, length: 4))
        controller.insertLink(label: "bug 1", url: "https://b.test/1")
        #expect(controller.text == "see [this](https://b.test/1)")
        #expect(controller.currentSelection == NSRange(location: 28, length: 0))
        let empty = SourceEditorController(text: "see ")
        empty.setSelection(NSRange(location: 4, length: 0))
        empty.insertLink(label: "bug 1", url: "https://b.test/1")
        #expect(empty.text == "see [bug 1](https://b.test/1)")
        let code = SourceEditorController(text: "```\n\n```")
        code.setSelection(NSRange(location: 4, length: 0))
        code.insertLink(label: "x", url: "https://x")
        #expect(code.text == "```\n[x](https://x)\n```")
    }

    @Test func externalTextReplacesTheDocumentWithoutPushing() {
        let controller = SourceEditorController(text: "a")
        var pushes: [String] = []
        controller.textSink = { pushes.append($0) }
        controller.applyExternalText("# b")
        #expect(controller.text == "# b")
        #expect(pushes.isEmpty)
        #expect(!controller.undoManager.canUndo)
        controller.setSelection(NSRange(location: 3, length: 0))
        controller.insertMarkdown("c", label: "Insert")
        #expect(pushes == ["# bc"])
    }
}

@Suite("Line-start insertion")
@MainActor
struct LineStartInsertionTests {
    static let label = InlineContentRule(id: "label", pattern: #"\{nav(?:\s+|\s*,\s*)icon=([A-Za-z0-9_\-]+)\s*,\s*name=([^}\n]*)\}"#) { match in
        .custom(kind: "label", label: match.capture(2) ?? "", systemImage: "tag")
    }

    static let praise = "{nav, icon=thumbs-up, name=praise:} "
    static let nitpick = "{nav, icon=info-circle, name=nitpick:} "

    private func source(_ text: String, caret: Int) -> SourceEditorController {
        let controller = SourceEditorController(text: text)
        controller.setSelection(NSRange(location: caret, length: 0))
        return controller
    }

    @Test func sourceInsertsAfterTheLinePrefix() {
        let controller = source("first\nsecond line", caret: 12)
        controller.insertMarkdownAtLineStart(Self.praise, replacingLeading: Self.label)
        #expect(controller.text == "first\n{nav, icon=thumbs-up, name=praise:} second line")
        #expect(controller.currentSelection == NSRange(location: 6 + (Self.praise as NSString).length, length: 0))
        let prefixed = source("> - [ ] item", caret: 10)
        prefixed.insertMarkdownAtLineStart(Self.praise, replacingLeading: Self.label)
        #expect(prefixed.text == "> - [ ] {nav, icon=thumbs-up, name=praise:} item")
        let empty = source("", caret: 0)
        empty.insertMarkdownAtLineStart(Self.praise, replacingLeading: Self.label)
        #expect(empty.text == Self.praise)
    }

    @Test func sourceReplacesAnExistingLeadingToken() {
        let existing = source("{nav, icon=thumbs-up, name=praise:} body", caret: 40)
        existing.insertMarkdownAtLineStart(Self.nitpick, replacingLeading: Self.label)
        #expect(existing.text == "{nav, icon=info-circle, name=nitpick:} body")
        let spelling = source("{nav,  icon=thumbs-up, name=praise:}   body", caret: 0)
        spelling.insertMarkdownAtLineStart(Self.nitpick, replacingLeading: Self.label)
        #expect(spelling.text == "{nav, icon=info-circle, name=nitpick:} body")
    }

    @Test func richReplacesALeadingAtomAndInsertsAtTheParagraphStart() {
        let controller = EditorController(
            markdown: "first\n\n- {nav, icon=thumbs-up, name=praise:} body",
            inlineContentRules: [Self.label]
        )
        let ns = controller.textStorage.string as NSString
        controller.setSelection(NSRange(location: ns.length, length: 0))
        controller.insertMarkdownAtLineStart(Self.nitpick, replacingLeading: Self.label)
        #expect(controller.markdown() == "first\n\n- {nav, icon=info-circle, name=nitpick:} body")
        controller.setSelection(NSRange(location: 2, length: 0))
        controller.insertMarkdownAtLineStart(Self.praise, replacingLeading: Self.label)
        #expect(controller.markdown() == "{nav, icon=thumbs-up, name=praise:} first\n\n- {nav, icon=info-circle, name=nitpick:} body")
    }
}

@Suite("Editor handle")
@MainActor
struct EditorHandleTests {
    private func handle(_ markdown: String, mode: EditorMode) -> EditorHandle {
        let rich = EditorController(markdown: markdown)
        let source = SourceEditorController(text: mode == .source ? markdown : "")
        return EditorHandle(richController: rich, sourceController: source, mode: mode)
    }

    @Test func handleRoutesInsertionsToTheActiveMode() {
        for mode in EditorMode.allCases {
            let handle = handle("see this", mode: mode)
            handle.setSelection(NSRange(location: 4, length: 4))
            #expect(handle.selection == NSRange(location: 4, length: 4))
            handle.insertLink(label: "bug 1", url: "https://b.test/1")
            #expect(handle.markdown() == "see [this](https://b.test/1)")
            handle.insertMarkdown(" **x**", replacing: NSRange(location: handle.textStorage.length, length: 0))
            #expect(handle.markdown() == "see [this](https://b.test/1) **x**")
            #expect(handle.activeEditor === (mode == .rich ? handle.richController as AnyObject : handle.sourceController as AnyObject))
        }
    }

    @Test func synchronizeKeepsUntouchedBytes() {
        let original = "* item\n\nSetext\n======\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n"
        let handle = handle(original, mode: .rich)
        handle.synchronize(for: .source)
        handle.mode = .source
        #expect(handle.sourceController.text == original)
        handle.synchronize(for: .rich)
        handle.mode = .rich
        #expect(handle.richController.markdown() == original)

        handle.synchronize(for: .source)
        handle.mode = .source
        handle.sourceController.insertMarkdown("\nmore", replacing: NSRange(location: handle.sourceController.textStorage.length, length: 0))
        let edited = handle.sourceController.text
        handle.synchronize(for: .rich)
        handle.mode = .rich
        #expect(handle.richController.markdown() == edited)
    }
}

@Suite("Completion in source mode")
@MainActor
struct SourceCompletionTests {
    private func makeEditor(_ text: String = "") -> (SourceEditorController, SourceTyping, CompletionPlugin) {
        let controller = SourceEditorController(text: text)
        controller.setSelection(NSRange(location: (text as NSString).length, length: 0))
        let plugin = CompletionPlugin(triggers: [CompletionTrigger(id: "mention", prefix: "@")])
        plugin.attach(to: controller)
        return (controller, SourceTyping(controller), plugin)
    }

    @Test func triggerOpensAndQueryExtends() {
        let (controller, typing, plugin) = makeEditor("hi")
        var changes: [CompletionSession?] = []
        plugin.onSessionChanged = { changes.append($0) }
        typing.typeEach(" @fre")
        let session = plugin.session(controller: controller)
        #expect(session?.context.query == "fre")
        #expect(session?.context.range == NSRange(location: 3, length: 4))
        #expect(!changes.isEmpty)
        typing.type(" ")
        #expect(plugin.session(controller: controller) == nil)
    }

    @Test func triggerInsideCodeOrAWordDoesNotOpen() {
        let (controller, typing, plugin) = makeEditor("mail")
        typing.type("@")
        #expect(plugin.session(controller: controller) == nil)
        let (code, codeTyping, codePlugin) = makeEditor("```\n")
        codeTyping.type("@")
        #expect(codePlugin.session(controller: code) == nil)
        let (span, spanTyping, spanPlugin) = makeEditor("`a `")
        span.setSelection(NSRange(location: 3, length: 0))
        spanTyping.type("@")
        #expect(spanPlugin.session(controller: span) == nil)
    }

    @Test func enterCommitsAndInsertsTheMarkdownSource() {
        let (controller, typing, plugin) = makeEditor("cc")
        var committed: [CompletionSession] = []
        plugin.onCommit = { editor, session in
            committed.append(session)
            editor.insertInlineContent(.userMention(handle: "fred", displayName: "@fred"), markdownSource: "@fred", replacing: session.context.range)
        }
        typing.typeEach(" @fr")
        plugin.updateItemCount(2, controller: controller)
        plugin.updateHighlight(1, controller: controller)
        #expect(typing.key(PluginKeyName.enter))
        #expect(committed.map(\.highlightedIndex) == [1])
        #expect(controller.text == "cc @fred ")
        #expect(plugin.session(controller: controller) == nil)
        controller.undoManager.undo()
        #expect(controller.text == "cc @fr")
    }

    @Test func newlineInputCommitsThroughTheDeferredPath() {
        let (controller, typing, plugin) = makeEditor()
        plugin.onCommit = { editor, session in
            editor.replaceText(in: session.context.range, with: "@fred ")
        }
        typing.typeEach("@fr")
        plugin.updateItemCount(1, controller: controller)
        #expect(!typing.type("\n"))
        #expect(controller.text == "@fr")
        typing.settle()
        #expect(controller.text == "@fred ")
    }

    @Test func escapeCancelsAndArrowsMoveTheHighlight() {
        let (controller, typing, plugin) = makeEditor()
        typing.typeEach("@a")
        plugin.updateItemCount(3, controller: controller)
        #expect(typing.key(PluginKeyName.arrowDown))
        #expect(plugin.session(controller: controller)?.highlightedIndex == 1)
        #expect(typing.key(PluginKeyName.arrowUp))
        #expect(plugin.session(controller: controller)?.highlightedIndex == 0)
        #expect(typing.key(PluginKeyName.escape))
        #expect(plugin.session(controller: controller) == nil)
    }

    @Test func pluginAttachesToBothControllersThroughTheHandle() {
        let rich = EditorController(markdown: "")
        let source = SourceEditorController(text: "")
        let handle = EditorHandle(richController: rich, sourceController: source, mode: .source)
        let plugin = CompletionPlugin(triggers: [CompletionTrigger(id: "mention", prefix: "@")])
        plugin.attach(to: rich)
        plugin.attach(to: source)
        plugin.attach(to: source)
        let typing = SourceTyping(source)
        typing.typeEach("@x")
        #expect(plugin.session(controller: handle)?.context.query == "x")
        plugin.updateItemCount(4, controller: handle)
        #expect(plugin.session(controller: source)?.itemCount == 4)
        plugin.cancel(controller: handle)
        #expect(plugin.session(controller: source) == nil)
        #expect(rich.plugins.count == 1)
    }
}
