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

    public init(
        controller: EditorController,
        text: Binding<String>,
        sizing: EditorSizing = .fitsContent,
        minHeight: CGFloat = 96,
        editMenuBuilder: EditMenuBuilder? = nil
    ) {
        self.controller = controller
        self._text = text
        self.sizing = sizing
        self.minHeight = minHeight
        self.editMenuBuilder = editMenuBuilder
    }

    public func makeUIView(context: Context) -> UITextView {
        let textView = ProseUITextView(frame: .zero, textContainer: controller.textContainer)
        textView.proseController = controller
        textView.delegate = context.coordinator
        textView.font = controller.theme.bodyFont
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .default
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = (sizing == .fillContainer)
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
        return textView
    }

    public func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyExternalText(text, to: uiView)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard sizing == .fitsContent else { return nil }
        if let proposedWidth = proposal.width, proposedWidth > 0 {
            let inset = uiView.textContainerInset
            controller.textContainer.size = CGSize(
                width: max(0, proposedWidth - inset.left - inset.right),
                height: .greatestFiniteMagnitude
            )
        }
        let intrinsic = uiView.intrinsicContentSize
        let width = proposal.width ?? intrinsic.width
        return CGSize(width: width, height: max(intrinsic.height, minHeight))
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, UITextViewDelegate {
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
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.onSelectionChanged?(textView.selectedRange)
        }

        public func textView(_ textView: UITextView,
                             editMenuForTextIn range: NSRange,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
            parent.editMenuBuilder?(range, suggestedActions)
        }

        public func textView(_ textView: UITextView,
                             shouldChangeTextIn range: NSRange,
                             replacementText text: String) -> Bool {
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

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(UIKeyCommand(
            input: "\t",
            modifierFlags: .shift,
            action: #selector(handleShiftTab(_:))
        ))
        return commands
    }

    @objc private func handleShiftTab(_ sender: UIKeyCommand) {
        guard let controller = proseController else { return }
        if isCursorInListItem(controller: controller) {
            controller.perform(.outdent)
        }
    }
}
#endif
