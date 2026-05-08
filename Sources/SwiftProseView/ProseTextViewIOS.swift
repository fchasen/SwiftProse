#if canImport(UIKit)
import UIKit
import SwiftUI
import SwiftProseSyntax
import SwiftProseRendering

public struct ProseTextViewIOS: UIViewRepresentable {
    public typealias EditMenuBuilder = @MainActor (NSRange, [UIMenuElement]) -> UIMenu?

    @Binding public var text: String
    public let controller: EditorController
    public let sizing: EditorSizing
    public let minHeight: CGFloat
    public let editMenuBuilder: EditMenuBuilder?
    public let spellChecking: ProseSpellChecking

    public init(
        controller: EditorController,
        text: Binding<String>,
        sizing: EditorSizing = .fitsContent,
        minHeight: CGFloat = 96,
        editMenuBuilder: EditMenuBuilder? = nil,
        spellChecking: ProseSpellChecking = .full
    ) {
        self.controller = controller
        self._text = text
        self.sizing = sizing
        self.minHeight = minHeight
        self.editMenuBuilder = editMenuBuilder
        self.spellChecking = spellChecking
    }

    public func makeUIView(context: Context) -> UITextView {
        let textView = ProseUITextView(frame: .zero, textContainer: controller.textContainer)
        textView.proseController = controller
        textView.delegate = context.coordinator
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        applySpellChecking(spellChecking, to: textView)
        let inset = controller.theme.textContainerInset
        textView.textContainerInset = UIEdgeInsets(
            top: inset.height, left: inset.width,
            bottom: inset.height, right: inset.width
        )
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = (sizing == .fillContainer)
        // UITextView is itself a UIScrollView. `.always` makes it pad its
        // content by the enclosing safe-area insets (status bar / nav
        // bar), so when the host SwiftUI view ignores the top safe area
        // the first line still sits below the bar at rest while content
        // scrolls under it.
        textView.contentInsetAdjustmentBehavior = .always
        if #available(iOS 16.0, *) {
            textView.isFindInteractionEnabled = (sizing == .fillContainer)
        }
        context.coordinator.textView = textView
        controller.hostTextView = textView
        if sizing == .fitsContent {
            controller.intrinsicSizeInvalidator = { [weak textView] in
                textView?.invalidateIntrinsicContentSize()
            }
        }
        context.coordinator.installPluginClickRecognizer(on: textView)
        return textView
    }

    public func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let themeInset = controller.theme.textContainerInset
        let desired = UIEdgeInsets(
            top: themeInset.height, left: themeInset.width,
            bottom: themeInset.height, right: themeInset.width
        )
        if uiView.textContainerInset != desired {
            uiView.textContainerInset = desired
        }
        if let mtv = uiView as? ProseUITextView {
            mtv.updateCodeBlockBgLayerFill()
        }
        applySpellChecking(spellChecking, to: uiView)
        coordinator.refreshSpellCheckingForCaret(uiView)
        coordinator.applyExternalText(text, to: uiView)
    }

    fileprivate func applySpellChecking(_ mode: ProseSpellChecking, to textView: UITextView) {
        let spelling: UITextSpellCheckingType = mode.spellingEnabled ? .yes : .no
        if textView.spellCheckingType != spelling {
            textView.spellCheckingType = spelling
        }
        let autocorrect: UITextAutocorrectionType = mode.autocorrectEnabled ? .yes : .no
        if textView.autocorrectionType != autocorrect {
            textView.autocorrectionType = autocorrect
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard sizing == .fitsContent else { return nil }
        if let proposedWidth = proposal.width, proposedWidth > 0 {
            let inset = uiView.textContainerInset
            let containerWidth = max(0, proposedWidth - inset.left - inset.right)
            controller.textContainer.size = CGSize(
                width: containerWidth,
                height: .greatestFiniteMagnitude
            )
            controller.scheduleTableHeightStamp(containerWidth: containerWidth)
        }
        let intrinsic = uiView.intrinsicContentSize
        let width = proposal.width ?? intrinsic.width
        return CGSize(width: width, height: max(intrinsic.height, minHeight))
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ProseTextViewIOS
        weak var textView: UITextView?
        var lastAppliedMarkdown: String
        var pendingTextPush: DispatchWorkItem?

        /// Coalescing window for `parent.text = controller.markdown()` writes
        /// triggered by `textViewDidChange`. See ProseTextViewMac.swift for
        /// the rationale — same debounce on iOS.
        public static var debounceInterval: DispatchTimeInterval = .milliseconds(80)

        init(_ parent: ProseTextViewIOS) {
            self.parent = parent
            self.lastAppliedMarkdown = parent.text
        }

        deinit {
            pendingTextPush?.cancel()
        }

        func applyExternalText(_ md: String, to: UITextView) {
            if md != lastAppliedMarkdown {
                if parent.controller.markdown() != md {
                    parent.controller.setMarkdown(md)
                }
                lastAppliedMarkdown = md
                pendingTextPush?.cancel()
                pendingTextPush = nil
            }
        }

        public func textViewDidChange(_ textView: UITextView) {
            scheduleTextPush()
            (textView as? ProseUITextView)?.notifyTextChanged()
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.fanoutSelectionChanged(textView.selectedRange)
            refreshSpellCheckingForCaret(textView)
        }

        /// UITextView lacks a per-range spell-check exclusion. As a
        /// best-effort, suspend view-wide spell-check + autocorrect
        /// whenever the caret sits inside an inline-code span or a code
        /// block; restore on exit. Matches the semantics of macOS's
        /// `firstCheckableRange` for the typing path.
        func refreshSpellCheckingForCaret(_ textView: UITextView) {
            let storage = parent.controller.textStorage
            let total = storage.length
            let caret = textView.selectedRange.location
            let inCode: Bool = {
                guard total > 0 else { return false }
                let probe = max(0, min(caret, total - 1))
                if storage.blockSpec(at: probe)?.isCodeBlock == true { return true }
                // Inline code: extend only when both sides of the caret
                // carry the code mark — same gate as
                // `EditorController.refreshTypingAttributes`.
                guard caret > 0, caret < total else { return false }
                let prev = storage.markSet(at: caret - 1)?.contains(type: "code") == true
                let next = storage.markSet(at: caret)?.contains(type: "code") == true
                return prev && next
            }()
            let effective: ProseSpellChecking = inCode ? .off : parent.spellChecking
            parent.applySpellChecking(effective, to: textView)
        }

        public func textView(_ textView: UITextView,
                             editMenuForTextIn range: NSRange,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
            parent.editMenuBuilder?(range, suggestedActions)
        }

        // MARK: Plugin click forwarding

        /// UITextView's own tap recognizer fires for caret placement; this
        /// runs alongside it (simultaneously) so plugins can intercept link
        /// taps without breaking editing. Plugin work is dispatched async so
        /// our `setSelection` lands *after* UITextView's caret placement.
        func installPluginClickRecognizer(on textView: UITextView) {
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

        @objc private func handlePluginTap(_ gr: UITapGestureRecognizer) {
            guard let textView = textView,
                  !parent.controller.plugins.isEmpty else { return }
            let point = gr.location(in: textView)
            // closestPosition gives the gap between glyphs at `point`.
            // Convert to a character index relative to the document start.
            guard let pos = textView.closestPosition(to: point) else { return }
            let charIndex = textView.offset(from: textView.beginningOfDocument, to: pos)
            let controller = parent.controller
            DispatchQueue.main.async {
                for plugin in controller.plugins {
                    if plugin.props.handleClick?(controller, charIndex) == true { return }
                }
            }
        }

        @objc private func handlePluginLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began,
                  let textView = textView,
                  !parent.controller.plugins.isEmpty else { return }
            let point = gr.location(in: textView)
            guard let pos = textView.closestPosition(to: point) else { return }
            let charIndex = textView.offset(from: textView.beginningOfDocument, to: pos)
            let controller = parent.controller
            for plugin in controller.plugins {
                if plugin.props.handleLongPress?(controller, charIndex) == true { return }
            }
        }

        public func textView(_ textView: UITextView,
                             shouldChangeTextIn range: NSRange,
                             replacementText text: String) -> Bool {
            // Plugins get first crack at every text-input event. Returning
            // true from `handleTextInput` consumes the input.
            let controller = parent.controller
            if !controller.plugins.isEmpty {
                for plugin in controller.plugins {
                    if plugin.props.handleTextInput?(controller, range, text) == true {
                        pushTextNow()
                        return false
                    }
                }
            }
            if text == "\n" {
                if parent.controller.handleNewline() {
                    pushTextNow()
                    return false
                }
            }
            if text == "\t", isCursorInListItem(controller: parent.controller) {
                parent.controller.perform(.indent)
                pushTextNow()
                return false
            }
            return true
        }

        /// Cancel any pending debounced push and run one synchronously now.
        /// Used by handlers that have just mutated storage and need the
        /// SwiftUI binding in sync before they return.
        func pushTextNow() {
            pendingTextPush?.cancel()
            pendingTextPush = nil
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
    }
}

private func isCursorInListItem(controller: EditorController) -> Bool {
    let storage = controller.textStorage
    let total = storage.length
    guard total > 0 else { return false }
    let location = controller.currentSelection.location
    let probe = max(0, min(location, total - 1))
    return storage.blockSpec(at: probe)?.isListItem ?? false
}

final class ProseUITextView: UITextView {
    weak var proseController: EditorController?

    override func deleteBackward() {
        if proseController?.handleBackspace() == true { return }
        super.deleteBackward()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Plugins get first crack at navigation/control keys (arrows,
        // Enter, Escape, Tab). Regular text input flows through
        // `textView(_:shouldChangeTextIn:replacementText:)`.
        if let controller = proseController, !controller.plugins.isEmpty {
            for press in presses {
                guard let key = press.key,
                      let name = pluginKeyName(for: key) else { continue }
                for plugin in controller.plugins {
                    if plugin.props.handleKeyDown?(controller, name) == true { return }
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    private func pluginKeyName(for key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardEscape: return "Escape"
        case .keyboardReturnOrEnter, .keypadEnter: return "Enter"
        case .keyboardTab: return "Tab"
        case .keyboardUpArrow: return "ArrowUp"
        case .keyboardDownArrow: return "ArrowDown"
        case .keyboardLeftArrow: return "ArrowLeft"
        case .keyboardRightArrow: return "ArrowRight"
        default: return nil
        }
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        ensureCodeBlockBgLayer()
        scheduleCodeBlockBgUpdate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UITextView IS a UIScrollView, so `bounds.origin` shifts with the
        // current scroll offset. Pinning the layer's origin to (0, 0)
        // anchors it at the content origin instead of the viewport, so the
        // bands scroll naturally with the text.
        codeBlockBgLayer.frame = CGRect(origin: .zero, size: bounds.size)
        scheduleCodeBlockBgUpdate()
    }

    func notifyTextChanged() {
        scheduleCodeBlockBgUpdate()
    }

    private func ensureCodeBlockBgLayer() {
        guard !codeBlockBgLayerInstalled else { return }
        let fill = proseController?.theme.codeBlock.fillColor ?? .codeBlockDefaultFill
        codeBlockBgLayer.fillColor = resolvedFillCGColor(fill)
        codeBlockBgLayer.frame = CGRect(origin: .zero, size: layer.bounds.size)
        layer.insertSublayer(codeBlockBgLayer, at: 0)
        codeBlockBgLayerInstalled = true
    }

    /// Refresh the code-block band fill color from the controller's
    /// theme. Called from `updateUIView` so theme swaps re-tint
    /// without remaking the layer.
    func updateCodeBlockBgLayerFill() {
        guard let controller = proseController else { return }
        codeBlockBgLayer.fillColor = resolvedFillCGColor(controller.theme.codeBlock.fillColor)
    }

    /// `UIColor.cgColor` on a dynamic color resolved with `withAlphaComponent`
    /// can flatten to opaque (alpha=1) when accessed outside a trait-current
    /// scope — observed on iOS where the band rendered as solid black.
    /// Resolving against the view's own trait collection produces a static
    /// UIColor that preserves the alpha, then bridges cleanly to CGColor.
    private func resolvedFillCGColor(_ color: UIColor) -> CGColor {
        color.resolvedColor(with: traitCollection).cgColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            updateCodeBlockBgLayerFill()
        }
    }

    private var bgUpdateScheduled = false

    private func scheduleCodeBlockBgUpdate() {
        guard !bgUpdateScheduled else { return }
        bgUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.bgUpdateScheduled = false
            self?.updateCodeBlockBgPath()
        }
    }

    private func updateCodeBlockBgPath() {
        ensureCodeBlockBgLayer()
        guard let storage = textStorage as? NSTextStorage,
              let layoutManager = textLayoutManager else {
            codeBlockBgLayer.path = nil
            return
        }
        let inset = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        let containerWidth = textContainer.size.width
        let path = CGMutablePath()
        var runStart: Int?
        var runEnd: Int = 0
        let scanRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.proseNodePath, in: scanRange) { value, subRange, _ in
            let isCode: Bool = {
                guard let nodePath = (value as? NodePathBox)?.path else { return false }
                return BlockSpec.fromNodePath(nodePath)?.isCodeBlock == true
            }()
            if isCode {
                if runStart == nil { runStart = subRange.location }
                runEnd = subRange.location + subRange.length
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

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(UIKeyCommand(
            input: "\t",
            modifierFlags: .shift,
            action: #selector(handleShiftTab(_:))
        ))
        commands.append(UIKeyCommand(
            input: "\r",
            modifierFlags: .command,
            action: #selector(handleCommandReturn(_:))
        ))
        return commands
    }

    @objc private func handleShiftTab(_ sender: UIKeyCommand) {
        guard let controller = proseController else { return }
        if isCursorInListItem(controller: controller) {
            controller.perform(.outdent)
        }
    }

    @objc private func handleCommandReturn(_ sender: UIKeyCommand) {
        proseController?.exitCodeBlock()
    }
}
#endif
