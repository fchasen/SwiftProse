import Foundation
import MarginaliaSyntax
import MarginaliaRendering
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
                return fragment
            }
        }
        if let codeDeco = decorations.first(where: { if case .codeBackground = $0.kind { return true } else { return false } }) {
            if case .codeBackground(let language, let position) = codeDeco.kind {
                if let language {
                    let fragment = FencedCodeBlockLayoutFragment(
                        textElement: textElement,
                        range: textElement.elementRange
                    )
                    fragment.language = language
                    fragment.isFirstLine = position == .start || position == .single
                    fragment.isLastLine = position == .end || position == .single
                    return fragment
                } else if let spec = controller.textStorage.blockSpec(at: elementStart),
                          case .indentedCode = spec.kind {
                    let fragment = IndentedCodeBlockLayoutFragment(
                        textElement: textElement,
                        range: textElement.elementRange
                    )
                    fragment.isFirstLine = position == .start || position == .single
                    fragment.isLastLine = position == .end || position == .single
                    return fragment
                } else {
                    let fragment = FencedCodeBlockLayoutFragment(
                        textElement: textElement,
                        range: textElement.elementRange
                    )
                    fragment.language = nil
                    fragment.isFirstLine = position == .start || position == .single
                    fragment.isLastLine = position == .end || position == .single
                    return fragment
                }
            }
        }
        if decorations.contains(where: { if case .horizontalRule = $0.kind { return true } else { return false } }) {
            return HorizontalRuleLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        if let spec = paragraphSpec(in: controller.textStorage, from: elementStart, to: elementEnd),
           case .pipeTable = spec.kind {
            let fragment = PipeTableLayoutFragment(
                textElement: textElement,
                range: textElement.elementRange
            )
            // Approximate run position by walking neighbors directly.
            let prevPipe = (elementStart > 0
                            ? (controller.textStorage.blockSpec(at: elementStart - 1).map { if case .pipeTable = $0.kind { return true } else { return false } } ?? false)
                            : false)
            let nextPipe = (elementEnd < total
                            ? (controller.textStorage.blockSpec(at: elementEnd).map { if case .pipeTable = $0.kind { return true } else { return false } } ?? false)
                            : false)
            fragment.isFirstLine = !prevPipe
            fragment.isLastLine = !nextPipe
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    private func paragraphSpec(in storage: NSAttributedString, from lo: Int, to hi: Int) -> BlockSpec? {
        var i = lo
        while i < hi {
            if let spec = storage.blockSpec(at: i) { return spec }
            i += 1
        }
        return nil
    }
}
