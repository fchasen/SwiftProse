#if canImport(AppKit) && os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
final class SourceMacHarness {
    final class Box {
        var text: String
        var pushes: [String] = []
        var submits = 0
        init(_ text: String) { self.text = text }
    }

    let controller: SourceEditorController
    let box: Box
    let coordinator: ProseSourceTextViewMac.Coordinator
    let textView: ProseSourceNSTextView
    let window: NSWindow

    init(_ text: String, submits: Bool = false) {
        let box = Box(text)
        self.box = box
        controller = SourceEditorController(text: text)
        let binding = Binding<String>(get: { box.text }, set: { box.text = $0; box.pushes.append($0) })
        let representable = ProseSourceTextViewMac(
            controller: controller,
            text: binding,
            sizing: .fillContainer,
            spellChecking: .off,
            onSubmit: submits ? { box.submits += 1 } : nil
        )
        coordinator = representable.makeCoordinator()
        textView = representable.makeTextView(coordinator: coordinator)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.textContainer.size = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        window.contentView = textView
        window.makeFirstResponder(textView)
    }

    func close() { window.close() }

    func select(_ location: Int, _ length: Int = 0) {
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    func type(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
        textView.keyDown(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    func traits(at index: Int) -> FontTraits {
        (controller.textStorage.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont)?.fontTraits ?? []
    }
}

@Suite("Source host (macOS, .serialized)")
@MainActor
struct SourceHostMacTests {
    @Test func hostsAPlainTextKit2ViewSharingTheControllerUndoManager() {
        let host = SourceMacHarness("x")
        defer { host.close() }
        #expect(host.textView.textLayoutManager != nil)
        #expect(host.textView.textStorage === host.controller.textStorage)
        #expect(host.textView.undoManager === host.controller.undoManager)
        #expect(!host.textView.isRichText)
        #expect(host.controller.hostTextView === host.textView)
    }

    @Test func typingStylesTheLineAndWritesTheBinding() {
        let host = SourceMacHarness("title\nbody")
        defer { host.close() }
        #expect(!host.traits(at: 1).contains(.bold))
        host.select(0)
        host.type("# ")
        #expect(host.textView.string == "# title\nbody")
        #expect(host.traits(at: 3).contains(.bold))
        #expect(!host.traits(at: 9).contains(.bold))
        #expect(host.box.text == "# title\nbody")
        #expect(host.controller.styler.lastPass.lines.map { (host.textView.string as NSString).substring(with: $0) } == ["# title\n", "body"])
    }

    @Test func keymapShortcutsFormatInTheSourceView() {
        let host = SourceMacHarness("hello world")
        defer { host.close() }
        host.select(6, 5)
        host.key("b", keyCode: 11, flags: .command)
        #expect(host.textView.string == "hello **world**")
        #expect(host.textView.selectedRange() == NSRange(location: 8, length: 5))
        host.key("i", keyCode: 34, flags: .command)
        #expect(host.textView.string == "hello ***world***")
        host.key("e", keyCode: 14, flags: .command)
        #expect(host.textView.string == "hello ***`world`***")
        #expect(host.box.text == "hello ***`world`***")
        host.controller.undoManager.undo()
        #expect(host.textView.string == "hello ***world***")
        host.controller.undoManager.undo()
        host.controller.undoManager.undo()
        #expect(host.textView.string == "hello world")
        host.controller.undoManager.redo()
        #expect(host.textView.string == "hello **world**")
    }

    @Test func plainKeysAndReadOnlyViewsAreNotFormatted() {
        let host = SourceMacHarness("word")
        defer { host.close() }
        host.select(0, 4)
        host.controller.isEditable = false
        host.textView.isEditable = false
        host.key("b", keyCode: 11, flags: .command)
        #expect(host.textView.string == "word")
    }

    @Test func toolbarActionsWhileHostedAreUndoable() {
        let host = SourceMacHarness("- a\n- b")
        defer { host.close() }
        host.select(0, 7)
        #expect(host.controller.perform(.orderedList))
        #expect(host.textView.string == "1. a\n2. b")
        #expect(host.controller.undoManager.undoActionName == "Numbered List")
        host.controller.undoManager.undo()
        #expect(host.textView.string == "- a\n- b")
    }

    @Test func pastingRichTextInsertsPlainText() {
        let host = SourceMacHarness("x ")
        defer { host.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("swiftprose.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let rich = NSAttributedString(string: "Bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
        let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString("Bold", forType: .string)
        host.select(2)
        #expect(host.textView.readSelection(from: pasteboard))
        #expect(host.textView.string == "x Bold")
        let font = host.controller.textStorage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        #expect(font == host.controller.theme.monospaceFont)
        #expect(host.textView.writablePasteboardTypes == [.string])
    }

    @Test func returnSubmitsAndShiftReturnInsertsANewline() {
        let host = SourceMacHarness("a", submits: true)
        defer { host.close() }
        host.select(1)
        host.key("\r", keyCode: 36)
        #expect(host.box.submits == 1)
        #expect(host.textView.string == "a")
        host.key("\r", keyCode: 36, flags: .shift)
        #expect(host.textView.string == "a\n")
    }

    @Test func completionKeysReachTheSourceView() {
        let host = SourceMacHarness("")
        defer { host.close() }
        let plugin = CompletionPlugin(triggers: [CompletionTrigger(id: "mention", prefix: "@")])
        plugin.attach(to: host.controller)
        plugin.onCommit = { editor, session in
            editor.insertInlineContent(.userMention(handle: "nina", displayName: "@nina"), markdownSource: "@nina", replacing: session.context.range)
        }
        host.type("@")
        host.type("n")
        #expect(plugin.session(controller: host.controller)?.context.query == "n")
        plugin.updateItemCount(1, controller: host.controller)
        host.key("\r", keyCode: 36)
        #expect(host.textView.string == "@nina ")
        #expect(plugin.session(controller: host.controller) == nil)
    }

    @Test func caretRectsTrackTheHost() throws {
        let host = SourceMacHarness("one\ntwo")
        defer { host.close() }
        let first = try #require(host.controller.rect(forCharacterAt: 0))
        let second = try #require(host.controller.rect(forCharacterAt: 4))
        #expect(second.minY > first.minY)
        #expect(first.minX >= host.textView.textContainerOrigin.x)
    }
}
#endif
