import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class LayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {
    public weak var controller: EditorController?
    public var decorationProvider: DecorationProvider = BlockSpecDecorationProvider()

    public init(controller: EditorController? = nil) {
        self.controller = controller
        super.init()
    }

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let controller,
              let elementRange = textElement.elementRange else {
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        let storage = controller.contentStorage
        let elementStart = storage.offset(from: storage.documentRange.location, to: elementRange.location)
        let elementEnd = storage.offset(from: storage.documentRange.location, to: elementRange.endLocation)
        let total = controller.textStorage.length
        guard total > 0,
              elementStart >= 0,
              elementStart < total,
              elementEnd >= elementStart,
              elementEnd <= total else {
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }

        let lineRange = NSRange(location: elementStart, length: elementEnd - elementStart)
        let decorations = decorationProvider.decorations(in: lineRange, storage: controller.textStorage)
        if let bar = decorations.first(where: { if case .blockquoteBar = $0.kind { return true } else { return false } }) {
            if case .blockquoteBar(_, let position) = bar.kind {
                let fragment = BlockquoteLayoutFragment(textElement: textElement, range: textElement.elementRange)
                fragment.isFirstInRun = position == .start || position == .single
                fragment.isLastInRun = position == .end || position == .single
                fragment.barColor = controller.theme.blockquote.barColor
                fragment.inlineCodeFillColor = controller.theme.codeBlock.fillColor
                return fragment
            }
        }
        if let codeDeco = decorations.first(where: { if case .codeBackground = $0.kind { return true } else { return false } }) {
            if case .codeBackground(let language, let position) = codeDeco.kind {
                let containerWidth = controller.textContainer.size.width
                let codeStyle = controller.theme.codeBlock
                if let language {
                    let fragment = FencedCodeBlockLayoutFragment(
                        textElement: textElement,
                        range: textElement.elementRange
                    )
                    fragment.language = language
                    fragment.isFirstLine = position == .start || position == .single
                    fragment.isLastLine = position == .end || position == .single
                    fragment.containerWidth = containerWidth
                    fragment.fillColor = codeStyle.fillColor
                    fragment.languageTagColor = codeStyle.languageTagColor
                    return fragment
                } else if let path = controller.textStorage.nodePath(at: elementStart),
                          path.leaf?.type == "code_block",
                          path.leaf?.attrs["fenced"]?.boolValue == false {
                    let fragment = IndentedCodeBlockLayoutFragment(
                        textElement: textElement,
                        range: textElement.elementRange
                    )
                    fragment.isFirstLine = position == .start || position == .single
                    fragment.isLastLine = position == .end || position == .single
                    fragment.containerWidth = containerWidth
                    fragment.fillColor = codeStyle.fillColor
                    return fragment
                } else {
                    let fragment = FencedCodeBlockLayoutFragment(
                        textElement: textElement,
                        range: textElement.elementRange
                    )
                    fragment.language = nil
                    fragment.isFirstLine = position == .start || position == .single
                    fragment.isLastLine = position == .end || position == .single
                    fragment.containerWidth = containerWidth
                    fragment.fillColor = codeStyle.fillColor
                    fragment.languageTagColor = codeStyle.languageTagColor
                    return fragment
                }
            }
        }
        if rangeContainsCodeSpan(controller.textStorage, range: lineRange) {
            let fragment = InlineCodePainterLayoutFragment(textElement: textElement, range: textElement.elementRange)
            fragment.fillColor = controller.theme.codeBlock.fillColor
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    private func textContainer(_ controller: EditorController) -> NSTextContainer {
        controller.textContainer
    }

    /// Cheap scan: returns `true` if any character in `range` carries
    /// `.proseInline = .codeSpan`. Used to decide whether to upgrade the
    /// default fragment to one that paints rounded code-span backdrops.
    private func rangeContainsCodeSpan(_ storage: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0, range.location + range.length <= storage.length else { return false }
        var found = false
        storage.enumerateAttribute(.proseInline, in: range) { value, _, stop in
            if let tag = value as? InlineTag, tag == .codeSpan {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
