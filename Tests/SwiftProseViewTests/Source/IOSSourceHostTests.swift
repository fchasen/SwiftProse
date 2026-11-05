#if canImport(UIKit) && os(iOS)
import Testing
import UIKit
import SwiftUI
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
final class IOSSourceHarness {
    final class Box {
        var text: String
        var pushes: [String] = []
        var submits = 0
        init(_ text: String) { self.text = text }
    }

    let controller: SourceEditorController
    let box: Box
    let coordinator: ProseSourceTextViewIOS.Coordinator
    let textView: ProseSourceUITextView

    init(_ text: String = "", submits: Bool = false) {
        let box = Box(text)
        self.box = box
        controller = SourceEditorController(text: text)
        let binding = Binding<String>(get: { box.text }, set: { box.text = $0; box.pushes.append($0) })
        let representable = ProseSourceTextViewIOS(
            controller: controller,
            text: binding,
            sizing: .fillContainer,
            spellChecking: .off,
            onSubmit: submits ? { box.submits += 1 } : nil
        )
        coordinator = representable.makeCoordinator()
        textView = representable.makeTextView(coordinator: coordinator)
        textView.pasteboard = UIPasteboard(name: UIPasteboard.Name("swiftprose.source.\(UUID().uuidString)"), create: true)!
        controller.textContainer.size = CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        textView.layoutIfNeeded()
    }

    var string: String { controller.text }

    func select(_ location: Int, _ length: Int = 0) {
        textView.selectedRange = NSRange(location: location, length: length)
        coordinator.textViewDidChangeSelection(textView)
    }

    @discardableResult
    func key(_ text: String) -> Bool {
        let range = textView.selectedRange
        let allowed = coordinator.textView(textView, shouldChangeTextIn: range, replacementText: text)
        if allowed { textView.insertText(text) }
        coordinator.textViewDidChange(textView)
        return allowed
    }

    func type(_ text: String) {
        for character in text { key(String(character)) }
    }

    func keymapCommand(_ id: String) -> UIKeyCommand? {
        textView.keyCommands?.first { ($0.propertyList as? String) == id }
    }

    func traits(at index: Int) -> FontTraits {
        (controller.textStorage.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont)?.fontTraits ?? []
    }
}

@MainActor
@Suite("iOS source host")
struct IOSSourceHostTests {
    @Test func hostsTextKit2AndRoutesUndoToTheController() {
        let host = IOSSourceHarness("a")
        #expect(host.textView.textLayoutManager != nil)
        #expect(host.textView.textStorage === host.controller.textStorage)
        #expect(host.textView.undoManager === host.controller.undoManager)
        #expect(host.controller.effectiveUndoManager === host.controller.undoManager)
        #expect(!host.textView.allowsEditingTextAttributes)
    }

    @Test func typingStylesAndWritesTheBinding() {
        let host = IOSSourceHarness("title")
        host.select(0)
        host.type("# ")
        #expect(host.string == "# title")
        #expect(host.traits(at: 3).contains(.bold))
        #expect(host.box.text == "# title")
    }

    @Test func keymapCommandsFormatTheSelectionAsOneUndoStep() throws {
        let host = IOSSourceHarness("hello world")
        host.select(6, 5)
        let bold = try #require(host.keymapCommand("bold"))
        #expect(bold.input == "b")
        #expect(bold.modifierFlags == .command)
        host.textView.handleKeymapCommand(bold)
        #expect(host.string == "hello **world**")
        #expect(host.textView.selectedRange == NSRange(location: 8, length: 5))
        #expect(host.box.text == "hello **world**")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        host.textView.performKeymapAction(id: "codeSpan")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(host.string == "hello **`world`**")
        host.controller.undoManager.undo()
        #expect(host.string == "hello **world**")
        host.controller.undoManager.undo()
        #expect(host.string == "hello world")
        host.controller.undoManager.redo()
        #expect(host.string == "hello **world**")
    }

    @Test func standardBoldAndItalicCommandsUseTheFormatter() {
        let host = IOSSourceHarness("word")
        host.select(0, 4)
        #expect(host.textView.canPerformAction(#selector(UIResponderStandardEditActions.toggleBoldface(_:)), withSender: nil))
        host.textView.toggleItalics(nil)
        #expect(host.string == "*word*")
    }

    @Test func pastingRichTextInsertsPlainText() throws {
        let host = IOSSourceHarness("x ")
        let rich = NSAttributedString(string: "Bold", attributes: [.font: UIFont.boldSystemFont(ofSize: 30)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        host.textView.pasteboard.items = [["public.rtf": rtf, "public.utf8-plain-text": "Bold"]]
        host.select(2)
        host.textView.paste(nil)
        #expect(host.string == "x Bold")
        let font = host.controller.textStorage.attribute(.font, at: 3, effectiveRange: nil) as? UIFont
        #expect(font == host.controller.theme.monospaceFont)
        host.select(2, 4)
        host.textView.copy(nil)
        #expect(host.textView.pasteboard.string == "Bold")
        #expect(host.textView.pasteboard.types.allSatisfy { !$0.contains("rtf") })
    }

    @Test func returnSubmitsWhenConfigured() {
        let host = IOSSourceHarness("a", submits: true)
        host.select(1)
        #expect(!host.key("\n"))
        #expect(host.box.submits == 1)
        host.textView.handleShiftReturn(nil)
        #expect(host.string == "a\n")
    }

    @Test func completionCommitsFromTheSoftwareReturnKey() {
        let host = IOSSourceHarness("")
        let plugin = CompletionPlugin(triggers: [CompletionTrigger(id: "mention", prefix: "@")])
        plugin.attach(to: host.controller)
        plugin.onCommit = { editor, session in
            editor.insertInlineContent(.userMention(handle: "nina", displayName: "@nina"), markdownSource: "@nina", replacing: session.context.range)
        }
        host.type("@ni")
        #expect(plugin.session(controller: host.controller)?.context.query == "ni")
        plugin.updateItemCount(1, controller: host.controller)
        #expect(!host.key("\n"))
        host.controller.drainDeferredEdits()
        #expect(host.string == "@nina ")
    }

    @Test func hardwareKeysReachCompletion() {
        let host = IOSSourceHarness("")
        let plugin = CompletionPlugin(triggers: [CompletionTrigger(id: "mention", prefix: "@")])
        plugin.attach(to: host.controller)
        host.type("@n")
        plugin.updateItemCount(2, controller: host.controller)
        #expect(host.textView.dispatchKey(PluginKeyName.arrowDown))
        #expect(plugin.session(controller: host.controller)?.highlightedIndex == 1)
    }
}
#endif
