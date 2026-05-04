#if canImport(AppKit) && os(macOS)
import AppKit
import SwiftUI
import SwiftProseSyntax
import SwiftProseRendering

public struct ProseTextViewMac: NSViewRepresentable {
    @Binding public var text: String
    public let controller: EditorController
    public let sizing: EditorSizing
    public let minHeight: CGFloat
    public let contextMenuItems: [ProseContextMenuItem]

    public init(
        controller: EditorController,
        text: Binding<String>,
        sizing: EditorSizing = .fitsContent,
        minHeight: CGFloat = 96,
        contextMenuItems: [ProseContextMenuItem] = []
    ) {
        self.controller = controller
        self._text = text
        self.sizing = sizing
        self.minHeight = minHeight
        self.contextMenuItems = contextMenuItems
    }

    public func makeNSView(context: Context) -> NSView {
        let textView = ProseNSTextView(
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
        textView.proseController = controller

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
        if let mtv = textView as? ProseNSTextView,
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
        var parent: ProseTextViewMac
        weak var textView: NSTextView?
        var lastAppliedMarkdown: String
        var pendingTextPush: DispatchWorkItem?

        /// Coalescing window for `parent.text = controller.markdown()` writes
        /// triggered by `textDidChange`. Serializing the whole storage on
        /// every keystroke is wasted work when the user is mid-burst; one
        /// push per ~80 ms tail-edge feels instant and lets the host's
        /// save-on-change observers see a single update per word.
        public static var debounceInterval: DispatchTimeInterval = .milliseconds(80)

        init(_ parent: ProseTextViewMac) {
            self.parent = parent
            self.lastAppliedMarkdown = parent.text
        }

        deinit {
            pendingTextPush?.cancel()
        }

        /// Push an external markdown change into the controller (and storage).
        /// Triggered by SwiftUI binding updates from sources outside the
        /// editor (e.g. the host loaded a different bug's text). Internal
        /// edits flow back via `textDidChange` and update the watermark.
        ///
        /// We don't flush a pending debounced push here — `controller.markdown()`
        /// reads from storage, not from the binding, so the comparison is
        /// always fresh. Flushing would overwrite a deliberate external set
        /// with the user's mid-typing content.
        func applyExternalText(_ md: String, to: NSTextView) {
            if md != lastAppliedMarkdown {
                if parent.controller.markdown() != md {
                    parent.controller.setMarkdown(md)
                }
                lastAppliedMarkdown = md
                // External set wins; cancel any pending push since the
                // post-setMarkdown textDidChange will re-schedule one if
                // needed.
                pendingTextPush?.cancel()
                pendingTextPush = nil
            }
        }

        public func textDidChange(_ notification: Notification) {
            scheduleTextPush()
        }

        /// Cancel + run any pending push immediately on the current thread.
        /// Called from external-text / programmatic paths that need the
        /// binding to be in sync before they read it.
        func flushPendingTextPush() {
            guard let work = pendingTextPush else { return }
            pendingTextPush = nil
            work.cancel()
            performTextPush()
        }

        private func scheduleTextPush() {
            pendingTextPush?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingTextPush = nil
                self.performTextPush()
            }
            pendingTextPush = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.debounceInterval,
                execute: work
            )
        }

        private func performTextPush() {
            let md = parent.controller.markdown()
            if parent.text != md {
                parent.text = md
            }
            lastAppliedMarkdown = md
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.controller.onSelectionChanged?(tv.selectedRange())
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

final class ProseNSTextView: NSTextView {
    var fitsContent: Bool = false {
        didSet { invalidateIntrinsicContentSize() }
    }
    var minimumIntrinsicHeight: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// The owning controller. Set in `ProseTextViewMac.makeNSView`. The
    /// `@objc` action methods read it to dispatch to `Operations`. Held weak
    /// so SwiftUI can tear down the text view without leaking the controller.
    weak var proseController: EditorController?

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
                    if proseController?.toggleCheckbox(at: probe) == true { return }
                }
            }
        }
        // Pipe-table click handling: route to the controller for cell edit
        // sheet (single click on cell) or raw-mode toggle (top-right button).
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if handleTableClick(at: event) { return }
        }
        super.mouseDown(with: event)
    }

    private func handleTableClick(at event: NSEvent) -> Bool {
        guard let controller = proseController,
              let layoutManager = textLayoutManager else { return false }
        let point = convert(event.locationInWindow, from: nil)
        // Translate from text-view coordinates to text-container coordinates
        // (which is also the layout manager's coordinate space).
        let containerOrigin = textContainerOrigin
        let containerPoint = CGPoint(x: point.x - containerOrigin.x, y: point.y - containerOrigin.y)
        // Find the fragment that contains this point. Use the line's
        // vertical strip — for a short table line, the click might be past
        // the text horizontally, so probe at x=0 (within the container) so
        // textLayoutFragment(for:) resolves by row.
        let probePoint = CGPoint(x: 4, y: containerPoint.y)
        guard let frag = layoutManager.textLayoutFragment(for: probePoint) as? PipeTableLayoutFragment else { return false }
        // Both toggleHitRect and columnXs are container-anchored x with
        // y measured from the top of the fragment. Compute fragment-local y.
        let fragY = containerPoint.y - frag.layoutFragmentFrame.origin.y
        let local = CGPoint(x: containerPoint.x, y: fragY)
        // Toggle button hit (only valid on the first table line).
        if frag.isFirstLine, !frag.toggleHitRect.isEmpty, frag.toggleHitRect.contains(local) {
            guard let elementRange = frag.textElement?.elementRange,
                  let tcs = textLayoutManager?.textContentManager as? NSTextContentStorage else { return false }
            let start = tcs.offset(from: tcs.documentRange.location, to: elementRange.location)
            let probe = max(0, min(start, controller.textStorage.length - 1))
            let runRange = PipeTableModel.pipeTableRunRange(at: probe, in: controller.textStorage)
                ?? NSRange(location: start, length: 0)
            controller.toggleTableExpansion(tableRange: runRange)
            needsDisplay = true
            return true
        }
        // Cell edit hit.
        guard let hit = frag.cellHitTest(at: local) else { return false }
        guard let elementRange = frag.textElement?.elementRange,
              let tcs = textLayoutManager?.textContentManager as? NSTextContentStorage else { return false }
        let start = tcs.offset(from: tcs.documentRange.location, to: elementRange.location)
        let probe = max(0, min(start, controller.textStorage.length - 1))
        guard let model = PipeTableModel.parse(at: probe, in: controller.textStorage) else { return false }
        let cellText: String
        if hit.row == -1 {
            cellText = model.headerCells.indices.contains(hit.column) ? model.headerCells[hit.column] : ""
        } else if model.bodyRows.indices.contains(hit.row),
                  model.bodyRows[hit.row].indices.contains(hit.column) {
            cellText = model.bodyRows[hit.row][hit.column]
        } else {
            cellText = ""
        }
        controller.onTableCellTapped?(PipeTableCellHit(
            tableRange: model.sourceRange,
            row: hit.row,
            column: hit.column,
            cellText: cellText
        ))
        return true
    }

    @objc func toggleBold(_ sender: Any?) {
        proseController?.perform(.bold)
    }
    @objc func toggleItalic(_ sender: Any?) {
        proseController?.perform(.italic)
    }
    @objc func toggleStrikethrough(_ sender: Any?) {
        proseController?.perform(.strikethrough)
    }
    @objc func toggleCodeSpan(_ sender: Any?) {
        proseController?.perform(.codeSpan)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           let action = shortcutAction(forCommandKey: chars,
                                       shift: event.modifierFlags.contains(.shift)) {
            proseController?.perform(action)
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
