import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
import SwiftUI

public struct ProseSourceTextViewMac: NSViewRepresentable {
    @Binding public var text: String
    public let controller: SourceEditorController
    public let sizing: EditorSizing
    public let minHeight: CGFloat
    public let contextMenuItems: [ProseContextMenuItem]
    public let spellChecking: ProseSpellChecking
    public let isEditable: Bool
    public let onSubmit: (() -> Void)?

    public init(
        controller: SourceEditorController,
        text: Binding<String>,
        sizing: EditorSizing = .fitsContent,
        minHeight: CGFloat = 96,
        contextMenuItems: [ProseContextMenuItem] = [],
        spellChecking: ProseSpellChecking = .spellingAndGrammar,
        isEditable: Bool = true,
        onSubmit: (() -> Void)? = nil
    ) {
        self.controller = controller
        self._text = text
        self.sizing = sizing
        self.minHeight = minHeight
        self.contextMenuItems = contextMenuItems
        self.spellChecking = spellChecking
        self.isEditable = isEditable
        self.onSubmit = onSubmit
    }

    public func makeNSView(context: Context) -> NSView {
        let textView = makeTextView(coordinator: context.coordinator)
        switch sizing {
        case .fitsContent:
            textView.autoresizingMask = [.width]
            textView.usesFindBar = false
            textView.fitsContent = true
            textView.minimumIntrinsicHeight = minHeight
            controller.intrinsicSizeInvalidator = { [weak textView] in
                textView?.invalidateIntrinsicContentSize()
            }
            return textView
        case .fillContainer:
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.automaticallyAdjustsContentInsets = true
            textView.autoresizingMask = [.width]
            textView.usesFindBar = true
            scrollView.documentView = textView
            return scrollView
        }
    }

    func makeTextView(coordinator: Coordinator) -> ProseSourceNSTextView {
        let textView = ProseSourceNSTextView(frame: .zero, textContainer: controller.textContainer)
        textView.delegate = coordinator
        textView.applyEditorDefaults()
        textView.isEditable = isEditable
        controller.isEditable = isEditable
        applySpellChecking(spellChecking, to: textView)
        textView.drawsBackground = false
        textView.textContainerInset = controller.theme.textContainerInset
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        coordinator.textView = textView
        textView.sourceController = controller
        textView.onSubmit = onSubmit
        controller.hostTextView = textView
        textView.adoptSelection(controller.headlessSelection)
        controller.textSink = { [weak coordinator] text in
            coordinator?.push(text)
        }
        controller.applyTypingAttributes()
        return textView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let textView = Self.textView(in: nsView) else { return }
        context.coordinator.parent = self
        if textView.minimumIntrinsicHeight != minHeight { textView.minimumIntrinsicHeight = minHeight }
        textView.onSubmit = onSubmit
        controller.applyThemeToHost()
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        controller.isEditable = isEditable
        applySpellChecking(spellChecking, to: textView)
        controller.applyExternalText(text)
    }

    private func applySpellChecking(_ mode: ProseSpellChecking, to textView: NSTextView) {
        if textView.isContinuousSpellCheckingEnabled != mode.spellingEnabled {
            textView.isContinuousSpellCheckingEnabled = mode.spellingEnabled
        }
        if textView.isGrammarCheckingEnabled != mode.grammarEnabled {
            textView.isGrammarCheckingEnabled = mode.grammarEnabled
        }
        if textView.isAutomaticSpellingCorrectionEnabled != mode.autocorrectEnabled {
            textView.isAutomaticSpellingCorrectionEnabled = mode.autocorrectEnabled
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard sizing == .fitsContent, let textView = Self.textView(in: nsView) else { return nil }
        if let proposedWidth = proposal.width, proposedWidth > 0 {
            let containerWidth = max(0, proposedWidth - textView.textContainerInset.width * 2)
            if abs(controller.textContainer.size.width - containerWidth) > 0.5 {
                controller.textContainer.size = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        let intrinsic = textView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: max(intrinsic.height, 28))
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func textView(in nsView: NSView) -> ProseSourceNSTextView? {
        if let textView = nsView as? ProseSourceNSTextView { return textView }
        return (nsView as? NSScrollView)?.documentView as? ProseSourceNSTextView
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProseSourceTextViewMac
        weak var textView: NSTextView?

        init(_ parent: ProseSourceTextViewMac) {
            self.parent = parent
            super.init()
        }

        func push(_ text: String) {
            if parent.text != text { parent.text = text }
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.controller.selectionDidChange(textView.selectedRange())
        }

        public func undoManager(for view: NSTextView) -> UndoManager? {
            parent.controller.undoManager
        }

        public func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            parent.controller.hostShouldChangeText(in: affectedCharRange, replacement: replacementString)
        }

        public func textView(
            _ textView: NSTextView,
            shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
            toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]
        ) -> [NSAttributedString.Key: Any] {
            parent.controller.baseAttributes
        }

        public func textView(
            _ textView: NSTextView,
            shouldCheckTextIn range: NSRange,
            offset: Int,
            types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>
        ) -> NSRange {
            guard parent.spellChecking != .off else { return range }
            return ProseSpellChecking.firstCheckableRange(in: range, storage: parent.controller.textStorage)
        }

        public func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard !parent.contextMenuItems.isEmpty else { return menu }
            menu.addItem(NSMenuItem.separator())
            for item in parent.contextMenuItems {
                let menuItem = NSMenuItem(title: item.title, action: #selector(invokeContextMenuItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.state = item.isOn ? .on : .off
                if let symbol = item.systemImage {
                    menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menuItem.representedObject = SourceMenuActionBox(item.action)
                menu.addItem(menuItem)
            }
            return menu
        }

        @objc private func invokeContextMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? SourceMenuActionBox)?.action()
        }
    }
}

private final class SourceMenuActionBox {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

final class ProseSourceNSTextView: NSTextView {
    weak var sourceController: SourceEditorController?
    var onSubmit: (() -> Void)?

    var fitsContent: Bool = false {
        didSet { invalidateIntrinsicContentSize() }
    }

    var minimumIntrinsicHeight: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    func applyEditorDefaults() {
        isRichText = false
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        isSelectable = true
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        allowedWritingToolsResultOptions = [.plainText]
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func unmarkText() {
        let hadMarkedText = hasMarkedText()
        super.unmarkText()
        if hadMarkedText { sourceController?.compositionDidEnd() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        sourceController?.pushBinding()
    }

    override func didChangeText() {
        super.didChangeText()
        if fitsContent { invalidateIntrinsicContentSize() }
        sourceController?.flushDocumentChanges()
    }

    override func keyDown(with event: NSEvent) {
        guard let controller = sourceController, !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        if controller.hasKeyHandlers, let key = Self.pluginKeyName(for: event), controller.dispatchKey(key) {
            return
        }
        let flags = event.modifierFlags
        if flags.contains(.command), !flags.contains(.control),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let action = controller.action(forCommandKey: key, shift: flags.contains(.shift), option: flags.contains(.option)),
           controller.performKeymapAction(action) {
            return
        }
        if let onSubmit, event.keyCode == 36 || event.keyCode == 76,
           flags.intersection([.command, .control, .option]).isEmpty {
            if flags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit()
            }
            return
        }
        super.keyDown(with: event)
    }

    static func pluginKeyName(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case 53: return PluginKeyName.escape
        case 36, 76: return PluginKeyName.enter
        case 48: return PluginKeyName.tab
        case 126: return PluginKeyName.arrowUp
        case 125: return PluginKeyName.arrowDown
        case 123: return PluginKeyName.arrowLeft
        case 124: return PluginKeyName.arrowRight
        default: return nil
        }
    }

    override var intrinsicContentSize: NSSize {
        guard fitsContent, let layoutManager = textLayoutManager else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let used = layoutManager.usageBoundsForTextContainer
        let contentHeight = used.height + textContainerInset.height * 2
        let font = sourceController?.theme.monospaceFont ?? self.font
        let floor = max(minimumIntrinsicHeight, font?.boundingRectForFont.height ?? 16)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(contentHeight, floor))
    }
}
#endif
