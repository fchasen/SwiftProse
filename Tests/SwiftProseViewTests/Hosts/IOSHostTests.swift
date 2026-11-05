#if canImport(UIKit) && os(iOS)
import Testing
import UIKit
import SwiftUI
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@MainActor
final class IOSHostHarness {
    final class Box {
        var text: String
        var pushes: [String] = []
        var submits = 0
        init(_ text: String) { self.text = text }
    }

    let controller: EditorController
    let box: Box
    let coordinator: ProseTextViewIOS.Coordinator
    let textView: ProseUITextView

    var storage: NSTextStorage { controller.textStorage }
    var string: String { storage.string }
    var markdown: String { controller.markdown() }
    var undoManager: UndoManager? { textView.undoManager }

    init(markdown: String = "", submits: Bool = false) {
        let box = Box(markdown)
        self.box = box
        controller = EditorController(markdown: markdown)
        let binding = Binding<String>(
            get: { box.text },
            set: { value in
                box.text = value
                box.pushes.append(value)
            }
        )
        let representable = ProseTextViewIOS(
            controller: controller,
            text: binding,
            sizing: .fillContainer,
            onSubmit: submits ? { box.submits += 1 } : nil
        )
        coordinator = representable.makeCoordinator()
        textView = representable.makeTextView(coordinator: coordinator)
        controller.textContainer.size = CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        textView.layoutIfNeeded()
        spin()
    }

    func select(_ location: Int, _ length: Int = 0) {
        textView.selectedRange = NSRange(location: location, length: length)
        coordinator.textViewDidChangeSelection(textView)
    }

    func key(_ text: String) {
        let range = textView.selectedRange
        if coordinator.textView(textView, shouldChangeTextIn: range, replacementText: text) {
            textView.insertText(text)
        }
        coordinator.textViewDidChange(textView)
    }

    func type(_ text: String) {
        for character in text { key(String(character)) }
    }

    func backspace() {
        let selection = textView.selectedRange
        let range = selection.length > 0
            ? selection
            : NSRange(location: max(0, selection.location - 1), length: selection.location > 0 ? 1 : 0)
        if coordinator.textView(textView, shouldChangeTextIn: range, replacementText: "") {
            textView.deleteBackward()
        }
        coordinator.textViewDidChange(textView)
    }

    func spin() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    var paragraphTexts: [String] {
        string.components(separatedBy: "\n")
    }

    func block(at index: Int) -> MarkdownBlock? {
        storage.markdownBlock(at: index)
    }
}

final class EnterRecordingPlugin: EditorPlugin {
    let key = AnyPluginKey(name: "test.enter")
    var consumes: Bool
    private(set) var keys: [String] = []

    init(consumes: Bool) { self.consumes = consumes }

    var props: PluginProps {
        PluginProps(handleKeyDown: { [weak self] _, key in
            guard let self else { return false }
            self.keys.append(key)
            return key == PluginKeyName.enter && self.consumes
        })
    }
}

@MainActor
@Suite("iOS host")
struct IOSHostTests {
    @Test func hostsTextKit2AndSharesTheTextViewUndoManager() {
        let host = IOSHostHarness(markdown: "a")
        #expect(host.textView.textLayoutManager != nil)
        #expect(host.textView.textStorage === host.controller.textStorage)
        #expect(host.controller.editSession.undoManager === host.textView.undoManager)
        #expect(host.controller.usesNativeListEditing == false)
    }

    @Test func returnAtItemEndAddsItemWithoutPlaceholderSpace() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(3)
        host.key("\n")
        #expect(host.string == "one\n\ntwo")
        host.type("x")
        #expect(host.markdown == "- one\n- x\n- two")
        #expect(!host.string.contains(" "))
    }

    @Test func returnInsideItemSplitsIt() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(1)
        host.key("\n")
        #expect(host.markdown == "- o\n- ne\n- two")
        #expect(host.textView.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test func returnAtDocumentEndContinuesTheList() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(7)
        host.key("\n")
        host.type("three")
        #expect(host.markdown == "- one\n- two\n- three")
    }

    @Test func returnOnEmptyItemEndsTheList() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(7)
        host.key("\n")
        host.key("\n")
        host.type("z")
        #expect(host.markdown == "- one\n- two\n\nz")
    }

    @Test func programmaticNewlineUsesTheSameRules() {
        let host = IOSHostHarness(markdown: "- one")
        host.select(3)
        host.textView.insertText("\n")
        host.textView.insertText("b")
        #expect(host.markdown == "- one\n- b")
        #expect(!host.string.contains(" "))
    }

    @Test func tabNestsAndShiftTabOutdents() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(5)
        host.textView.insertText("\t")
        #expect(host.markdown == "- one\n  - two")
        host.textView.handleShiftTab(nil)
        #expect(host.markdown == "- one\n- two")
        host.textView.handleTabCommand(nil)
        #expect(host.markdown == "- one\n  - two")
    }

    @Test func tabOutsideListsInsertsATab() {
        let host = IOSHostHarness(markdown: "a")
        host.select(1)
        host.textView.handleTabCommand(nil)
        #expect(host.string == "a\t")
        host.textView.handleShiftTab(nil)
        #expect(host.string == "a\t")
    }

    @Test func backspaceAtFirstItemStartLeavesTheList() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(0)
        host.backspace()
        #expect(host.string == "one\ntwo")
        #expect(host.block(at: 0)?.isListItem == false)
        #expect(host.markdown == "one\n\n- two")
    }

    @Test func backspaceAtLaterItemStartMergesIntoThePreviousItem() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(4)
        host.backspace()
        #expect(host.markdown == "- one\n\ntwo")
        host.backspace()
        #expect(host.markdown == "- onetwo")
    }

    @Test func splittingAHeadingInsideAListStartsAnItem() {
        let host = IOSHostHarness(markdown: "- # Title")
        host.select(2)
        host.key("\n")
        #expect(host.string == "Ti\ntle")
        #expect(host.block(at: 3)?.headingLevel == 1)
        #expect(host.block(at: 3)?.isListItemStart == true)
        #expect(host.markdown == "- # Ti\n- # tle")
    }

    @Test func returnInAQuoteInsideAListAddsAContinuation() {
        let host = IOSHostHarness(markdown: "- > quoted")
        host.select(6)
        host.key("\n")
        host.type("more")
        #expect(host.string.hasPrefix("quoted\nmore"))
        #expect(host.block(at: 7)?.isContinuation == true)
        #expect(host.block(at: 7)?.isInQuote == true)
        #expect(!host.string.contains(" "))
    }

    @Test func returnInCodeInsideAListContinuesTheCodeBlock() {
        let host = IOSHostHarness(markdown: "- a\n\n  ```\n  x\n  ```")
        let end = (host.string as NSString).length
        host.select(end)
        host.key("\n")
        host.type("y")
        #expect(host.markdown == "- a\n  ```\n  x\n  y\n  ```")
        #expect(!host.string.contains(" "))
    }

    @Test func returnWithSelectionInsideAListReplacesIt() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(1, 2)
        host.key("\n")
        #expect(host.markdown == "- o\n- \n- two" || host.markdown == "- o\n-\n- two")
        #expect(!host.string.contains(" "))
    }

    @Test func shiftReturnInsertsAHardBreak() {
        let host = IOSHostHarness(markdown: "a")
        host.select(1)
        host.textView.handleShiftReturn(nil)
        host.type("b")
        #expect(host.markdown == "a  \nb")
    }

    @Test func shiftReturnWithSubmitInsertsAParagraph() {
        let host = IOSHostHarness(markdown: "a", submits: true)
        host.select(1)
        host.textView.handleShiftReturn(nil)
        host.type("b")
        #expect(host.markdown == "a\n\nb")
        #expect(host.box.submits == 0)
        host.key("\n")
        #expect(host.box.submits == 1)
        #expect(host.markdown == "a\n\nb")
    }

    @Test func commandReturnExitsTheCodeBlock() {
        let host = IOSHostHarness(markdown: "```\nx\n```")
        host.select(1)
        host.textView.handleCommandReturn(nil)
        host.type("y")
        #expect(host.markdown == "```\nx\n```\n\ny")
    }

    @Test func commandReturnIsAvailableOnlyInsideCodeBlocks() {
        let host = IOSHostHarness(markdown: "```\nx\n```\n\nplain")
        let action = #selector(ProseUITextView.handleCommandReturn(_:))
        host.select(host.string.utf16.count)
        #expect(!host.textView.canPerformAction(action, withSender: nil))
        host.select(1)
        #expect(host.textView.canPerformAction(action, withSender: nil))
        host.textView.isEditable = false
        #expect(!host.textView.canPerformAction(action, withSender: nil))
    }

    @Test func typingAtTheEndOfABoldRunStaysBold() {
        let host = IOSHostHarness(markdown: "**bold** plain")
        host.select(4)
        host.type("X")
        #expect(host.markdown == "**boldX** plain")
    }

    @Test func typingAtALinkEndLeavesTheLinkAlone() {
        let host = IOSHostHarness(markdown: "[a](https://x.com) b")
        host.select(1)
        #expect(host.textView.typingAttributes[.link] == nil)
        host.type("Z")
        #expect(host.markdown == "[a](https://x.com)Z b")
    }

    @Test func typingInsideALinkExtendsIt() {
        let host = IOSHostHarness(markdown: "[ab](https://x.com)")
        host.select(1)
        host.type("Z")
        #expect(host.markdown == "[aZb](https://x.com)")
    }

    @Test func typingAttributesCarryTheBlock() {
        let host = IOSHostHarness(markdown: "# Head")
        host.select(2)
        #expect(host.textView.typingAttributes.markdownBlock?.headingLevel == 1)
    }

    @Test func boldAndItalicMapToMarksAndUnderlineIsRefused() {
        let host = IOSHostHarness(markdown: "abc")
        host.select(0, 3)
        let underline = #selector(UIResponderStandardEditActions.toggleUnderline(_:))
        let bold = #selector(UIResponderStandardEditActions.toggleBoldface(_:))
        #expect(host.textView.canPerformAction(underline, withSender: nil) == false)
        #expect(host.textView.canPerformAction(bold, withSender: nil))
        host.textView.toggleUnderline(nil)
        #expect(host.markdown == "abc")
        host.textView.toggleBoldface(nil)
        #expect(host.markdown == "**abc**")
        host.textView.toggleItalics(nil)
        #expect(host.markdown == "***abc***")
    }

    @Test func keyCommandsCoverFormattingAndIndentation() {
        let host = IOSHostHarness(markdown: "a")
        let commands = host.textView.keyCommands ?? []
        func has(_ input: String, _ flags: UIKeyModifierFlags) -> Bool {
            commands.contains { $0.input == input && $0.modifierFlags == flags }
        }
        #expect(has("b", .command))
        #expect(has("i", .command))
        #expect(has("e", .command))
        #expect(has("\t", []))
        #expect(has("\t", .shift))
        #expect(has("\r", .shift))
        #expect(has("\r", .command))
        #expect(commands.allSatisfy { $0.wantsPriorityOverSystemBehavior })
    }

    @Test func keymapCommandPerformsItsAction() {
        let host = IOSHostHarness(markdown: "abc")
        host.select(0, 3)
        host.textView.performKeymapAction(id: EditorAction.codeSpan.stableID)
        #expect(host.markdown == "`abc`")
    }

    @Test func editMenuDropsUnderline() {
        let underline = UICommand(title: "U", action: #selector(UIResponderStandardEditActions.toggleUnderline(_:)))
        let bold = UICommand(title: "B", action: #selector(UIResponderStandardEditActions.toggleBoldface(_:)))
        let menu = UIMenu(title: "Format", children: [bold, underline])
        let filtered = ProseUITextView.filteredMenuElements([menu])
        let children = (filtered.first as? UIMenu)?.children ?? []
        #expect(children.count == 1)
        #expect((children.first as? UICommand)?.action == bold.action)
    }

    @Test func bindingPushesOncePerEditAndNeverOnLoad() {
        let host = IOSHostHarness(markdown: "a")
        #expect(host.box.pushes.isEmpty)
        host.select(1)
        host.type("b")
        #expect(host.box.pushes == ["ab"])
        host.controller.setMarkdown("fresh")
        host.controller.isEditable = false
        host.controller.isEditable = true
        #expect(host.box.pushes == ["ab"])
        host.select(5)
        host.key("\n")
        host.type("c")
        #expect(host.box.pushes.last == "fresh\n\nc")
    }

    @Test func markedTextDefersThePushUntilCommit() {
        let host = IOSHostHarness(markdown: "a")
        host.select(1)
        host.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        #expect(host.textView.markedTextRange != nil)
        #expect(host.box.pushes.isEmpty)
        host.textView.unmarkText()
        #expect(host.box.pushes == ["aか"])
    }

    @Test func returnDuringCompositionSkipsRulesAndPlugins() {
        let host = IOSHostHarness(markdown: "- one")
        let plugin = EnterRecordingPlugin(consumes: true)
        host.controller.register(plugin: plugin)
        host.select(3)
        host.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        #expect(host.textView.routeNewline(submits: true) == false)
        #expect(plugin.keys.isEmpty)
    }

    @Test func softwareReturnGoesToPluginsFirst() {
        let host = IOSHostHarness(markdown: "a")
        let plugin = EnterRecordingPlugin(consumes: true)
        host.controller.register(plugin: plugin)
        host.select(1)
        host.key("\n")
        #expect(host.string == "a")
        #expect(plugin.keys == [PluginKeyName.enter])
        host.textView.insertText("\n")
        #expect(host.string == "a")
        #expect(plugin.keys == [PluginKeyName.enter, PluginKeyName.enter])
    }

    @Test func unconsumedReturnReachesPluginsOncePerPress() {
        let host = IOSHostHarness(markdown: "a")
        let plugin = EnterRecordingPlugin(consumes: false)
        host.controller.register(plugin: plugin)
        host.select(1)
        host.key("\n")
        #expect(host.string == "a\n")
        #expect(plugin.keys == [PluginKeyName.enter])
        host.type("b")
        host.key("\n")
        #expect(plugin.keys == [PluginKeyName.enter, PluginKeyName.enter])
    }

    @Test func ruleEditsAndTypingUndoSeparately() {
        let host = IOSHostHarness(markdown: "- one")
        host.select(3)
        host.spin()
        host.key("\n")
        host.spin()
        host.type("x")
        host.spin()
        #expect(host.markdown == "- one\n- x")
        host.undoManager?.undo()
        host.spin()
        #expect(host.markdown == "- one")
        #expect(host.string.hasPrefix("one\n"))
        host.undoManager?.undo()
        host.spin()
        #expect(host.string == "one")
        host.undoManager?.redo()
        host.spin()
        #expect(host.string.hasPrefix("one\n"))
        #expect(host.block(at: 4)?.isListItem == true || host.textView.typingAttributes.markdownBlock?.isListItem == true)
    }

    @Test func undoAfterTabRestoresTheList() {
        let host = IOSHostHarness(markdown: "- one\n- two")
        host.select(5)
        host.spin()
        host.textView.handleTabCommand(nil)
        host.spin()
        #expect(host.markdown == "- one\n  - two")
        host.undoManager?.undo()
        host.spin()
        #expect(host.markdown == "- one\n- two")
        host.undoManager?.redo()
        host.spin()
        #expect(host.markdown == "- one\n  - two")
    }

    @Test func inputRuleIsItsOwnUndoStep() {
        let host = IOSHostHarness(markdown: "")
        host.type("-")
        host.spin()
        host.type(" ")
        host.controller.drainDeferredEdits()
        host.spin()
        #expect(host.string == "\n")
        #expect(host.block(at: 0)?.isListItem == true)
        host.type("a")
        host.spin()
        #expect(host.markdown == "- a")
        host.undoManager?.undo()
        host.spin()
        host.undoManager?.undo()
        host.spin()
        #expect(host.string == "- ")
    }

    @Test func pasteParsesMarkdownAndCopyWritesIt() throws {
        let host = IOSHostHarness(markdown: "**a** b")
        let pasteboard = try #require(UIPasteboard(name: UIPasteboard.Name("mek.test.\(UUID().uuidString)"), create: true))
        host.textView.pasteboard = pasteboard
        host.select(0, 1)
        host.textView.copy(nil)
        #expect(pasteboard.string == "**a**")
        host.select(7)
        pasteboard.string = " *c*"
        host.textView.paste(nil)
        #expect(host.markdown == "**a** b *c*")
        host.select(0, 1)
        host.textView.cut(nil)
        #expect(host.markdown == " b *c*" || host.markdown == "b *c*")
    }

    @Test func pasteAndMatchStyleInsertsLiteralText() throws {
        let host = IOSHostHarness(markdown: "a")
        let pasteboard = try #require(UIPasteboard(name: UIPasteboard.Name("mek.test.\(UUID().uuidString)"), create: true))
        host.textView.pasteboard = pasteboard
        host.select(1)
        pasteboard.string = " **b**"
        host.textView.pasteAndMatchStyle(nil)
        #expect(host.string == "a **b**")
    }

    @Test func droppedTextParsesAsMarkdown() throws {
        let host = IOSHostHarness(markdown: "a")
        let delegate = try #require(host.textView.pasteDelegate)
        let end = host.textView.endOfDocument
        let range = try #require(host.textView.textRange(from: end, to: end))
        _ = delegate.textPasteConfigurationSupporting?(host.textView, performPasteOf: NSAttributedString(string: "**b**\r\n\r\n- c"), to: range)
        #expect(host.markdown == "a**b**\n\n- c")
        #expect(host.box.pushes.last == "a**b**\n\n- c")
    }

    @Test func taskGutterHitTestsLeftOfTheContent() throws {
        let host = IOSHostHarness(markdown: "- [ ] task")
        host.textView.layoutIfNeeded()
        let rect = try #require(host.controller.rect(forCharacterAt: 0))
        let inside = CGPoint(x: rect.minX - 10, y: rect.midY)
        let onText = CGPoint(x: rect.minX + 5, y: rect.midY)
        #expect(host.textView.taskGutterIndex(at: inside, charIndex: 0) == 0)
        #expect(host.textView.taskGutterIndex(at: onText, charIndex: 0) == nil)
        #expect(host.controller.toggleCheckbox(at: 0))
        #expect(host.markdown == "- [x] task")
    }

    @Test func rightToLeftTaskGutterHitTestsRightOfTheContent() throws {
        let host = IOSHostHarness(markdown: "- [ ] שלום עולם")
        host.textView.layoutIfNeeded()
        let rect = try #require(host.controller.rect(forCharacterAt: 0))
        #expect(host.textView.taskGutterIndex(at: CGPoint(x: rect.maxX + 10, y: rect.midY), charIndex: 0) == 0)
        #expect(host.textView.taskGutterIndex(at: CGPoint(x: rect.minX - 10, y: rect.midY), charIndex: 0) == nil)
    }

    @Test func themeChangeUpdatesTheHostInsetAndCodeFill() {
        let host = IOSHostHarness(markdown: "```\ncode\n```")
        var theme = ProseTheme.default
        theme.textContainerInset = CGSize(width: 21, height: 13)
        theme.codeBlock.fillColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        host.controller.theme = theme
        #expect(host.textView.textContainerInset == UIEdgeInsets(top: 13, left: 21, bottom: 13, right: 21))
        #expect(host.textView.codeBlockBgLayer.fillColor == UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor)
    }

    @Test func caretMovesReloadInputTraitsOnlyWhenAutocorrectChanges() {
        let host = IOSHostHarness(markdown: "plain words\n\n```\nlet x = 1\nlet y = 2\n```")
        host.select(2)
        #expect(host.textView.autocorrectionType == .yes)
        host.textView.delegate = nil
        #expect(!host.coordinator.refreshSpellCheckingForCaret(host.textView))
        host.textView.selectedRange = NSRange(location: 4, length: 0)
        #expect(!host.coordinator.refreshSpellCheckingForCaret(host.textView))
        host.textView.selectedRange = NSRange(location: 14, length: 0)
        #expect(host.coordinator.refreshSpellCheckingForCaret(host.textView))
        #expect(host.textView.autocorrectionType == .no)
        host.textView.selectedRange = NSRange(location: 24, length: 0)
        #expect(!host.coordinator.refreshSpellCheckingForCaret(host.textView))
        host.textView.selectedRange = NSRange(location: 1, length: 0)
        #expect(host.coordinator.refreshSpellCheckingForCaret(host.textView))
        #expect(host.textView.autocorrectionType == .yes)
    }

    @Test func readOnlyHostIgnoresKeyRules() {
        let host = IOSHostHarness(markdown: "- one")
        host.textView.isEditable = false
        host.controller.isEditable = false
        host.select(3)
        #expect(host.textView.routeNewline(submits: false) == false)
        #expect(host.textView.routeTab(backward: false) == false)
    }
}
#endif
