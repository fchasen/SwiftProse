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
            // Resolve the table's source range by walking adjacent .pipeTable
            // paragraphs, then parse it once with PipeTableModel so the
            // fragment can dispatch by line role and place column dividers.
            let tableRange = PipeTableModel.pipeTableRunRange(at: elementStart, in: controller.textStorage)
                ?? NSRange(location: elementStart, length: elementEnd - elementStart)
            let prevPipe = (elementStart > 0
                            ? (controller.textStorage.blockSpec(at: elementStart - 1).map { if case .pipeTable = $0.kind { return true } else { return false } } ?? false)
                            : false)
            let nextPipe = (elementEnd < total
                            ? (controller.textStorage.blockSpec(at: elementEnd).map { if case .pipeTable = $0.kind { return true } else { return false } } ?? false)
                            : false)
            fragment.isFirstLine = !prevPipe
            fragment.isLastLine = !nextPipe
            // Apply theme palette so callers can switch palettes per editor.
            let palette = controller.theme.tablePalette
            fragment.borderColor = palette.border
            fragment.headerBackgroundColor = palette.headerBackground
            fragment.toggleColor = palette.toggle
            // Raw mode: skip role/columnXs computation; the fragment falls
            // through to default super.draw and the literal source prints.
            if controller.isTableExpanded(tableRange: tableRange) {
                fragment.isRawMode = true
                return fragment
            }
            // Resolve role + bodyRowIndex by parsing the table source.
            if let model = PipeTableModel.parse(at: elementStart, in: controller.textStorage),
               let lineIdx = model.lineRanges.firstIndex(where: { $0.location <= elementStart && elementStart < $0.location + max(1, $0.length) }) {
                switch model.lineKinds[lineIdx] {
                case .header:
                    fragment.role = .header
                case .alignment:
                    fragment.role = .alignment
                case .body(let row):
                    fragment.role = .body
                    fragment.bodyRowIndex = row
                }
                fragment.columnXs = computeColumnXs(model: model, lineWidth: textContainer(controller).size.width)
            }
            // Top-right toggle hit rect (only the first table line draws it).
            if fragment.isFirstLine {
                fragment.toggleHitRect = CGRect(x: max(0, controller.textContainer.size.width - 22), y: 2, width: 16, height: 16)
            }
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    private func textContainer(_ controller: EditorController) -> NSTextContainer {
        controller.textContainer
    }

    /// Distribute available width evenly across the table's columns. Markdown
    /// has no column-width metadata so equal widths are the natural default
    /// — the rendered chrome lines up cleanly while cell text inside still
    /// wraps within its container as one paragraph.
    private func computeColumnXs(model: PipeTableModel, lineWidth: CGFloat) -> [CGFloat] {
        let cols = max(1, model.columnCount)
        // Subtract the standard text-container padding TextKit applies.
        let padding: CGFloat = 5
        let usable = max(40, lineWidth - 2 * padding)
        let step = usable / CGFloat(cols)
        var xs: [CGFloat] = []
        xs.reserveCapacity(cols + 1)
        for i in 0...cols {
            xs.append(CGFloat(i) * step)
        }
        return xs
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
