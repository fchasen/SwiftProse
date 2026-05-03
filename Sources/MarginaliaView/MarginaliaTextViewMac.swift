#if canImport(AppKit) && os(macOS)
import AppKit
import SwiftUI
import MarginaliaSyntax
import MarginaliaRendering

public struct MarginaliaTextViewMac: NSViewRepresentable {
    @Binding public var text: String
    public let controller: EditorController
    public let sizing: EditorSizing
    public let minHeight: CGFloat
    public let contextMenuItems: [MarginaliaContextMenuItem]

    public init(
        controller: EditorController,
        text: Binding<String>,
        sizing: EditorSizing = .fitsContent,
        minHeight: CGFloat = 96,
        contextMenuItems: [MarginaliaContextMenuItem] = []
    ) {
        self.controller = controller
        self._text = text
        self.sizing = sizing
        self.minHeight = minHeight
        self.contextMenuItems = contextMenuItems
    }

    public func makeNSView(context: Context) -> NSView {
        let textView = MarginaliaNSTextView(
            frame: .zero,
            textContainer: controller.textContainer
        )
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.font = controller.theme.bodyFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        context.coordinator.textView = textView
        controller.hostTextView = textView
        textView.marginaliaController = controller

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
            textView.autoresizingMask = [.width]
            textView.usesFindBar = true
            scrollView.documentView = textView
            return scrollView
        }
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let textView = textView(in: nsView) else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        if let mtv = textView as? MarginaliaNSTextView,
           mtv.minimumIntrinsicHeight != minHeight {
            mtv.minimumIntrinsicHeight = minHeight
        }
        coordinator.applyExternalText(text, to: textView)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard sizing == .fitsContent, let textView = textView(in: nsView) else { return nil }
        if let proposedWidth = proposal.width, proposedWidth > 0 {
            let inset = textView.textContainerInset
            let containerWidth = max(0, proposedWidth - inset.width * 2)
            controller.textContainer.size = NSSize(
                width: containerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        let intrinsic = textView.intrinsicContentSize
        let width = proposal.width ?? intrinsic.width
        return CGSize(width: width, height: max(intrinsic.height, 28))
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func textView(in nsView: NSView) -> NSTextView? {
        if let tv = nsView as? NSTextView { return tv }
        if let scroll = nsView as? NSScrollView { return scroll.documentView as? NSTextView }
        return nil
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarginaliaTextViewMac
        weak var textView: NSTextView?
        var lastAppliedMarkdown: String

        init(_ parent: MarginaliaTextViewMac) {
            self.parent = parent
            self.lastAppliedMarkdown = parent.text
        }

        /// Push an external markdown change into the controller (and storage).
        /// Triggered by SwiftUI binding updates from sources outside the
        /// editor (e.g. the host loaded a different bug's text). Internal
        /// edits flow back via `textDidChange` and update the watermark.
        func applyExternalText(_ md: String, to: NSTextView) {
            if md != lastAppliedMarkdown {
                if parent.controller.markdown() != md {
                    parent.controller.setMarkdown(md)
                }
                lastAppliedMarkdown = md
            }
        }

        public func textDidChange(_ notification: Notification) {
            let md = parent.controller.markdown()
            if parent.text != md {
                parent.text = md
            }
            lastAppliedMarkdown = md
        }

        public func undoManager(for view: NSTextView) -> UndoManager? {
            parent.controller.undoManager
        }

        public func textView(_ textView: NSTextView,
                             doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if parent.controller.handleNewline() { return true }
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if parent.controller.handleBackspace() { return true }
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if isCursorInListItem() {
                    parent.controller.perform(.indent)
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if isCursorInListItem() {
                    parent.controller.perform(.outdent)
                    return true
                }
            }
            return false
        }

        private func isCursorInListItem() -> Bool {
            let storage = parent.controller.textStorage
            let total = storage.length
            guard total > 0 else { return false }
            let location = parent.controller.currentSelection.location
            let probe = max(0, min(location, total - 1))
            return storage.blockSpec(at: probe)?.isListItem ?? false
        }

        public func textView(_ view: NSTextView,
                             menu: NSMenu,
                             for event: NSEvent,
                             at charIndex: Int) -> NSMenu? {
            guard !parent.contextMenuItems.isEmpty else { return menu }
            menu.addItem(NSMenuItem.separator())
            for item in parent.contextMenuItems {
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(invokeContextMenuItem(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.state = item.isOn ? .on : .off
                if let symbol = item.systemImage {
                    menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menuItem.representedObject = ContextMenuActionBox(item.action)
                menu.addItem(menuItem)
            }
            return menu
        }

        @objc private func invokeContextMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? ContextMenuActionBox)?.action()
        }
    }
}

private final class ContextMenuActionBox {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

final class MarginaliaNSTextView: NSTextView {
    var fitsContent: Bool = false {
        didSet { invalidateIntrinsicContentSize() }
    }
    var minimumIntrinsicHeight: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// The owning controller. Set in `MarginaliaTextViewMac.makeNSView`. The
    /// `@objc` action methods read it to dispatch to `Operations`. Held weak
    /// so SwiftUI can tear down the text view without leaking the controller.
    weak var marginaliaController: EditorController?

    override func mouseDown(with event: NSEvent) {
        // Single click without modifiers on a task-list checkbox toggles it
        // in place — the standard editable-text-view single-click reserves
        // for cursor placement, but flipping a checkbox is a more obvious
        // affordance.
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let storage = textStorage {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            for probe in [charIndex, charIndex - 1] where probe >= 0 && probe < storage.length {
                if storage.safeAttribute(.attachment, at: probe) is CheckboxAttachment {
                    if marginaliaController?.toggleCheckbox(at: probe) == true { return }
                }
            }
        }
        super.mouseDown(with: event)
    }

    @objc func toggleBold(_ sender: Any?) {
        marginaliaController?.perform(.bold)
    }
    @objc func toggleItalic(_ sender: Any?) {
        marginaliaController?.perform(.italic)
    }
    @objc func toggleStrikethrough(_ sender: Any?) {
        marginaliaController?.perform(.strikethrough)
    }
    @objc func toggleCodeSpan(_ sender: Any?) {
        marginaliaController?.perform(.codeSpan)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           let action = shortcutAction(forCommandKey: chars,
                                       shift: event.modifierFlags.contains(.shift)) {
            marginaliaController?.perform(action)
            return
        }
        super.keyDown(with: event)
    }

    private func shortcutAction(forCommandKey key: String, shift: Bool) -> EditorAction? {
        switch (key, shift) {
        case ("b", false): return .bold
        case ("i", false): return .italic
        case ("e", false): return .codeSpan
        case ("]", false): return .indent
        case ("[", false): return .outdent
        default: return nil
        }
    }

    override var intrinsicContentSize: NSSize {
        guard fitsContent else { return super.intrinsicContentSize }
        guard let layoutManager = textLayoutManager else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let used = layoutManager.usageBoundsForTextContainer
        let inset = textContainerInset
        let contentHeight = used.height + inset.height * 2
        let floor = max(minimumIntrinsicHeight, font?.boundingRectForFont.height ?? 16)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(contentHeight, floor))
    }

    override func didChangeText() {
        super.didChangeText()
        if fitsContent { invalidateIntrinsicContentSize() }
    }
}
#endif
