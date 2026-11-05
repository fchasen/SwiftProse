#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
private final class RecordingPlugin: EditorPlugin {
    let key = AnyPluginKey(name: "test.recording")
    var changes: [DocumentChange] = []
    var keys: [String] = []
    var inputs: [String] = []
    var pastes: [PasteEvent] = []
    var consumePaste = false
    var consumeEnter = false

    var props: PluginProps {
        PluginProps(
            handlePaste: { [weak self] _, event in
                self?.pastes.append(event)
                return self?.consumePaste ?? false
            },
            handleKeyDown: { [weak self] _, key in
                self?.keys.append(key)
                return key == PluginKeyName.enter && (self?.consumeEnter ?? false)
            },
            handleTextInput: { [weak self] _, _, text in
                self?.inputs.append(text)
                return false
            }
        )
    }

    func documentDidChange(_ change: DocumentChange, controller: EditorController) {
        changes.append(change)
    }
}

@Suite("Controller host (macOS, .serialized)")
@MainActor
struct ControllerHostTests {
    private func keyEvent(_ harness: EditorHarness, keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    @Test func pluginsReceiveDocumentChangesAfterTheEdit() {
        let harness = EditorHarness(markdown: "a")
        let plugin = RecordingPlugin()
        harness.controller.register(plugin: plugin)
        harness.select(1)
        harness.type("b")
        #expect(plugin.changes.map(\.origin) == [.user])
        #expect(plugin.changes.first?.editedRange == NSRange(location: 1, length: 1))
        harness.step { harness.controller.perform(.heading(level: 1)) }
        #expect(plugin.changes.last?.origin == .command)
        harness.undo()
        harness.controller.flushDocumentChanges()
        #expect(plugin.changes.last?.origin == .undo)
    }

    @Test func pluginKeyDispatchPrecedesKeyRules() {
        let harness = EditorHarness(markdown: "# Title")
        let plugin = RecordingPlugin()
        plugin.consumeEnter = true
        harness.controller.register(plugin: plugin)
        harness.select(7)
        harness.step { harness.textView.keyDown(with: keyEvent(harness, keyCode: 36, characters: "\r")) }
        #expect(plugin.keys == [PluginKeyName.enter])
        #expect(harness.string == "Title")
    }

    @Test func commandReturnKeyEquivalentExitsOnlyCodeBlocks() {
        let harness = EditorHarness(markdown: "```\nx\n```\n\nplain")
        harness.window.makeFirstResponder(harness.textView)
        let commandReturn = keyEvent(harness, keyCode: 36, characters: "\r", flags: .command)
        harness.select(harness.string.utf16.count)
        #expect(!harness.textView.performKeyEquivalent(with: commandReturn))
        #expect(harness.controller.markdown() == "```\nx\n```\n\nplain")
        harness.select(1)
        harness.window.makeFirstResponder(nil)
        #expect(!harness.textView.performKeyEquivalent(with: commandReturn))
        harness.window.makeFirstResponder(harness.textView)
        harness.select(1)
        var handled = false
        harness.step { handled = harness.textView.performKeyEquivalent(with: commandReturn) }
        #expect(handled)
        harness.type("y")
        #expect(harness.controller.markdown() == "```\nx\n```\n\ny\n\nplain")
    }

    @Test func pluginTextInputIsSkippedForCommands() {
        let harness = EditorHarness(markdown: "")
        let plugin = RecordingPlugin()
        harness.controller.register(plugin: plugin)
        #expect(harness.controller.hostShouldChangeText(in: NSRange(location: 0, length: 0), replacement: "@"))
        #expect(plugin.inputs == ["@"])
        harness.controller.commandDepth += 1
        #expect(harness.controller.hostShouldChangeText(in: NSRange(location: 0, length: 0), replacement: "x"))
        harness.controller.commandDepth -= 1
        #expect(plugin.inputs == ["@"])
    }

    @Test func pluginCanConsumePaste() {
        let harness = EditorHarness(markdown: "")
        let plugin = RecordingPlugin()
        plugin.consumePaste = true
        harness.controller.register(plugin: plugin)
        let pasteboard = harness.privatePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("hello", forType: .string)
        harness.step { _ = harness.textView.readSelection(from: pasteboard, type: .string) }
        #expect(plugin.pastes.first?.text == "hello")
        #expect(harness.string.isEmpty)
    }

    @Test func coordinatorRoutesDelegateCallbacks() {
        var text = "a `code` b"
        let binding = Binding(get: { text }, set: { text = $0 })
        let controller = EditorController(markdown: text)
        let view = ProseTextViewMac(controller: controller, text: binding)
        let coordinator = view.makeCoordinator()
        let textView = ProseNSTextView(frame: .zero, textContainer: controller.textContainer)

        var types = NSTextCheckingTypes(NSTextCheckingResult.CheckingType.spelling.rawValue)
        let checked = coordinator.textView(textView, shouldCheckTextIn: NSRange(location: 2, length: 8), offset: 0, types: &types)
        #expect(checked == NSRange(location: 6, length: 2))

        let typing = coordinator.textView(
            textView,
            shouldChangeTypingAttributes: [:],
            toAttributes: [.markdownLiteral: "\\*", .markdownBlock: MarkdownBlock.paragraph]
        )
        #expect(typing[.markdownLiteral] == nil)
        #expect(typing.markdownBlock == .paragraph)

        let ignored = coordinator.textView(textView, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: 6))
        #expect(ignored.map(\.rangeValue) == [NSRange(location: 2, length: 4)])
        #expect(coordinator.responds(to: NSSelectorFromString("textView:shouldChangeTypingAttributes:toAttributes:")))
        #expect(coordinator.responds(to: NSSelectorFromString("textView:writingToolsIgnoredRangesInEnclosingRange:")))
        #expect(coordinator.responds(to: NSSelectorFromString("textViewWritingToolsWillBegin:")))
        #expect(coordinator.responds(to: NSSelectorFromString("textViewWritingToolsDidEnd:")))
    }

    @Test func writingToolsSessionPausesInputRulesAndNormalizesAtEnd() {
        let harness = EditorHarness(markdown: "")
        harness.controller.writingToolsWillBegin()
        harness.typeEach("- ")
        #expect(harness.string == "- ")
        harness.clearPushes()
        harness.storage.addAttribute(.markdownBlock, value: MarkdownBlock(leaf: .heading(level: 2)), range: NSRange(location: 0, length: 1))
        harness.controller.writingToolsDidEnd()
        #expect(harness.storage.isBlockUniform(in: NSRange(location: 0, length: harness.storage.length)))
        harness.typeEach(" ")
        #expect(harness.string.hasPrefix("- "))
    }

    @Test func readOnlyCheckboxToggleRequiresOptIn() {
        let harness = EditorHarness(markdown: "- [ ] a")
        harness.controller.isEditable = false
        harness.textView.isEditable = false
        #expect(!harness.controller.toggleCheckbox(at: 0))
        harness.controller.allowsCheckboxToggle = true
        #expect(harness.controller.toggleCheckbox(at: 0))
        #expect(harness.controller.markdown() == "- [x] a")
        #expect(harness.pushes == ["- [x] a"])
    }

    @Test func remainingBlockRulesUndoToTypedMarker() {
        for (typed, initial) in [("3. ", ""), ("> ", ""), ("[x] ", ""), ("# ", "")] {
            let harness = EditorHarness(markdown: initial)
            harness.typeEach(typed)
            #expect(harness.string != typed, "\(typed)")
            harness.undo()
            #expect(harness.string == typed, "\(typed)")
        }
    }

    private static let wordRule = InlineContentRule(id: "test.word", pattern: "world") { _ in
        .custom(kind: "test.word", label: "world", systemImage: "tag")
    }

    private static let chipProvider: ProseInlineContentProvider = { ChipAttachment.make(for: $0) }

    @Test func inlineContentChangeKeepsUndoAndSelection() {
        let harness = EditorHarness(markdown: "hello world")
        harness.select(5)
        harness.type(" there")
        harness.controller.setInlineContent(rules: [Self.wordRule], provider: Self.chipProvider)
        #expect(harness.string == "hello there \u{FFFC}")
        #expect(harness.selection == NSRange(location: 11, length: 0))
        #expect(harness.controller.markdown() == "hello there world")
        #expect(harness.pushes == ["hello there world"])

        harness.select(13)
        harness.controller.setInlineContent(rules: [], provider: nil)
        #expect(harness.string == "hello there world")
        #expect(harness.selection == NSRange(location: 17, length: 0))
        harness.undo()
        #expect(harness.string == "hello there \u{FFFC}")
        harness.undo()
        #expect(harness.string == "hello there world")
        harness.undo()
        #expect(harness.string == "hello world")
        #expect(harness.pushes == ["hello there world", "hello world"])
    }

    @Test func inlineContentChangeWaitsForComposition() {
        let harness = EditorHarness(markdown: "a world")
        harness.select(1)
        harness.setMarkedText("か")
        harness.controller.setInlineContent(rules: [Self.wordRule], provider: Self.chipProvider)
        #expect(harness.textView.hasMarkedText())
        #expect(harness.string == "aか world")
        harness.unmarkText()
        harness.spin()
        #expect(harness.string == "aか \u{FFFC}")
        #expect(harness.pushes == ["aか world"])
        #expect(harness.selection == NSRange(location: 2, length: 0))
    }

    @Test func setMarkdownDuringCompositionDoesNotPushStaleText() {
        let harness = EditorHarness(markdown: "a")
        harness.select(1)
        harness.setMarkedText("k")
        harness.controller.applyExternalText("fresh")
        #expect(harness.pushes.isEmpty)
        #expect(harness.string == "fresh")
    }
}
#endif
