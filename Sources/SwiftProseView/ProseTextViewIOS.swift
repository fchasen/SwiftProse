import SwiftProseSyntax
import SwiftProseRendering
#if canImport(UIKit) && os(iOS)
import UIKit
import SwiftUI
import UniformTypeIdentifiers

public struct ProseTextViewIOS: UIViewRepresentable {
    public typealias EditMenuBuilder = @MainActor (NSRange, [UIMenuElement]) -> UIMenu?

    @Binding public var text: String
    public let controller: EditorController
    public let sizing: EditorSizing
    public let minHeight: CGFloat
    public let editMenuBuilder: EditMenuBuilder?
    public let spellChecking: ProseSpellChecking
    public let isEditable: Bool
    public let onSubmit: (() -> Void)?

    public init(
        controller: EditorController,
        text: Binding<String>,
        sizing: EditorSizing = .fitsContent,
        minHeight: CGFloat = 96,
        editMenuBuilder: EditMenuBuilder? = nil,
        spellChecking: ProseSpellChecking = .full,
        isEditable: Bool = true,
        onSubmit: (() -> Void)? = nil
    ) {
        self.controller = controller
        self._text = text
        self.sizing = sizing
        self.minHeight = minHeight
        self.editMenuBuilder = editMenuBuilder
        self.spellChecking = spellChecking
        self.isEditable = isEditable
        self.onSubmit = onSubmit
    }

    public func makeUIView(context: Context) -> UITextView {
        makeTextView(coordinator: context.coordinator)
    }

    func makeTextView(coordinator: Coordinator) -> ProseUITextView {
        let textView = ProseUITextView(frame: .zero, textContainer: controller.textContainer)
        textView.markdownController = controller
        textView.delegate = coordinator
        textView.applyEditorDefaults()
        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        controller.isEditable = isEditable
        applySpellChecking(spellChecking, to: textView)
        let inset = controller.theme.textContainerInset
        textView.textContainerInset = UIEdgeInsets(
            top: inset.height, left: inset.width,
            bottom: inset.height, right: inset.width
        )
        textView.isScrollEnabled = sizing == .fillContainer
        textView.contentInsetAdjustmentBehavior = .always
        textView.isFindInteractionEnabled = sizing == .fillContainer
        coordinator.textView = textView
        controller.hostTextView = textView
        textView.adoptSelection(controller.headlessSelection)
        controller.textSink = { [weak coordinator] markdown in
            coordinator?.push(markdown)
        }
        if sizing == .fitsContent {
            controller.intrinsicSizeInvalidator = { [weak textView] in
                textView?.invalidateIntrinsicContentSize()
            }
        }
        coordinator.installPluginRecognizers(on: textView)
        textView.syncTypingAttributes()
        return textView
    }

    public func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.applyThemeToHost()
        if let markdownView = uiView as? ProseUITextView {
            markdownView.onSubmit = onSubmit
        }
        if uiView.isEditable != isEditable {
            uiView.isEditable = isEditable
        }
        controller.isEditable = isEditable
        context.coordinator.refreshSpellCheckingForCaret(uiView)
        controller.applyExternalText(text)
    }

    @discardableResult
    fileprivate func applySpellChecking(_ mode: ProseSpellChecking, to textView: UITextView) -> Bool {
        let spelling: UITextSpellCheckingType = mode.spellingEnabled ? .yes : .no
        if textView.spellCheckingType != spelling {
            textView.spellCheckingType = spelling
        }
        let autocorrect: UITextAutocorrectionType = mode.autocorrectEnabled ? .yes : .no
        guard textView.autocorrectionType != autocorrect else { return false }
        textView.autocorrectionType = autocorrect
        return true
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard sizing == .fitsContent else { return nil }
        if let proposedWidth = proposal.width, proposedWidth > 0 {
            let inset = uiView.textContainerInset
            let containerWidth = max(0, proposedWidth - inset.left - inset.right)
            if abs(controller.textContainer.size.width - containerWidth) > 0.5 {
                controller.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
            }
        }
        let intrinsic = uiView.intrinsicContentSize
        let width = proposal.width ?? intrinsic.width
        return CGSize(width: width, height: max(intrinsic.height, minHeight))
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ProseTextViewIOS
        weak var textView: UITextView?

        init(_ parent: ProseTextViewIOS) {
            self.parent = parent
            super.init()
        }

        func push(_ markdown: String) {
            if parent.text != markdown {
                parent.text = markdown
            }
        }

        public func textViewDidChange(_ textView: UITextView) {
            (textView as? ProseUITextView)?.textDidChange()
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? ProseUITextView)?.syncTypingAttributes()
            parent.controller.selectionDidChange(textView.selectedRange)
            refreshSpellCheckingForCaret(textView)
        }

        @discardableResult
        func refreshSpellCheckingForCaret(_ textView: UITextView) -> Bool {
            let inCode = parent.controller.isLocationInCode(textView.selectedRange.location)
            guard parent.applySpellChecking(inCode ? .off : parent.spellChecking, to: textView) else { return false }
            if textView.isFirstResponder { textView.reloadInputViews() }
            return true
        }

        public func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            var allowed = ProseUITextView.filteredMenuElements(suggestedActions)
            if let table = ProseUITextView.tableMenu(for: parent.controller) {
                allowed.append(table)
            }
            if let builder = parent.editMenuBuilder {
                return builder(range, allowed)
            }
            return UIMenu(children: allowed)
        }

        public func textView(
            _ textView: UITextView,
            writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange
        ) -> [NSValue] {
            parent.controller.writingToolsIgnoredRanges(in: enclosingRange).map { NSValue(range: $0) }
        }

        public func textViewWritingToolsWillBegin(_ textView: UITextView) {
            parent.controller.writingToolsWillBegin()
        }

        public func textViewWritingToolsDidEnd(_ textView: UITextView) {
            parent.controller.writingToolsDidEnd()
        }

        func installPluginRecognizers(on textView: UITextView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handlePluginTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            textView.addGestureRecognizer(tap)
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePluginLongPress(_:)))
            press.minimumPressDuration = 0.5
            press.cancelsTouchesInView = false
            press.delegate = self
            textView.addGestureRecognizer(press)
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        private func characterIndex(for gr: UIGestureRecognizer, in textView: UITextView) -> Int? {
            guard let position = textView.closestPosition(to: gr.location(in: textView)) else { return nil }
            return textView.offset(from: textView.beginningOfDocument, to: position)
        }

        @objc private func handlePluginTap(_ gr: UITapGestureRecognizer) {
            guard let textView = textView as? ProseUITextView,
                  let charIndex = characterIndex(for: gr, in: textView) else { return }
            let point = gr.location(in: textView)
            let controller = parent.controller
            let taskIndex = textView.taskGutterIndex(at: point, charIndex: charIndex)
            DispatchQueue.main.async {
                for plugin in controller.plugins {
                    if plugin.props.handleClick?(controller, charIndex) == true { return }
                }
                if let taskIndex { _ = controller.toggleCheckbox(at: taskIndex) }
            }
        }

        @objc private func handlePluginLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began,
                  let textView,
                  !parent.controller.plugins.isEmpty,
                  let charIndex = characterIndex(for: gr, in: textView) else { return }
            let controller = parent.controller
            for plugin in controller.plugins {
                if plugin.props.handleLongPress?(controller, charIndex) == true { return }
            }
        }

        public func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard let markdownView = textView as? ProseUITextView else {
                return parent.controller.hostShouldChangeText(in: range, replacement: text)
            }
            return markdownView.keyboardShouldChangeText(in: range, replacement: text)
        }
    }
}

final class ProseUITextView: UITextView {
    static let markdownType = EditorController.markdownPasteboardType

    weak var markdownController: EditorController? {
        didSet {
            guard markdownController !== oldValue else { return }
            if let token = documentObserver { oldValue?.removeObserver(token) }
            documentObserver = markdownController?.addOnDocumentChange { [weak self] change in
                guard change.origin == .command || change.origin == .undo else { return }
                self?.syncTypingAttributes()
            }
        }
    }
    var onSubmit: (() -> Void)?
    var pasteboard: UIPasteboard = .general
    private var documentObserver: EditorController.ObserverToken?

    override var undoManager: UndoManager? {
        markdownController?.undoManager ?? super.undoManager
    }

    private var pluginKeyResults: [String: Bool] = [:]
    private var pluginKeyResetScheduled = false
    private var cachedKeymap: Keymap?
    private var cachedKeymapCommands: [UIKeyCommand] = []

    deinit {
        if let documentObserver { markdownController?.removeObserver(documentObserver) }
    }

    func applyEditorDefaults() {
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        dataDetectorTypes = []
        allowsEditingTextAttributes = false
        adjustsFontForContentSizeCategory = true
        allowedWritingToolsResultOptions = [.plainText]
        pasteDelegate = self
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: (pasteConfiguration?.acceptableTypeIdentifiers ?? [])
                + PastedImagePolicy.dataTypes.map(\.identifier)
        )
    }

    func textDidChange() {
        scheduleCodeBlockBgUpdate()
        markdownController?.flushDocumentChanges()
    }

    func syncTypingAttributes() {
        guard let controller = markdownController, markedTextRange == nil else { return }
        let storage = controller.textStorage
        let selection = selectedRange
        let location = min(selection.location, storage.length)
        var attributes = controller.typingAttributes(at: location)
        let info = controller.paragraphInfo(at: location)
        guard !info.block.isCode else {
            controller.applyTypingAttributes(attributes)
            return
        }
        if selection.length > 0, location < NSMaxRange(info.content) {
            let intent = storage.markdownInlineIntent(at: location).intersection(.markdownMarks)
            attributes = controller.typingAttributes(for: info.block, textLists: info.lists, intent: intent)
        }
        if location > info.content.location, location < NSMaxRange(info.content),
           let before = storage.attribute(.link, at: location - 1, effectiveRange: nil),
           let after = storage.attribute(.link, at: location, effectiveRange: nil),
           (before as AnyObject).isEqual(after) {
            attributes[.link] = before
        }
        controller.applyTypingAttributes(attributes)
    }

    func keyboardShouldChangeText(in range: NSRange, replacement text: String) -> Bool {
        guard let controller = markdownController else { return true }
        if markedTextRange == nil {
            if text == "\n" {
                if routeNewline(submits: true) {
                    finishPluginKey(PluginKeyName.enter)
                    return false
                }
            } else if text == "\t", routeTab(backward: false) {
                return false
            }
        }
        return controller.hostShouldChangeText(in: range, replacement: text)
    }

    override func insertText(_ text: String) {
        if markdownController != nil, markedTextRange == nil {
            if text == "\n", routeNewline(submits: true) {
                finishPluginKey(PluginKeyName.enter)
                return
            }
            if text == "\t", routeTab(backward: false) { return }
        }
        super.insertText(text)
        if text == "\n" { finishPluginKey(PluginKeyName.enter) }
        markdownController?.pushBinding()
    }

    override func deleteBackward() {
        if markedTextRange == nil, markdownController?.handleBackspace() == true { return }
        super.deleteBackward()
        markdownController?.pushBinding()
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        markdownController?.isSettingMarkedText = true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        markdownController?.isSettingMarkedText = false
    }

    override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        markdownController?.isSettingMarkedText = true
        super.setAttributedMarkedText(markedText, selectedRange: selectedRange)
        markdownController?.isSettingMarkedText = false
    }

    override func unmarkText() {
        let hadMarkedText = markedTextRange != nil
        super.unmarkText()
        guard hadMarkedText, let controller = markdownController else { return }
        controller.pushBinding()
        controller.flushDocumentChanges()
        syncTypingAttributes()
    }

    func routeNewline(submits: Bool) -> Bool {
        guard let controller = markdownController, markedTextRange == nil else { return false }
        if dispatchPluginKey(PluginKeyName.enter) { return true }
        if submits, let onSubmit {
            onSubmit()
            return true
        }
        guard controller.isEditable else { return false }
        if controller.handleNewline() { return true }
        return splitListParagraph()
    }

    func routeTab(backward: Bool) -> Bool {
        guard let controller = markdownController, markedTextRange == nil else { return false }
        return controller.handleTab(backward: backward)
    }

    private func splitListParagraph() -> Bool {
        guard let controller = markdownController else { return false }
        var selection = controller.currentSelection
        let paragraphs = controller.selectedParagraphs(in: selection)
        guard paragraphs.contains(where: { !controller.effectiveLists($0).isEmpty }) else { return false }
        if selection.length > 0 {
            let caret = NSRange(location: selection.location, length: 0)
            guard controller.replace(selection, with: NSAttributedString(), actionName: "Typing", selection: caret) else {
                return false
            }
            if controller.handleNewline() { return true }
            selection = caret
        }
        let info = controller.paragraphInfo(at: selection.location)
        guard !info.isTrailingEmpty, !controller.effectiveLists(info).isEmpty else { return false }
        let lower = info.block.with(isContinuation: true).with(task: nil)
        return controller.splitParagraph(info, at: selection.location, lowerBlock: lower, actionName: "New Paragraph")
    }

    func dispatchPluginKey(_ name: String) -> Bool {
        guard let controller = markdownController, !controller.plugins.isEmpty, markedTextRange == nil else {
            return false
        }
        if let cached = pluginKeyResults[name] { return cached }
        var consumed = false
        for plugin in controller.plugins where plugin.props.handleKeyDown?(controller, name) == true {
            consumed = true
            break
        }
        pluginKeyResults[name] = consumed
        if !pluginKeyResetScheduled {
            pluginKeyResetScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.pluginKeyResetScheduled = false
                self?.pluginKeyResults.removeAll()
            }
        }
        return consumed
    }

    private func finishPluginKey(_ name: String) {
        pluginKeyResults.removeValue(forKey: name)
    }

    private func insertBypassingKeyRules(_ text: String) {
        guard isEditable, let controller = markdownController else { return }
        guard controller.hostShouldChangeText(in: selectedRange, replacement: text) else { return }
        super.insertText(text)
        controller.pushBinding()
    }

    func taskGutterIndex(at point: CGPoint, charIndex: Int) -> Int? {
        guard let controller = markdownController else { return nil }
        let info = controller.paragraphInfo(at: charIndex)
        guard !info.isTrailingEmpty, info.block.isListItemStart, info.block.task != nil,
              let rect = controller.rect(forCharacterAt: info.content.location) else { return nil }
        let gutter = MarkdownTaskGutter.hitRect(
            caret: rect,
            isRightToLeft: controller.textStorage.isRightToLeftParagraph(at: info.content.location)
        )
        return gutter.contains(point) ? info.content.location : nil
    }

    override func paste(_ sender: Any?) {
        guard performPaste(forcePlain: false) else {
            super.paste(sender)
            return
        }
    }

    override func pasteAndMatchStyle(_ sender: Any?) {
        guard performPaste(forcePlain: true) else {
            super.pasteAndMatchStyle(sender)
            return
        }
    }

    private func performPaste(forcePlain: Bool) -> Bool {
        guard let controller = markdownController, controller.isEditable, isEditable else { return false }
        let payload = Self.pastePayload(from: pasteboard, forcePlain: forcePlain)
        let images = Self.pastedImages(from: pasteboard, forcePlain: forcePlain)
        guard !payload.isEmpty || !images.isEmpty else { return false }
        let selection = selectedRange
        let event = PasteEvent(
            text: payload.anyText,
            html: forcePlain ? nil : Self.htmlString(from: pasteboard),
            plainText: forcePlain,
            source: .paste,
            selection: selection,
            inCode: controller.isLocationInCode(selection.location),
            images: images
        )
        for plugin in controller.plugins {
            if plugin.props.handlePaste?(controller, event) == true { return true }
        }
        guard !payload.isEmpty else { return false }
        return controller.paste(payload, replacing: selection)
    }

    static func pastedImages(from pasteboard: UIPasteboard, forcePlain: Bool) -> [PastedImage] {
        guard !forcePlain, pasteboard.hasImages || pasteboard.hasURLs else { return [] }
        return PastedImagePolicy.images(
            hasMarkdown: pasteboard.types.contains(markdownType),
            forcePlain: forcePlain,
            plainText: pasteboard.string,
            fileURLs: (pasteboard.urls ?? []).filter(\.isFileURL),
            dataImages: {
                pasteboard.items.compactMap { item in
                    guard let type = PastedImagePolicy.preferredDataType(in: Array(item.keys)) else { return nil }
                    switch item[type.identifier] {
                    case let data as Data where !data.isEmpty:
                        return PastedImage(data: data, contentType: type)
                    case let image as UIImage:
                        return image.pngData().map { PastedImage(data: $0, contentType: .png) }
                    default:
                        return nil
                    }
                }
            }
        )
    }

    static func pastePayload(from pasteboard: UIPasteboard, forcePlain: Bool) -> PastePayload {
        let plain = pasteboard.string ?? pasteboard.url?.absoluteString
        let markdown = pasteboard.data(forPasteboardType: markdownType).flatMap { String(data: $0, encoding: .utf8) }
        if forcePlain {
            return PastePayload(plainText: plain ?? markdown, forcePlain: true)
        }
        if let markdown {
            return PastePayload(markdown: markdown, plainText: plain)
        }
        if let rich = richText(from: pasteboard) {
            return PastePayload(plainText: plain, richText: rich)
        }
        return PastePayload(plainText: plain)
    }

    private static func richText(from pasteboard: UIPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forPasteboardType: UTType.rtfd.identifier),
           let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
            return rich
        }
        if let data = pasteboard.data(forPasteboardType: UTType.rtf.identifier),
           let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return rich
        }
        if let html = htmlString(from: pasteboard) {
            return EditorController.attributedString(fromHTML: html)
        }
        return nil
    }

    private static func htmlString(from pasteboard: UIPasteboard) -> String? {
        guard let data = pasteboard.data(forPasteboardType: UTType.html.identifier) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    override func copy(_ sender: Any?) {
        guard !writeMarkdown(of: selectedRange) else { return }
        super.copy(sender)
    }

    private func writeMarkdown(of range: NSRange) -> Bool {
        guard let controller = markdownController else { return false }
        let target = Normalizer.clamp(range, to: controller.textStorage.length)
        guard target.length > 0 else { return false }
        let markdown = controller.markdownForCopy(range: target)
        pasteboard.items = [[
            UTType.utf8PlainText.identifier: markdown,
            Self.markdownType: Data(markdown.utf8)
        ]]
        return true
    }

    override func cut(_ sender: Any?) {
        guard let controller = markdownController, controller.isEditable, isEditable else {
            super.cut(sender)
            return
        }
        let range = selectedRange
        guard range.length > 0, writeMarkdown(of: range) else {
            super.cut(sender)
            return
        }
        controller.deleteForCut(range)
    }

    override func toggleBoldface(_ sender: Any?) {
        markdownController?.perform(.bold)
    }

    override func toggleItalics(_ sender: Any?) {
        markdownController?.perform(.italic)
    }

    override func toggleUnderline(_ sender: Any?) {}

    override func increaseSize(_ sender: Any?) {}

    override func decreaseSize(_ sender: Any?) {}

    static let refusedActions: Set<Selector> = [
        #selector(UIResponderStandardEditActions.toggleUnderline(_:)),
        #selector(UIResponderStandardEditActions.increaseSize(_:)),
        #selector(UIResponderStandardEditActions.decreaseSize(_:)),
        #selector(UIResponderStandardEditActions.updateTextAttributes(conversionHandler:))
    ]

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if Self.refusedActions.contains(action) { return false }
        if action == #selector(handleCommandReturn(_:)) {
            return isEditable && markedTextRange == nil && markdownController?.canExitCodeBlock == true
        }
        if let controller = markdownController {
            switch action {
            case #selector(UIResponderStandardEditActions.toggleBoldface(_:)):
                return isEditable && controller.canPerform(.bold)
            case #selector(UIResponderStandardEditActions.toggleItalics(_:)):
                return isEditable && controller.canPerform(.italic)
            case #selector(UIResponderStandardEditActions.paste(_:)) where pasteboard.hasImages:
                return isEditable && controller.isEditable
            default:
                break
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    static func tableMenu(for controller: EditorController) -> UIMenu? {
        guard controller.isEditable, controller.isSelectionInTable else { return nil }
        let children = EditorAction.tableActions.map { action in
            UIAction(
                title: action.title,
                image: UIImage(systemName: action.systemImage),
                attributes: controller.canPerform(action) ? [] : .disabled,
                state: controller.isActive(action) ? .on : .off
            ) { [weak controller] _ in
                controller?.perform(action)
            }
        }
        return UIMenu(title: "Table", image: UIImage(systemName: "tablecells"), children: children)
    }

    static func filteredMenuElements(_ elements: [UIMenuElement]) -> [UIMenuElement] {
        elements.compactMap { element in
            if let command = element as? UICommand, refusedActions.contains(command.action) {
                return nil
            }
            if let menu = element as? UIMenu {
                let children = filteredMenuElements(menu.children)
                guard !children.isEmpty else { return nil }
                return menu.replacingChildren(children)
            }
            return element
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if markdownController?.plugins.isEmpty == false, markedTextRange == nil {
            for press in presses {
                guard let key = press.key, let name = Self.pluginKeyName(for: key) else { continue }
                if dispatchPluginKey(name) { return }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    static func pluginKeyName(for key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardEscape: return PluginKeyName.escape
        case .keyboardReturnOrEnter, .keypadEnter: return PluginKeyName.enter
        case .keyboardTab: return key.modifierFlags.contains(.shift) ? nil : PluginKeyName.tab
        case .keyboardUpArrow: return PluginKeyName.arrowUp
        case .keyboardDownArrow: return PluginKeyName.arrowDown
        case .keyboardLeftArrow: return PluginKeyName.arrowLeft
        case .keyboardRightArrow: return PluginKeyName.arrowRight
        default: return nil
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(contentsOf: editingKeyCommands)
        commands.append(contentsOf: keymapCommands())
        return commands
    }

    private lazy var editingKeyCommands: [UIKeyCommand] = [
        Self.priorityCommand(input: "\t", flags: [], action: #selector(handleTabCommand(_:))),
        Self.priorityCommand(input: "\t", flags: .shift, action: #selector(handleShiftTab(_:))),
        Self.priorityCommand(input: "\r", flags: .shift, action: #selector(handleShiftReturn(_:))),
        Self.priorityCommand(input: "\r", flags: .command, action: #selector(handleCommandReturn(_:)))
    ]

    private static func priorityCommand(input: String, flags: UIKeyModifierFlags, action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    private func keymapCommands() -> [UIKeyCommand] {
        guard let keymap = markdownController?.keymap else { return [] }
        if keymap != cachedKeymap {
            cachedKeymap = keymap
            cachedKeymapCommands = keymap.bindings
                .sorted { $0.key < $1.key }
                .compactMap { Self.keyCommand(forSpec: $0.key, actionID: $0.value.stableID) }
        }
        return cachedKeymapCommands
    }

    static func keyCommand(forSpec spec: String, actionID: String) -> UIKeyCommand? {
        var parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let input = parts.popLast(), !input.isEmpty else { return nil }
        var flags: UIKeyModifierFlags = []
        for part in parts {
            switch part {
            case "Mod": flags.insert(.command)
            case "Shift": flags.insert(.shift)
            case "Alt": flags.insert(.alternate)
            default: return nil
            }
        }
        let command = UIKeyCommand(
            action: #selector(handleKeymapCommand(_:)),
            input: input,
            modifierFlags: flags,
            propertyList: actionID
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc func handleKeymapCommand(_ sender: UIKeyCommand) {
        guard let id = sender.propertyList as? String else { return }
        performKeymapAction(id: id)
    }

    func performKeymapAction(id: String) {
        guard let controller = markdownController, markedTextRange == nil,
              let action = controller.keymap.bindings.values.first(where: { $0.stableID == id }) else { return }
        controller.perform(action)
    }

    @objc func handleTabCommand(_ sender: UIKeyCommand?) {
        guard markedTextRange == nil else { return }
        if dispatchPluginKey(PluginKeyName.tab) { return }
        if routeTab(backward: false) { return }
        insertBypassingKeyRules("\t")
    }

    @objc func handleShiftTab(_ sender: UIKeyCommand?) {
        _ = routeTab(backward: true)
    }

    @objc func handleShiftReturn(_ sender: UIKeyCommand?) {
        guard let controller = markdownController, markedTextRange == nil, isEditable else { return }
        let inCodeBlock = controller.paragraphInfo(at: controller.currentSelection.location).block.isCode
        if onSubmit != nil || inCodeBlock {
            if routeNewline(submits: false) {
                finishPluginKey(PluginKeyName.enter)
                return
            }
            finishPluginKey(PluginKeyName.enter)
            insertBypassingKeyRules("\n")
            return
        }
        if dispatchPluginKey(PluginKeyName.enter) {
            finishPluginKey(PluginKeyName.enter)
            return
        }
        insertBypassingKeyRules(MarkdownBreak.string)
    }

    @objc func handleCommandReturn(_ sender: UIKeyCommand?) {
        _ = markdownController?.exitCodeBlock()
    }

    let codeBlockBgLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.actions = ["path": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.zPosition = -1
        return layer
    }()

    private var codeBlockBgLayerInstalled = false
    private var bgUpdateScheduled = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        ensureCodeBlockBgLayer()
        scheduleCodeBlockBgUpdate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        codeBlockBgLayer.frame = CGRect(origin: .zero, size: bounds.size)
        scheduleCodeBlockBgUpdate()
    }

    private func ensureCodeBlockBgLayer() {
        guard !codeBlockBgLayerInstalled else { return }
        let fill = markdownController?.theme.codeBlock.fillColor ?? .codeBlockDefaultFill
        codeBlockBgLayer.fillColor = resolvedFillCGColor(fill)
        codeBlockBgLayer.frame = CGRect(origin: .zero, size: layer.bounds.size)
        layer.insertSublayer(codeBlockBgLayer, at: 0)
        codeBlockBgLayerInstalled = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProseUITextView, _) in
            view.updateCodeBlockBgLayerFill()
        }
    }

    func updateCodeBlockBgLayerFill() {
        guard let controller = markdownController else { return }
        codeBlockBgLayer.fillColor = resolvedFillCGColor(controller.theme.codeBlock.fillColor)
    }

    private func resolvedFillCGColor(_ color: UIColor) -> CGColor {
        color.resolvedColor(with: traitCollection).cgColor
    }

    func scheduleCodeBlockBgUpdate() {
        guard !bgUpdateScheduled else { return }
        bgUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.bgUpdateScheduled = false
            self?.updateCodeBlockBgPath()
        }
    }

    private func updateCodeBlockBgPath() {
        ensureCodeBlockBgLayer()
        guard let layoutManager = textLayoutManager else {
            codeBlockBgLayer.path = nil
            return
        }
        codeBlockBgLayer.path = CodeBandPath.make(
            storage: textStorage,
            layoutManager: layoutManager,
            inset: CGPoint(x: textContainerInset.left, y: textContainerInset.top),
            containerWidth: textContainer.size.width
        )
    }
}

final class PastedImageAttachment: NSTextAttachment {
    let pastedImage: PastedImage

    init(pastedImage: PastedImage) {
        self.pastedImage = pastedImage
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension ProseUITextView: UITextPasteDelegate {
    static let richTextTypeIdentifiers: [String] = [
        markdownType, UTType.rtf.identifier, UTType.rtfd.identifier, UTType.flatRTFD.identifier
    ]

    func textPasteConfigurationSupporting(
        _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
        transform item: any UITextPasteItem
    ) {
        let provider = item.itemProvider
        let registered = provider.registeredTypeIdentifiers
        guard !registered.contains(where: Self.richTextTypeIdentifiers.contains),
              let type = PastedImagePolicy.preferredDataType(in: registered)
                ?? registered.lazy.compactMap(UTType.init).first(where: { $0.conforms(to: .image) })
        else {
            item.setDefaultResult()
            return
        }
        let suggestedName = provider.suggestedName.map { name in
            (name as NSString).pathExtension.isEmpty
                ? (name as NSString).appendingPathExtension(type.preferredFilenameExtension ?? "") ?? name
                : name
        }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            DispatchQueue.main.async {
                guard let data, !data.isEmpty else {
                    item.setNoResult()
                    return
                }
                let image = PastedImage(data: data, contentType: type, suggestedName: suggestedName)
                item.setResult(attachment: PastedImageAttachment(pastedImage: image))
            }
        }
    }

    func textPasteConfigurationSupporting(
        _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
        performPasteOf attributedString: NSAttributedString,
        to textRange: UITextRange
    ) -> UITextRange {
        guard let controller = markdownController, controller.isEditable, isEditable,
              attributedString.length > 0 else { return textRange }
        let start = offset(from: beginningOfDocument, to: textRange.start)
        let end = offset(from: beginningOfDocument, to: textRange.end)
        let range = NSRange(location: start, length: max(0, end - start))
        let images = Self.pastedImages(in: attributedString)
        let text = images.isEmpty
            ? attributedString.string
            : attributedString.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        let event = PasteEvent(
            text: text.isEmpty ? nil : text,
            selection: range,
            inCode: controller.isLocationInCode(start),
            images: images
        )
        for plugin in controller.plugins {
            if plugin.props.handlePaste?(controller, event) == true { return textRange }
        }
        guard !text.isEmpty, controller.paste(PastePayload(plainText: text), replacing: range) else { return textRange }
        let caret = controller.currentSelection
        guard let from = position(from: beginningOfDocument, offset: caret.location),
              let to = position(from: beginningOfDocument, offset: NSMaxRange(caret)),
              let result = self.textRange(from: from, to: to) else { return textRange }
        return result
    }

    static func pastedImages(in attributedString: NSAttributedString) -> [PastedImage] {
        var images: [PastedImage] = []
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, _ in
            if let attachment = value as? PastedImageAttachment {
                images.append(attachment.pastedImage)
            }
        }
        return images
    }
}
#endif
