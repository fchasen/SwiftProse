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
                let containerWidth = controller.textContainer.size.width
                if let language {
                    let fragment = FencedCodeBlockLayoutFragment(
                        textElement: textElement,
                        range: textElement.elementRange
                    )
                    fragment.language = language
                    fragment.isFirstLine = position == .start || position == .single
                    fragment.isLastLine = position == .end || position == .single
                    fragment.containerWidth = containerWidth
                    return fragment
                } else if let spec = controller.textStorage.blockSpec(at: elementStart),
                          case .indentedCode = spec.kind {
                    let fragment = IndentedCodeBlockLayoutFragment(
                        textElement: textElement,
                        range: textElement.elementRange
                    )
                    fragment.isFirstLine = position == .start || position == .single
                    fragment.isLastLine = position == .end || position == .single
                    fragment.containerWidth = containerWidth
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
                    return fragment
                }
            }
        }
        if decorations.contains(where: { if case .horizontalRule = $0.kind { return true } else { return false } }) {
            return HorizontalRuleLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        if rangeContainsCodeSpan(controller.textStorage, range: lineRange) {
            return InlineCodePainterLayoutFragment(textElement: textElement, range: textElement.elementRange)
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
            fragment.separatorColor = palette.separator
            fragment.headerBackgroundColor = palette.headerBackground
            fragment.bodyAltBackgroundColor = palette.bodyAltBackground
            fragment.toggleColor = palette.toggle
            // Whole-table raw mode toggle — falls through to `super.draw`
            // so the literal source prints. Per-row editing is intentionally
            // not wired here; cell-content edits aren't yet routed back into
            // the painted cells.
            if controller.isTableExpanded(tableRange: tableRange) {
                fragment.isRawMode = true
                return fragment
            }
            // Resolve role + bodyRowIndex by parsing the table source.
            let containerWidth = controller.textContainer.size.width
            fragment.containerWidth = containerWidth
            if let model = PipeTableModel.parse(at: elementStart, in: controller.textStorage),
               let lineIdx = model.lineRanges.firstIndex(where: { $0.location <= elementStart && elementStart < $0.location + max(1, $0.length) }) {
                let theme = controller.theme
                let bodyFormatter = PipeTableCellFormatters.body(theme: theme)
                let headerFormatter = PipeTableCellFormatters.header(theme: theme)
                let attributedHeader = model.headerCells.map { headerFormatter.format($0) }
                let attributedBody: [[NSAttributedString]] = model.bodyRows.map { row in
                    row.map { bodyFormatter.format($0) }
                }
                let columnWidths = PipeTableMetrics.columnWidths(
                    natural: PipeTableMetrics.naturalColumnWidths(
                        headerCells: attributedHeader,
                        bodyRows: attributedBody,
                        columnCount: model.columnCount
                    ),
                    containerWidth: usableTableWidth(controller: controller, containerWidth: containerWidth),
                    cellPaddingHorizontal: fragment.cellPaddingHorizontal
                )
                fragment.columnXs = PipeTableMetrics.columnXs(widths: columnWidths)
                fragment.alignments = model.alignments
                switch model.lineKinds[lineIdx] {
                case .header:
                    fragment.role = .header
                    fragment.attributedCells = attributedHeader
                case .alignment:
                    fragment.role = .alignment
                case .body(let row):
                    fragment.role = .body
                    fragment.bodyRowIndex = row
                    fragment.attributedCells = (row < attributedBody.count) ? attributedBody[row] : []
                }
                // The row's paragraph style controls fragment height; ask
                // the controller to stamp wrapped row heights so cells with
                // multi-line content get enough vertical space. Async so we
                // don't mutate storage attributes during layout.
                controller.scheduleTableHeightStamp(containerWidth: containerWidth)
            }
            // Top-right toggle hit rect (only the first table line draws it).
            // Container-anchored coords; renderingSurfaceBounds extends to
            // container width so this is reachable for hit-testing.
            if fragment.isFirstLine {
                let toggleSize: CGFloat = 16
                let toggleInset: CGFloat = 6
                fragment.toggleHitRect = CGRect(
                    x: containerWidth - toggleInset - toggleSize,
                    y: 2,
                    width: toggleSize,
                    height: toggleSize
                )
            }
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    private func textContainer(_ controller: EditorController) -> NSTextContainer {
        controller.textContainer
    }

    /// Effective horizontal area available for the table chrome. The text
    /// container reports its full width but TextKit reserves a small
    /// `lineFragmentPadding` strip on each side; subtracting it keeps the
    /// chrome from sliding under the right-edge gutter.
    private func usableTableWidth(controller: EditorController, containerWidth: CGFloat) -> CGFloat {
        let padding: CGFloat = controller.textContainer.lineFragmentPadding
        return max(40, containerWidth - 2 * padding)
    }

    private func paragraphSpec(in storage: NSAttributedString, from lo: Int, to hi: Int) -> BlockSpec? {
        var i = lo
        while i < hi {
            if let spec = storage.blockSpec(at: i) { return spec }
            i += 1
        }
        return nil
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
