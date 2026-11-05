import SwiftProseSyntax
import SwiftProseRendering
#if canImport(UIKit) && os(iOS)
import UIKit
import SwiftUI
import UniformTypeIdentifiers

public struct ProseSourceTextViewIOS: UIViewRepresentable {
    public typealias EditMenuBuilder = ProseTextViewIOS.EditMenuBuilder

    @Binding public var text: String
    public let controller: SourceEditorController
    public let sizing: EditorSizing
    public let minHeight: CGFloat
    public let editMenuBuilder: EditMenuBuilder?
    public let spellChecking: ProseSpellChecking
    public let isEditable: Bool
    public let onSubmit: (() -> Void)?

    public init(
        controller: SourceEditorController,
        text: Binding<String>,
        sizing: EditorSizing = .fitsContent,
        minHeight: CGFloat = 96,
        editMenuBuilder: EditMenuBuilder? = nil,
        spellChecking: ProseSpellChecking = .spellingAndGrammar,
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

    func makeTextView(coordinator: Coordinator) -> ProseSourceUITextView {
        let textView = ProseSourceUITextView(frame: .zero, textContainer: controller.textContainer)
        textView.sourceController = controller
        textView.delegate = coordinator
        textView.applyEditorDefaults()
        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        controller.isEditable = isEditable
        let inset = controller.theme.textContainerInset
        textView.textContainerInset = UIEdgeInsets(top: inset.height, left: inset.width, bottom: inset.height, right: inset.width)
        textView.isScrollEnabled = sizing == .fillContainer
        textView.contentInsetAdjustmentBehavior = .always
        textView.isFindInteractionEnabled = sizing == .fillContainer
        coordinator.textView = textView
        controller.hostTextView = textView
        textView.adoptSelection(controller.headlessSelection)
        controller.textSink = { [weak coordinator] text in
            coordinator?.push(text)
        }
        if sizing == .fitsContent {
            controller.intrinsicSizeInvalidator = { [weak textView] in
                textView?.invalidateIntrinsicContentSize()
            }
        }
        coordinator.refreshSpellChecking(textView)
        controller.applyTypingAttributes()
        return textView
    }

    public func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.applyThemeToHost()
        (uiView as? ProseSourceUITextView)?.onSubmit = onSubmit
        if uiView.isEditable != isEditable { uiView.isEditable = isEditable }
        controller.isEditable = isEditable
        context.coordinator.refreshSpellChecking(uiView)
        controller.applyExternalText(text)
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
        return CGSize(width: proposal.width ?? intrinsic.width, height: max(intrinsic.height, minHeight))
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ProseSourceTextViewIOS
        weak var textView: UITextView?

        init(_ parent: ProseSourceTextViewIOS) {
            self.parent = parent
            super.init()
        }

        func push(_ text: String) {
            if parent.text != text { parent.text = text }
        }

        public func textViewDidChange(_ textView: UITextView) {
            parent.controller.flushDocumentChanges()
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.selectionDidChange(textView.selectedRange)
            refreshSpellChecking(textView)
        }

        func refreshSpellChecking(_ textView: UITextView) {
            let inCode = parent.controller.isLocationInCode(textView.selectedRange.location)
            let mode = inCode ? ProseSpellChecking.off : parent.spellChecking
            let spelling: UITextSpellCheckingType = mode.spellingEnabled ? .yes : .no
            let autocorrect: UITextAutocorrectionType = mode.autocorrectEnabled ? .yes : .no
            guard textView.spellCheckingType != spelling || textView.autocorrectionType != autocorrect else { return }
            textView.spellCheckingType = spelling
            textView.autocorrectionType = autocorrect
            if textView.isFirstResponder { textView.reloadInputViews() }
        }

        public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard let sourceView = textView as? ProseSourceUITextView else {
                return parent.controller.hostShouldChangeText(in: range, replacement: text)
            }
            return sourceView.keyboardShouldChangeText(in: range, replacement: text)
        }

        public func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            let allowed = ProseUITextView.filteredMenuElements(suggestedActions)
            if let builder = parent.editMenuBuilder { return builder(range, allowed) }
            return UIMenu(children: allowed)
        }
    }
}

final class ProseSourceUITextView: UITextView {
    weak var sourceController: SourceEditorController?
    var onSubmit: (() -> Void)?
    var pasteboard: UIPasteboard = .general
    private var keyResults: [String: Bool] = [:]
    private var keyResetScheduled = false
    private var cachedKeymap: Keymap?
    private var cachedKeymapCommands: [UIKeyCommand] = []

    override var undoManager: UndoManager? {
        sourceController?.undoManager ?? super.undoManager
    }

    func applyEditorDefaults() {
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        autocapitalizationType = .none
        dataDetectorTypes = []
        allowsEditingTextAttributes = false
        adjustsFontForContentSizeCategory = false
        allowedWritingToolsResultOptions = [.plainText]
    }

    func keyboardShouldChangeText(in range: NSRange, replacement text: String) -> Bool {
        guard let controller = sourceController else { return true }
        guard controller.hostShouldChangeText(in: range, replacement: text) else { return false }
        if text == "\n", markedTextRange == nil, let onSubmit {
            if dispatchKey(PluginKeyName.enter) { return false }
            onSubmit()
            return false
        }
        return true
    }

    override func insertText(_ text: String) {
        super.insertText(text)
        if text == "\n" { keyResults.removeValue(forKey: PluginKeyName.enter) }
        sourceController?.pushBinding()
    }

    override func unmarkText() {
        let hadMarkedText = markedTextRange != nil
        super.unmarkText()
        if hadMarkedText { sourceController?.compositionDidEnd() }
    }

    override func paste(_ sender: Any?) {
        guard let string = pasteboard.string, isEditable, sourceController?.isEditable == true else {
            super.paste(sender)
            return
        }
        insertPlainText(string)
    }

    override func pasteAndMatchStyle(_ sender: Any?) {
        paste(sender)
    }

    func insertPlainText(_ string: String) {
        let normalized = PasteSanitizer.normalizeLineEndings(string)
        guard let controller = sourceController,
              controller.hostShouldChangeText(in: selectedRange, replacement: normalized) else { return }
        super.insertText(normalized)
        controller.pushBinding()
    }

    override func copy(_ sender: Any?) {
        guard writePlainText(of: selectedRange) else {
            super.copy(sender)
            return
        }
    }

    override func cut(_ sender: Any?) {
        let range = selectedRange
        guard isEditable, sourceController?.isEditable == true, range.length > 0, writePlainText(of: range) else {
            super.cut(sender)
            return
        }
        sourceController?.replaceText(in: range, with: "", label: "Cut")
    }

    private func writePlainText(of range: NSRange) -> Bool {
        let target = Normalizer.clamp(range, to: textStorage.length)
        guard target.length > 0 else { return false }
        pasteboard.string = (textStorage.string as NSString).substring(with: target)
        return true
    }

    override func toggleBoldface(_ sender: Any?) {
        sourceController?.perform(.bold)
    }

    override func toggleItalics(_ sender: Any?) {
        sourceController?.perform(.italic)
    }

    override func toggleUnderline(_ sender: Any?) {}

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if ProseUITextView.refusedActions.contains(action) { return false }
        if let controller = sourceController {
            switch action {
            case #selector(UIResponderStandardEditActions.toggleBoldface(_:)):
                return isEditable && controller.canPerform(.bold)
            case #selector(UIResponderStandardEditActions.toggleItalics(_:)):
                return isEditable && controller.canPerform(.italic)
            default:
                break
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    func dispatchKey(_ name: String) -> Bool {
        guard let controller = sourceController, controller.hasKeyHandlers, markedTextRange == nil else { return false }
        if let cached = keyResults[name] { return cached }
        let consumed = controller.dispatchKey(name)
        keyResults[name] = consumed
        if !keyResetScheduled {
            keyResetScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.keyResetScheduled = false
                self?.keyResults.removeAll()
            }
        }
        return consumed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if sourceController?.hasKeyHandlers == true, markedTextRange == nil {
            for press in presses {
                guard let key = press.key, let name = ProseUITextView.pluginKeyName(for: key) else { continue }
                if dispatchKey(name) { return }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if onSubmit != nil {
            let shiftReturn = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(handleShiftReturn(_:)))
            shiftReturn.wantsPriorityOverSystemBehavior = true
            commands.append(shiftReturn)
        }
        commands.append(contentsOf: keymapCommands())
        return commands
    }

    private func keymapCommands() -> [UIKeyCommand] {
        guard let keymap = sourceController?.keymap else { return [] }
        if keymap != cachedKeymap {
            cachedKeymap = keymap
            cachedKeymapCommands = keymap.bindings
                .sorted { $0.key < $1.key }
                .compactMap { ProseUITextView.keyCommand(forSpec: $0.key, actionID: $0.value.stableID) }
        }
        return cachedKeymapCommands
    }

    @objc func handleKeymapCommand(_ sender: UIKeyCommand) {
        guard let id = sender.propertyList as? String else { return }
        performKeymapAction(id: id)
    }

    func performKeymapAction(id: String) {
        guard let controller = sourceController, markedTextRange == nil,
              let action = controller.keymap.bindings.values.first(where: { $0.stableID == id }) else { return }
        _ = controller.performKeymapAction(action)
    }

    @objc func handleShiftReturn(_ sender: UIKeyCommand?) {
        guard markedTextRange == nil, isEditable else { return }
        insertPlainText("\n")
    }
}
#endif
