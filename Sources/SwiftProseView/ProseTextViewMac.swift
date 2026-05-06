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
    public let spellChecking: ProseSpellChecking

    public init(
        controller: EditorController,
        text: Binding<String>,
        sizing: EditorSizing = .fitsContent,
        minHeight: CGFloat = 96,
        contextMenuItems: [ProseContextMenuItem] = [],
        spellChecking: ProseSpellChecking = .full
    ) {
        self.controller = controller
        self._text = text
        self.sizing = sizing
        self.minHeight = minHeight
        self.contextMenuItems = contextMenuItems
        self.spellChecking = spellChecking
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
        applySpellChecking(spellChecking, to: textView)
        textView.drawsBackground = false
        textView.textContainerInset = controller.theme.textContainerInset
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
            // Let AppKit pad the document view by the enclosing window's
            // safe-area insets (toolbar height) so the first line sits
            // below the bar at rest, while content scrolls under it when
            // the surrounding SwiftUI view ignores the top safe area.
            scrollView.automaticallyAdjustsContentInsets = true
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
        let inset = controller.theme.textContainerInset
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
        if let mtv = textView as? ProseNSTextView {
            mtv.updateCodeBlockBgLayerFill()
        }
        applySpellChecking(spellChecking, to: textView)
        coordinator.applyExternalText(text, to: textView)
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
        guard sizing == .fitsContent, let textView = textView(in: nsView) else { return nil }
        if let proposedWidth = proposal.width, proposedWidth > 0 {
            let inset = textView.textContainerInset
            let containerWidth = max(0, proposedWidth - inset.width * 2)
            controller.textContainer.size = NSSize(
                width: containerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            controller.scheduleTableHeightStamp(containerWidth: containerWidth)
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
            parent.controller.fanoutSelectionChanged(tv.selectedRange())
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
            if commandSelector == #selector(NSResponder.deleteForward(_:)) {
                if parent.controller.handleForwardDelete() { return true }
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

        /// Clip the spell-checker's candidate range to the first contiguous
        /// run that doesn't fall inside a code block or inline `code` mark.
        /// Returning a zero-length range short-circuits the check entirely.
        public func textView(
            _ textView: NSTextView,
            shouldCheckTextIn range: NSRange,
            offset: Int,
            types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>
        ) -> NSRange {
            guard parent.spellChecking != .off else { return range }
            let storage = parent.controller.textStorage
            return ProseSpellChecking.firstCheckableRange(
                in: range,
                storage: storage
            )
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
        // Plugin handleClick gets first crack — return true to consume.
        if let controller = proseController, !controller.plugins.isEmpty {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            for plugin in controller.plugins {
                if plugin.props.handleClick?(controller, charIndex) == true { return }
            }
        }
        // Built-in: single click on a task-list checkbox toggles it.
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
        super.mouseDown(with: event)
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
           event.keyCode == 36,
           proseController?.exitCodeBlock() == true {
            return
        }
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
        let spec = KeySpec.make(key: key, mod: true, shift: shift)
        return proseController?.keymap.action(forKey: spec)
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
        scheduleCodeBlockBgUpdate()
    }

    override func layout() {
        super.layout()
        codeBlockBgLayer.frame = bounds
        scheduleCodeBlockBgUpdate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureCodeBlockBgLayer()
        scheduleCodeBlockBgUpdate()
    }

    /// Sublayer that paints code-block BG bands behind text. Per-fragment
    /// drawing under TextKit 2 elides zero-width paragraph fragments (empty
    /// lines inside a multi-line block), leaving visual gaps; a layer drawn
    /// independently of the fragment-draw pipeline isn't subject to that
    /// optimization.
    private let codeBlockBgLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.actions = ["path": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        l.zPosition = -1
        return l
    }()

    private var codeBlockBgLayerInstalled = false

    private func ensureCodeBlockBgLayer() {
        guard !codeBlockBgLayerInstalled else { return }
        wantsLayer = true
        if let layer {
            let fill = proseController?.theme.codeBlock.fillColor ?? .codeBlockDefaultFill
            codeBlockBgLayer.fillColor = fill.cgColor
            codeBlockBgLayer.frame = layer.bounds
            layer.insertSublayer(codeBlockBgLayer, at: 0)
            codeBlockBgLayerInstalled = true
        }
    }

    /// Refresh the code-block band fill color from the controller's
    /// theme. Called from `updateNSView` so theme swaps re-tint
    /// without remaking the layer.
    func updateCodeBlockBgLayerFill() {
        guard let controller = proseController else { return }
        codeBlockBgLayer.fillColor = controller.theme.codeBlock.fillColor.cgColor
    }

    private var bgUpdateScheduled = false

    private func scheduleCodeBlockBgUpdate() {
        guard !bgUpdateScheduled else { return }
        bgUpdateScheduled = true
        // Defer to the next runloop tick so layout settles after the
        // current edit before we read fragment frames.
        DispatchQueue.main.async { [weak self] in
            self?.bgUpdateScheduled = false
            self?.updateCodeBlockBgPath()
        }
    }

    private func updateCodeBlockBgPath() {
        ensureCodeBlockBgLayer()
        guard codeBlockBgLayerInstalled else { return }
        guard let storage = textStorage,
              let layoutManager = textLayoutManager else {
            codeBlockBgLayer.path = nil
            return
        }
        let inset = textContainerOrigin
        let containerWidth = textContainer?.size.width ?? bounds.width
        let path = CGMutablePath()
        var runStart: Int?
        var runEnd: Int = 0
        let total = storage.length
        var i = 0
        while i < total {
            let isCode = storage.blockSpec(at: i)?.isCodeBlock == true
            if isCode {
                if runStart == nil { runStart = i }
                runEnd = i + 1
            } else if let s = runStart {
                addCodeBlockBand(
                    to: path,
                    range: NSRange(location: s, length: runEnd - s),
                    layoutManager: layoutManager,
                    inset: inset,
                    containerWidth: containerWidth
                )
                runStart = nil
            }
            i += 1
        }
        if let s = runStart {
            addCodeBlockBand(
                to: path,
                range: NSRange(location: s, length: runEnd - s),
                layoutManager: layoutManager,
                inset: inset,
                containerWidth: containerWidth
            )
        }
        codeBlockBgLayer.path = path.isEmpty ? nil : path
    }

    private func addCodeBlockBand(
        to path: CGMutablePath,
        range: NSRange,
        layoutManager: NSTextLayoutManager,
        inset: CGPoint,
        containerWidth: CGFloat
    ) {
        guard let cs = layoutManager.textContentManager as? NSTextContentStorage,
              let docStart = cs.location(cs.documentRange.location, offsetBy: range.location) else { return }
        let docEnd = cs.location(cs.documentRange.location, offsetBy: range.location + range.length)
        var minTextY: CGFloat = .greatestFiniteMagnitude
        var maxTextY: CGFloat = -.greatestFiniteMagnitude
        layoutManager.enumerateTextLayoutFragments(
            from: docStart,
            options: [.ensuresLayout]
        ) { fragment in
            if let docEnd,
               let elementStart = fragment.textElement?.elementRange?.location,
               cs.offset(from: elementStart, to: docEnd) <= 0 {
                return false
            }
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments where line.typographicBounds.height > 0 {
                minTextY = min(minTextY, frame.minY + line.typographicBounds.minY)
                maxTextY = max(maxTextY, frame.minY + line.typographicBounds.maxY)
            }
            return true
        }
        guard maxTextY > minTextY else { return }
        let cornerRadius: CGFloat = 6
        let verticalPadding: CGFloat = 4
        let bandY = max(0, inset.y + minTextY - verticalPadding)
        let bandBottom = inset.y + maxTextY + verticalPadding
        let bandRect = CGRect(
            x: inset.x,
            y: bandY,
            width: containerWidth,
            height: bandBottom - bandY
        )
        path.addRoundedRect(in: bandRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
    }
}
#endif
