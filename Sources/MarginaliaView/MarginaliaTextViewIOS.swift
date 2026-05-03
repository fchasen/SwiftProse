#if canImport(UIKit)
import UIKit
import SwiftUI
import MarginaliaSyntax
import MarginaliaRendering

public struct MarginaliaTextViewIOS: UIViewRepresentable {
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
        let textView = MarginaliaUITextView(frame: .zero, textContainer: controller.textContainer)
        textView.marginaliaController = controller
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
        var parent: MarginaliaTextViewIOS
        weak var textView: UITextView?
        var lastAppliedMarkdown: String

        init(_ parent: MarginaliaTextViewIOS) {
            self.parent = parent
            self.lastAppliedMarkdown = parent.text
        }

        func applyExternalText(_ md: String, to: UITextView) {
            if md != lastAppliedMarkdown {
                if parent.controller.markdown() != md {
                    parent.controller.setMarkdown(md)
                }
                lastAppliedMarkdown = md
            }
        }

        public func textViewDidChange(_ textView: UITextView) {
            let md = parent.controller.markdown()
            if parent.text != md {
                parent.text = md
            }
            lastAppliedMarkdown = md
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
                    let md = parent.controller.markdown()
                    if parent.text != md { parent.text = md }
                    lastAppliedMarkdown = md
                    return false
                }
            }
            if text == "\t", isCursorInListItem(controller: parent.controller) {
                parent.controller.perform(.indent)
                let md = parent.controller.markdown()
                if parent.text != md { parent.text = md }
                lastAppliedMarkdown = md
                return false
            }
            return true
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

final class MarginaliaUITextView: UITextView {
    weak var marginaliaController: EditorController?

    override func deleteBackward() {
        if marginaliaController?.handleBackspace() == true { return }
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
        guard let controller = marginaliaController else { return }
        if isCursorInListItem(controller: controller) {
            controller.perform(.outdent)
        }
    }
}
#endif
