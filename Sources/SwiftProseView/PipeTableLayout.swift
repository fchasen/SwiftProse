import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Per-cell formatter factory. Builds a `CellAttributedFormatter` configured
/// with the editor's theme so the layout fragment and the row-height
/// stamper produce identical attributed cells.
public enum PipeTableCellFormatters {
    public static func body(theme: ProseTheme) -> CellAttributedFormatter {
        CellAttributedFormatter(
            bodyFont: theme.bodyFont,
            monospaceFont: theme.monospaceFont,
            foregroundColor: theme.foregroundColor,
            linkColor: theme.linkColor,
            codeBackground: codeBackground(),
            bold: false
        )
    }

    public static func header(theme: ProseTheme) -> CellAttributedFormatter {
        CellAttributedFormatter(
            bodyFont: theme.bodyFont,
            monospaceFont: theme.monospaceFont,
            foregroundColor: theme.foregroundColor,
            linkColor: theme.linkColor,
            codeBackground: codeBackground(),
            bold: true
        )
    }

    private static func codeBackground() -> PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.15)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.15)
        #endif
    }
}

/// Stamps row-level paragraph styles on every pipe-table run in storage so
/// each table row's layout-fragment height matches the wrapped cell content
/// at the current container width.
///
/// TextKit 2 derives a layout fragment's vertical extent from its text-line
/// fragments, which in turn are governed by `paragraphStyle.minimumLineHeight`.
/// Stamping `min`/`maxLineHeight` is the lever that lets us push a single-
/// paragraph table row tall enough to host wrapped multi-line cells.
struct PipeTableHeightStamper {
    let storage: NSTextStorage
    let theme: ProseTheme
    let containerWidth: CGFloat
    /// Cell padding values must mirror the layout fragment defaults so that
    /// `requiredCellHeight` measures with the same insets that the fragment
    /// will draw with.
    let cellPaddingHorizontal: CGFloat
    let cellPaddingVertical: CGFloat
    /// Floor for any single row — comfortably accommodates body-font line
    /// height with vertical padding so empty cells don't collapse.
    let minimumRowHeight: CGFloat

    /// Walk every pipe-table run and apply per-row `minimumLineHeight`.
    /// Returns true when at least one paragraph style was changed (the
    /// caller invalidates intrinsic size in that case).
    @discardableResult
    func stamp() -> Bool {
        guard storage.length > 0, containerWidth > 0 else { return false }
        let bodyFormatter = PipeTableCellFormatters.body(theme: theme)
        let headerFormatter = PipeTableCellFormatters.header(theme: theme)
        var changed = false
        var cursor = 0
        let total = storage.length
        while cursor < total {
            guard let spec = storage.blockSpec(at: cursor),
                  case .pipeTable = spec.kind else {
                cursor = nextLineStart(after: cursor)
                continue
            }
            guard let runRange = PipeTableModel.pipeTableRunRange(at: cursor, in: storage),
                  let model = PipeTableModel.parse(at: cursor, in: storage) else {
                cursor = nextLineStart(after: cursor)
                continue
            }
            if stampOne(model: model, bodyFormatter: bodyFormatter, headerFormatter: headerFormatter) {
                changed = true
            }
            cursor = max(cursor + 1, runRange.location + runRange.length)
        }
        return changed
    }

    private func stampOne(
        model: PipeTableModel,
        bodyFormatter: CellAttributedFormatter,
        headerFormatter: CellAttributedFormatter
    ) -> Bool {
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
            containerWidth: containerWidth,
            cellPaddingHorizontal: cellPaddingHorizontal
        )
        var changed = false
        for (lineIdx, lineRange) in model.lineRanges.enumerated() {
            guard lineRange.length > 0,
                  lineRange.location + lineRange.length <= storage.length else { continue }
            let kind = model.lineKinds[lineIdx]
            // Alignment row keeps its existing collapsed paragraph style;
            // overwriting with a tall minLineHeight would resurrect the
            // 1-line dash strip we're hiding.
            if case .alignment = kind { continue }
            let cells: [NSAttributedString]
            switch kind {
            case .header: cells = attributedHeader
            case .body(let r): cells = (r < attributedBody.count) ? attributedBody[r] : []
            case .alignment: continue
            }
            let needed = max(
                minimumRowHeight,
                PipeTableMetrics.requiredCellHeight(
                    cells: cells,
                    columnWidths: columnWidths,
                    cellPaddingHorizontal: cellPaddingHorizontal,
                    cellPaddingVertical: cellPaddingVertical
                )
            )
            if applyRowHeight(needed, to: lineRange) { changed = true }
        }
        return changed
    }

    private func applyRowHeight(_ height: CGFloat, to range: NSRange) -> Bool {
        let safe = range.clamped(to: storage.length)
        guard safe.length > 0 else { return false }
        let existing = storage.attribute(.paragraphStyle, at: safe.location, effectiveRange: nil) as? NSParagraphStyle
        let mutable: NSMutableParagraphStyle
        if let copy = existing?.mutableCopy() as? NSMutableParagraphStyle {
            mutable = copy
        } else {
            mutable = NSMutableParagraphStyle()
        }
        if abs(mutable.minimumLineHeight - height) < 0.5 &&
           abs(mutable.maximumLineHeight - height) < 0.5 {
            return false
        }
        mutable.minimumLineHeight = height
        mutable.maximumLineHeight = height
        storage.addAttribute(.paragraphStyle, value: mutable, range: safe)
        return true
    }

    private func nextLineStart(after location: Int) -> Int {
        let ns = storage.string as NSString
        guard location < ns.length else { return ns.length }
        let line = ns.paragraphRange(for: NSRange(location: location, length: 0))
        return max(location + 1, line.location + line.length)
    }
}
