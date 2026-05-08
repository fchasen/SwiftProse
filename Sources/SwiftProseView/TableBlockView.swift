import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// View that renders a `table` `ProseNodeAttachment`'s structural subtree
/// as a grid of cells. Manual frame layout (no Auto Layout). Equal-width
/// columns; row height is the tallest cell's intrinsic height with a
/// minimum.
public final class TableBlockView: PlatformView {
    public private(set) var subtree: TreeNode
    public let theme: ProseTheme
    /// Closure the view calls with `Step.replaceCellInline` transactions
    /// when the user types inside a cell. Stays nil while the editing
    /// surface isn't wired up; cell text views remain non-editable.
    public var dispatch: ((Transaction) -> Void)? {
        didSet { updateCellEditable() }
    }

    /// `(row, column)` of the cell whose text view is currently first
    /// responder. `nil` when focus is outside the table. Updated by
    /// `CellView` on focus events; consumed by `TableCommands` to target
    /// the user's current cell.
    public internal(set) var activeCell: (row: Int, column: Int)?

    /// Move focus to the cell at `(row, column)`. Out-of-range targets
    /// are clamped.
    @discardableResult
    public func focusCell(row rowIdx: Int, column colIdx: Int) -> Bool {
        guard rowIdx >= 0, rowIdx < cellViews.count else { return false }
        let row = cellViews[rowIdx]
        guard colIdx >= 0, colIdx < row.count else { return false }
        return row[colIdx].becomeCellFirstResponder()
    }

    /// Tab / arrow-edge navigation entry point.
    /// `forward` advances cell-by-cell row-major; reaching past the
    /// last cell of the last row inserts a new body row and lands the
    /// caret in the new row's first cell (only when `dispatch` is set
    /// — otherwise we just stop at the boundary).
    @discardableResult
    public func advanceCellFocus(forward: Bool) -> Bool {
        guard let active = activeCell else {
            return focusCell(row: 0, column: 0)
        }
        let dims = TableBlockView.dimensions(of: subtree)
        guard dims.cols > 0, dims.rows > 0 else { return false }
        var row = active.row
        var col = active.column
        if forward {
            col += 1
            if col >= dims.cols { col = 0; row += 1 }
            if row >= dims.rows {
                if let dispatch = dispatch,
                   case .structural(let table, _) = subtree,
                   let last = lastRowIndex() {
                    // Emit an insert-row-below transaction targeting
                    // the last row; the apply path will append the row
                    // and re-render the grid.
                    var rows = subtreeRows()
                    let aligns = columnAlignments()
                    let newRow = makeBlankRow(
                        columnCount: dims.cols,
                        alignments: aligns,
                        isHeader: false
                    )
                    rows.insert(newRow, at: last + 1)
                    let newSubtree = TreeNode.structural(table, rows)
                    dispatch(Transaction(steps: [
                        .setTableSubtree(tableID: table.id, subtree: newSubtree)
                    ]))
                    return focusCell(row: last + 1, column: 0)
                }
                return false
            }
        } else {
            col -= 1
            if col < 0 {
                row -= 1
                col = dims.cols - 1
            }
            if row < 0 { return false }
        }
        return focusCell(row: row, column: col)
    }

    /// Resign first responder on the active cell — Escape handler.
    public func resignActiveCell() {
        guard let active = activeCell,
              active.row < cellViews.count,
              active.column < cellViews[active.row].count else { return }
        cellViews[active.row][active.column].resignCellFirstResponder()
    }

    private func lastRowIndex() -> Int? {
        guard case .structural(_, let rows) = subtree else { return nil }
        return rows.isEmpty ? nil : rows.count - 1
    }
    private func subtreeRows() -> [TreeNode] {
        if case .structural(_, let rows) = subtree { return rows }
        return []
    }
    private func columnAlignments() -> [ProseAttrValue] {
        guard case .structural(_, let rows) = subtree,
              let firstRow = rows.first,
              case .structural(_, let cells) = firstRow else { return [] }
        return cells.compactMap {
            if case .structural(let n, _) = $0 { return n.attrs["align"] ?? .null }
            return nil
        }
    }
    private func makeBlankRow(
        columnCount: Int,
        alignments: [ProseAttrValue],
        isHeader: Bool
    ) -> TreeNode {
        var cells: [TreeNode] = []
        for col in 0..<columnCount {
            let align = col < alignments.count ? alignments[col] : .null
            let cellNode = ProseNode(
                type: isHeader ? "table_header" : "table_cell",
                attrs: [
                    "align": align,
                    "colspan": .int(1),
                    "rowspan": .int(1),
                    "colwidth": .null
                ]
            )
            let para = TreeNode.structural(ProseNode(type: "paragraph"), [])
            cells.append(.structural(cellNode, [para]))
        }
        return .structural(
            ProseNode(type: "table_row", attrs: ["header": .bool(isHeader)]),
            cells
        )
    }

    private(set) var cellViews: [[CellView]] = []

    /// Cached row heights — `nil` entries are stale and re-probed on
    /// next `rowHeights()` call. Targeted invalidation keeps per-
    /// keystroke editing affordable: a single cell edit only invalidates
    /// its row, leaving sibling rows' measurements intact.
    private var cachedRowHeights: [CGFloat?] = []
    /// Cached column widths keyed by container width. Invalidated when
    /// a cell's content changes (natural widths shift) or the container
    /// resizes.
    private var cachedColumnWidths: (containerWidth: CGFloat, widths: [CGFloat])?

    /// Closure fired when the table's reported intrinsic size changes
    /// after a cell or structural mutation. Wired by
    /// `TableAttachmentViewProvider` to invalidate the attachment's
    /// storage range in TextKit 2 so the line fragment hosting this
    /// table re-queries `attachmentBounds` and the document reflows.
    public var layoutDidChange: (() -> Void)?

    /// Minimum cell height. Cell typography sets a higher one if needed.
    static let minRowHeight: CGFloat = 36
    static let minTableWidth: CGFloat = 280
    /// Floor for any column's width — keeps very-narrow tables legible
    /// even when their natural content widths are tiny.
    static let minColumnWidth: CGFloat = 64
    /// Cap on a column's natural single-line width so one long word
    /// can't push a column past the container. Past this width the cell
    /// wraps.
    static let maxNaturalColumnWidth: CGFloat = 360
    /// Headroom (in points) granted to the edited cell before its
    /// column's width is redistributed. Keeping this above zero means
    /// the column grows shortly *before* the cell would actually wrap
    /// rather than at the wrap boundary, smoothing the transition.
    /// Below this threshold typing leaves column widths stable.
    static let columnRedistributionSlack: CGFloat = 12
    static let cellHorizontalPadding: CGFloat = 8
    static let cellVerticalPadding: CGFloat = 6
    static let borderWidth: CGFloat = 1
    /// Sub-pixel rounding buffer added per row. Live measurement now
    /// uses an off-screen `NSTextView` / `UITextView` probe with the
    /// same configuration as the rendered `CellView`, so the only
    /// remaining drift is integer rounding on each row's `usedRect`.
    static let rowMeasurementSlack: CGFloat = 1
    /// Buffer for sub-pixel rounding accumulated across rows.
    static let tableMeasurementSlack: CGFloat = 2

    public init(subtree: TreeNode, theme: ProseTheme) {
        self.subtree = subtree
        self.theme = theme
        super.init(frame: .zero)
        #if canImport(AppKit) && os(macOS)
        wantsLayer = true
        layer?.backgroundColor = TableBlockView.backgroundColor.cgColor
        #else
        backgroundColor = TableBlockView.backgroundColor
        // Without `.redraw`, UIView's default `.scaleToFill` content
        // mode bilinearly stretches the layer's cached drawing
        // (chrome + cell text) when the frame grows after the first
        // paint — which is what made cells look stretched on iOS.
        contentMode = .redraw
        isOpaque = false
        #endif
        rebuild()
    }

    /// Re-resolve appearance-dependent colors and request a full
    /// repaint. Called by the host scroll container when system
    /// appearance changes — the layer's `backgroundColor` was
    /// captured as a CGColor at init / last appearance switch and
    /// won't auto-update on its own; cell text was rendered into an
    /// `NSAttributedString` whose colors must be regenerated under
    /// the new trait/appearance state.
    func refreshAppearance() {
        #if canImport(AppKit) && os(macOS)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor =
                TableBlockView.backgroundColor.cgColor
        }
        needsDisplay = true
        #else
        backgroundColor = TableBlockView.backgroundColor
        setNeedsDisplay()
        #endif
        for row in cellViews {
            for cell in row { cell.refreshAppearance() }
        }
    }

    static var backgroundColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.textBackgroundColor
        #else
        return UIColor.systemBackground
        #endif
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    /// Replace the displayed subtree (e.g. after a structural command).
    public func update(subtree: TreeNode) {
        self.subtree = subtree
        invalidateAllRows()
        invalidateColumnWidths()
        rebuild()
        reflowAfterMutation()
    }

    /// Replace just one cell's inline content (a `Step.replaceCellInline`
    /// follow-up). Avoids tearing down the whole grid for a single
    /// keystroke.
    public func updateCellInline(row rowIdx: Int, column colIdx: Int, runs: [TreeNode]) {
        guard rowIdx < cellViews.count, colIdx < cellViews[rowIdx].count else { return }
        guard case .structural(_, var rows) = subtree else { return }
        guard rowIdx < rows.count,
              case .structural(let rowNode, var cells) = rows[rowIdx],
              colIdx < cells.count,
              case .structural(let cellNode, var cellKids) = cells[colIdx] else { return }
        if !cellKids.isEmpty,
           case .structural(let paraNode, _) = cellKids[0] {
            cellKids[0] = .structural(paraNode, runs)
        } else {
            cellKids = [.structural(ProseNode(type: "paragraph"), runs)]
        }
        cells[colIdx] = .structural(cellNode, cellKids)
        rows[rowIdx] = .structural(rowNode, cells)
        if case .structural(let table, _) = subtree {
            self.subtree = .structural(table, rows)
        }
        cellViews[rowIdx][colIdx].applyInlineRuns(runs)
        invalidateRow(rowIdx)
        // Keep column widths sticky during typing so the grid doesn't
        // reflow on every keystroke. Only redistribute when the edited
        // cell's natural width approaches the current column allocation
        // — i.e. when it's about to wrap. `columnRedistributionSlack`
        // gives the column a bit of headroom so it grows just before
        // overflow rather than at it.
        let cellNeedsMoreRoom: Bool = autoreleasepool {
            guard let cached = cachedColumnWidths,
                  colIdx < cached.widths.count else { return true }
            let editedCell: TreeNode = .structural(cellNode, cellKids)
            let natural = CellView.measureNaturalWidth(cell: editedCell, theme: theme)
            let cappedNatural = min(natural, Self.maxNaturalColumnWidth)
            return cappedNatural + Self.columnRedistributionSlack > cached.widths[colIdx]
        }
        if cellNeedsMoreRoom {
            invalidateColumnWidths()
        }
        reflowAfterMutation()
    }

    /// Recompute intrinsic size against the current container width and
    /// resize the realized view in lock-step. Fires `layoutDidChange`
    /// when the reported size differs from the prior frame so the host
    /// layout manager re-queries `attachmentBounds` (otherwise the line
    /// fragment hosting this table keeps its old height and clips
    /// taller rows).
    private func reflowAfterMutation() {
        let proposedWidth = bounds.width > 0 ? bounds.width : Self.minTableWidth
        let newSize = intrinsicSizeUsingCache(proposedWidth: proposedWidth)
        let sizeChanged = abs(newSize.height - frame.height) > 0.5
            || abs(newSize.width - frame.width) > 0.5
        if sizeChanged {
            // Setting the frame triggers `setFrameSize` / `frame.didSet`,
            // which itself invalidates the caches and re-runs
            // `layoutCells` — match the order of operations in the
            // initial layout path.
            #if canImport(AppKit) && os(macOS)
            self.frame = CGRect(origin: frame.origin, size: newSize)
            needsLayout = true
            needsDisplay = true
            #else
            self.frame = CGRect(origin: frame.origin, size: newSize)
            setNeedsLayout()
            setNeedsDisplay()
            #endif
            layoutDidChange?()
        } else {
            // Width / total height unchanged but a row might have
            // shifted — relayout in place.
            layoutCells()
            #if canImport(AppKit) && os(macOS)
            needsDisplay = true
            #else
            setNeedsDisplay()
            #endif
        }
    }

    private func invalidateRow(_ row: Int) {
        guard row >= 0, row < cachedRowHeights.count else { return }
        cachedRowHeights[row] = nil
    }

    private func invalidateAllRows() {
        cachedRowHeights = Array(
            repeating: nil,
            count: TableBlockView.dimensions(of: subtree).rows
        )
    }

    private func invalidateColumnWidths() {
        cachedColumnWidths = nil
        // Column widths drive cell wrapping; row heights are stale too.
        invalidateAllRows()
    }

    public static func intrinsicSize(
        for subtree: TreeNode,
        theme: ProseTheme,
        proposedWidth: CGFloat
    ) -> CGSize {
        let dims = dimensions(of: subtree)
        guard dims.cols > 0, dims.rows > 0 else {
            return CGSize(width: max(proposedWidth, minTableWidth), height: minRowHeight)
        }
        // Must match the widths `layoutCells` later wraps against.
        let widths = measureColumnWidths(
            for: subtree,
            theme: theme,
            containerWidth: max(proposedWidth, 1)
        )
        let totalWidth = widths.reduce(0, +)
        let heights = measureRowHeights(for: subtree, theme: theme, columnWidths: widths)
        let totalHeight = heights.reduce(0, +)
        return CGSize(
            width: totalWidth,
            height: totalHeight + 2 * borderWidth + tableMeasurementSlack
        )
    }

    /// Instance-side intrinsic size that prefers cached column widths
    /// when they're valid for `proposedWidth`. Keeps `attachmentBounds`
    /// and `reflowAfterMutation` reporting the same height the cells
    /// will actually render at — without this, the static path would
    /// recompute column widths from fresh natural measurements every
    /// keystroke and the reported height would disagree with the
    /// cached widths driving cell layout.
    public func intrinsicSizeUsingCache(proposedWidth: CGFloat) -> CGSize {
        let dims = TableBlockView.dimensions(of: subtree)
        guard dims.cols > 0, dims.rows > 0 else {
            return CGSize(
                width: max(proposedWidth, Self.minTableWidth),
                height: Self.minRowHeight
            )
        }
        let widths: [CGFloat]
        if let cached = cachedColumnWidths,
           abs(cached.containerWidth - proposedWidth) < 0.5,
           cached.widths.count == dims.cols {
            widths = cached.widths
        } else {
            widths = TableBlockView.measureColumnWidths(
                for: subtree,
                theme: theme,
                containerWidth: max(proposedWidth, 1)
            )
            cachedColumnWidths = (containerWidth: proposedWidth, widths: widths)
        }
        let heights = TableBlockView.measureRowHeights(
            for: subtree,
            theme: theme,
            columnWidths: widths
        )
        let totalWidth = widths.reduce(0, +)
        let totalHeight = heights.reduce(0, +)
        return CGSize(
            width: totalWidth,
            height: totalHeight + 2 * Self.borderWidth + Self.tableMeasurementSlack
        )
    }

    /// Compute per-column widths from cell content. Each column's
    /// natural width is the max measured single-line width across its
    /// cells (capped at `maxNaturalColumnWidth`, floored at
    /// `minColumnWidth`). When the column natural total fits in the
    /// container, columns are scaled up proportionally to fill it.
    /// When the natural total exceeds the container, columns keep
    /// their natural widths so each cell renders its single-line
    /// content without crammed wrapping — the host wraps the table in
    /// a horizontal scroll container so the overflow is reachable.
    public static func measureColumnWidths(
        for subtree: TreeNode,
        theme: ProseTheme,
        containerWidth: CGFloat
    ) -> [CGFloat] {
        let dims = dimensions(of: subtree)
        guard dims.cols > 0 else { return [] }
        guard case .structural(_, let rows) = subtree else { return [] }
        var natural = [CGFloat](repeating: minColumnWidth, count: dims.cols)
        for row in rows {
            guard case .structural(_, let cells) = row else { continue }
            for (col, cell) in cells.enumerated() where col < dims.cols {
                // Once a column has hit the cap, further cells in that
                // column can't increase its natural width — skip the
                // probe to avoid spawning a throwaway text view per cell.
                if natural[col] >= maxNaturalColumnWidth { continue }
                autoreleasepool {
                    let w = CellView.measureNaturalWidth(cell: cell, theme: theme)
                    natural[col] = max(natural[col], min(w, maxNaturalColumnWidth))
                }
            }
        }
        natural = natural.map { max($0, minColumnWidth) }
        let target = max(containerWidth, minTableWidth)
        let totalNatural = natural.reduce(0, +)
        guard totalNatural > 0 else {
            return Array(repeating: target / CGFloat(dims.cols), count: dims.cols)
        }
        if totalNatural <= target {
            // Natural fits — scale up proportionally to fill the container.
            // Preserves the content-driven proportions.
            let scale = target / totalNatural
            return natural.map { $0 * scale }
        }
        // Natural exceeds container — keep natural widths so each cell
        // renders its single-line content. The total exceeds the
        // container; the surrounding scroll container handles the
        // overflow by scrolling horizontally.
        return natural
    }

    /// Per-row heights using the supplied column widths. A row's
    /// height is the tallest cell at that column's width, with a
    /// floor of `minRowHeight` and a sub-pixel slack added per row.
    public static func measureRowHeights(
        for subtree: TreeNode,
        theme: ProseTheme,
        columnWidths: [CGFloat]
    ) -> [CGFloat] {
        guard case .structural(_, let rows) = subtree else { return [] }
        return rows.map { row in
            // Drain per row so probe text views and the transient
            // attributed strings they hold don't accumulate across the
            // whole table on a tight measurement pass.
            autoreleasepool {
                guard case .structural(_, let cells) = row else {
                    return minRowHeight + rowMeasurementSlack
                }
                var h = minRowHeight
                for (idx, cell) in cells.enumerated() {
                    let w = idx < columnWidths.count ? columnWidths[idx] : minColumnWidth
                    h = max(h, CellView.measureHeight(cell: cell, width: w, theme: theme))
                }
                return h + rowMeasurementSlack
            }
        }
    }

    public static func dimensions(of subtree: TreeNode) -> (rows: Int, cols: Int) {
        guard case .structural(_, let rows) = subtree else { return (0, 0) }
        let cols = rows.map { row in
            if case .structural(_, let cells) = row { return cells.count }
            return 0
        }.max() ?? 0
        return (rows.count, cols)
    }

    private func rebuild() {
        for row in cellViews { for cell in row { cell.removeFromSuperview() } }
        cellViews = []
        // Reset the row-height cache to match the new structural shape.
        cachedRowHeights = Array(
            repeating: nil,
            count: TableBlockView.dimensions(of: subtree).rows
        )
        cachedColumnWidths = nil
        guard case .structural(_, let rows) = subtree else { return }
        for (rowIdx, row) in rows.enumerated() {
            guard case .structural(let rowNode, let cells) = row else { continue }
            let isHeader = rowNode.attrs["header"]?.boolValue ?? false
            var built: [CellView] = []
            for (colIdx, cell) in cells.enumerated() {
                let cellView = CellView(
                    cell: cell,
                    row: rowIdx,
                    column: colIdx,
                    isHeader: isHeader,
                    theme: theme,
                    onEdit: { [weak self] runs in
                        self?.dispatchCellEdit(row: rowIdx, column: colIdx, runs: runs)
                    }
                )
                addSubview(cellView)
                built.append(cellView)
            }
            cellViews.append(built)
        }
        updateCellEditable()
    }

    private func updateCellEditable() {
        let editable = dispatch != nil
        for row in cellViews { for cell in row { cell.setEditable(editable) } }
    }

    private func dispatchCellEdit(row rowIdx: Int, column colIdx: Int, runs: [TreeNode]) {
        guard let dispatch = dispatch else { return }
        guard case .structural(let table, _) = subtree else { return }
        let step = Step.replaceCellInline(
            tableID: table.id,
            row: rowIdx,
            column: colIdx,
            runs: runs
        )
        dispatch(Transaction(steps: [step]))
    }

    private func columnWidths() -> [CGFloat] {
        let dims = TableBlockView.dimensions(of: subtree)
        guard dims.cols > 0, bounds.width > 0 else { return [] }
        if let cached = cachedColumnWidths,
           abs(cached.containerWidth - bounds.width) < 0.5,
           cached.widths.count == dims.cols {
            return cached.widths
        }
        let widths = TableBlockView.measureColumnWidths(
            for: subtree,
            theme: theme,
            containerWidth: bounds.width
        )
        cachedColumnWidths = (containerWidth: bounds.width, widths: widths)
        return widths
    }

    private func rowHeights() -> [CGFloat] {
        guard case .structural(_, let rows) = subtree else { return [] }
        let widths = columnWidths()
        if cachedRowHeights.count != rows.count {
            cachedRowHeights = Array(repeating: nil, count: rows.count)
        }
        var result: [CGFloat] = []
        result.reserveCapacity(rows.count)
        for (rowIdx, row) in rows.enumerated() {
            if let cached = cachedRowHeights[rowIdx] {
                result.append(cached)
                continue
            }
            let total: CGFloat = autoreleasepool {
                guard case .structural(_, let cells) = row else {
                    return Self.minRowHeight + Self.rowMeasurementSlack
                }
                var h = Self.minRowHeight
                for (idx, cell) in cells.enumerated() {
                    let w = idx < widths.count ? widths[idx] : Self.minColumnWidth
                    h = max(h, CellView.measureHeight(cell: cell, width: w, theme: theme))
                }
                return h + Self.rowMeasurementSlack
            }
            cachedRowHeights[rowIdx] = total
            result.append(total)
        }
        return result
    }

    private func layoutCells() {
        let widths = columnWidths()
        let heights = rowHeights()
        var y: CGFloat = Self.borderWidth
        for (r, rowCells) in cellViews.enumerated() {
            var x: CGFloat = 0
            let rowHeight = r < heights.count ? heights[r] : Self.minRowHeight
            for (c, cell) in rowCells.enumerated() {
                let cw = c < widths.count ? widths[c] : 0
                cell.frame = CGRect(x: x, y: y, width: cw, height: rowHeight)
                x += cw
            }
            y += rowHeight
        }
    }

    #if canImport(AppKit) && os(macOS)
    public override func layout() {
        super.layout()
        layoutCells()
        needsDisplay = true
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateColumnWidths() }
        layoutCells()
        needsDisplay = true
    }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawChrome()
    }
    #else
    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutCells()
        setNeedsDisplay()
    }

    public override var frame: CGRect {
        didSet {
            if abs(frame.width - oldValue.width) > 0.5 {
                invalidateColumnWidths()
            }
            layoutCells()
            setNeedsDisplay()
        }
    }

    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawChrome()
    }

    /// `setNeedsDisplay()` calls during `loadView` happen before the
    /// view is in a window, and on iOS the system honors them only
    /// when there's a layer to render into. Call again now so the
    /// chrome paints on first appearance — without this, tables added
    /// fresh sometimes paint cell text but no border / header bg
    /// until something else (typing, resize) re-dirties the layer.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        layoutCells()
        setNeedsDisplay()
    }
    #endif

    private func drawChrome() {
        let widths = columnWidths()
        let heights = rowHeights()
        let separatorColor = TableBlockView.borderColor
        let headerBg = TableBlockView.headerBackgroundColor

        #if canImport(AppKit) && os(macOS)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #else
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #endif
        context.saveGState()

        // Header row background.
        if let firstHeight = heights.first, isFirstRowHeader() {
            context.setFillColor(headerBg.cgColor)
            context.fill(CGRect(
                x: 0,
                y: TableBlockView.borderWidth,
                width: bounds.width,
                height: firstHeight
            ))
        }

        context.setStrokeColor(separatorColor.cgColor)
        context.setLineWidth(TableBlockView.borderWidth)

        // Outer border.
        context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))

        // Vertical separators.
        var x: CGFloat = 0
        for (i, w) in widths.enumerated() where i < widths.count - 1 {
            x += w
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
        }

        // Horizontal separators.
        var y: CGFloat = TableBlockView.borderWidth
        for (i, h) in heights.enumerated() where i < heights.count - 1 {
            y += h
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func isFirstRowHeader() -> Bool {
        guard case .structural(_, let rows) = subtree,
              let first = rows.first,
              case .structural(let n, _) = first else { return false }
        return n.attrs["header"]?.boolValue ?? false
    }

    static var borderColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor
        #else
        return UIColor.tertiaryLabel
        #endif
    }

    static var headerBackgroundColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.12)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.12)
        #endif
    }
}

/// One cell in a `TableBlockView`. Renders inert via `draw(_:)` until
/// activated, then promotes to a real `NSTextView` / `UITextView` for
/// editing. Demotes back to inert rendering when focus leaves. Holds at
/// most one live text view per cell — instantiating six hundred for a
/// table-heavy document was the original overhead this avoids.
public final class CellView: PlatformView {
    public let row: Int
    public let column: Int
    public let isHeader: Bool
    public let theme: ProseTheme
    public private(set) var cellNode: TreeNode
    private var textView: PlatformTextView?
    private let alignment: PipeTableAlignment
    /// Latest attributed content for the cell. Source of truth when
    /// `textView == nil` (inert mode); rebuilt from `cellNode` on every
    /// `applyAttributedContent` call.
    public private(set) var renderedString: NSAttributedString = NSAttributedString()
    /// Whether typing should be allowed when the cell is promoted. Stored
    /// so a `setEditable(_:)` call before promotion is honored when the
    /// text view is created.
    private var allowsEditing: Bool = false
    /// Closure called with the cell's new inline-run list whenever the
    /// embedded text view's content changes.
    public var onEdit: (([TreeNode]) -> Void)?
    private var suppressOnEdit = false

    public init(
        cell: TreeNode,
        row: Int,
        column: Int,
        isHeader: Bool,
        theme: ProseTheme,
        onEdit: (([TreeNode]) -> Void)? = nil
    ) {
        self.row = row
        self.column = column
        self.isHeader = isHeader
        self.theme = theme
        self.cellNode = cell
        self.alignment = CellView.parseAlignment(cell)
        self.onEdit = onEdit

        super.init(frame: .zero)
        #if canImport(AppKit) && os(macOS)
        wantsLayer = true
        setAccessibilityRole(.textField)
        setAccessibilityElement(true)
        #else
        isAccessibilityElement = true
        accessibilityTraits = isHeader ? [.staticText, .header] : .staticText
        // UIView's default `.scaleToFill` caches the cell text rendered
        // at the first paint and bilinearly stretches it whenever the
        // cell's frame grows — `.redraw` instead invalidates the layer
        // contents on bounds change so the next paint draws fresh.
        contentMode = .redraw
        #endif
        applyAttributedContent()
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    public func setEditable(_ editable: Bool) {
        allowsEditing = editable
        #if canImport(AppKit) && os(macOS)
        textView?.isEditable = editable
        #else
        textView?.isEditable = editable
        #endif
    }

    /// Re-render the cell's `renderedString` so any theme-derived
    /// dynamic colors are resolved under the current appearance.
    /// Called by the table view when the host scroll container
    /// observes a system appearance switch.
    func refreshAppearance() {
        suppressOnEdit = true
        applyAttributedContent()
        suppressOnEdit = false
        #if canImport(AppKit) && os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    public func applyInlineRuns(_ runs: [TreeNode]) {
        if case .structural(let cellNode, var kids) = self.cellNode {
            if !kids.isEmpty,
               case .structural(let para, _) = kids[0] {
                kids[0] = .structural(para, runs)
            } else {
                kids = [.structural(ProseNode(type: "paragraph"), runs)]
            }
            self.cellNode = .structural(cellNode, kids)
        }
        suppressOnEdit = true
        applyAttributedContent()
        suppressOnEdit = false
    }

    private func applyAttributedContent() {
        let attributed = CellView.buildAttributedString(
            cell: cellNode,
            isHeader: isHeader,
            alignment: alignment,
            theme: theme
        )
        renderedString = attributed
        #if canImport(AppKit) && os(macOS)
        setAccessibilityLabel(attributed.string)
        #else
        accessibilityLabel = attributed.string
        #endif
        #if canImport(AppKit) && os(macOS)
        if let tv = textView {
            // Skip the rewrite when the rendered text matches what's already
            // shown — the typing path round-trips through here and resetting
            // the storage would jump the cursor home on every keystroke.
            if tv.textStorage?.string == attributed.string {
                setNeedsDisplay(bounds)
                return
            }
            let priorSelection = tv.selectedRange()
            tv.textStorage?.setAttributedString(attributed)
            let clampedLoc = min(priorSelection.location, attributed.length)
            tv.setSelectedRange(NSRange(location: clampedLoc, length: 0))
        }
        setNeedsDisplay(bounds)
        #else
        if let tv = textView {
            if tv.text == attributed.string {
                setNeedsDisplay()
                return
            }
            let priorSelection = tv.selectedRange
            tv.attributedText = attributed
            let clampedLoc = min(priorSelection.location, attributed.length)
            tv.selectedRange = NSRange(location: clampedLoc, length: 0)
        }
        setNeedsDisplay()
        #endif
    }

    /// Used by `TableBlockView.intrinsicSize` to size rows before any
    /// view is realized. Builds an off-screen `NSTextView` /
    /// `UITextView` configured identically to the live `CellView`,
    /// applies the cell's attributed string, and reads the actual laid-
    /// out content height. This mirrors the live render pixel-for-pixel
    /// — boundingRect / NSLayoutManager-only measurements were under-
    /// counting for cells whose lines wrapped.
    public static func measureHeight(
        cell: TreeNode,
        width: CGFloat,
        theme: ProseTheme
    ) -> CGFloat {
        let isHeader = cellIsHeader(cell)
        let alignment = parseAlignment(cell)
        let attributed: NSAttributedString = {
            let s = buildAttributedString(
                cell: cell,
                isHeader: isHeader,
                alignment: alignment,
                theme: theme
            )
            if s.length > 0 { return s }
            return NSAttributedString(
                string: " ",
                attributes: [.font: isHeader
                    ? theme.bodyFont.withProseTraits(.bold)
                    : theme.bodyFont]
            )
        }()
        let usableWidth = max(1, width)
        return measureViaProbe(attributed: attributed, width: usableWidth)
    }

    /// Single-line natural width of `cell`'s content, measured at
    /// unbounded width. Used by `TableBlockView.measureColumnWidths` to
    /// derive content-aware column proportions before line wrapping
    /// has been decided. Mirrors the pixel-exact configuration of the
    /// live cell text view (padding, font, alignment) so the live
    /// render matches the budget.
    public static func measureNaturalWidth(
        cell: TreeNode,
        theme: ProseTheme
    ) -> CGFloat {
        let isHeader = cellIsHeader(cell)
        let alignment = parseAlignment(cell)
        let attributed = buildAttributedString(
            cell: cell,
            isHeader: isHeader,
            alignment: alignment,
            theme: theme
        )
        if attributed.length == 0 { return TableBlockView.minColumnWidth }
        return measureNaturalWidthViaProbe(attributed: attributed)
    }

    private static func measureNaturalWidthViaProbe(
        attributed: NSAttributedString
    ) -> CGFloat {
        // The probe view is heavy (NSTextView/UITextView pull in a
        // layout manager + text container + storage). Without a local
        // pool, the autoreleased internals — and any objects the
        // layout pass autoreleases — pile up in the run-loop pool
        // until the run loop drains, which is too late on tight
        // measurement passes.
        return autoreleasepool {
            #if canImport(AppKit) && os(macOS)
            let probe = NSTextView(frame: .zero)
            probe.isEditable = false
            probe.isSelectable = false
            probe.drawsBackground = false
            probe.textContainer?.lineFragmentPadding = 0
            probe.textContainer?.widthTracksTextView = false
            probe.textContainerInset = NSSize(
                width: TableBlockView.cellHorizontalPadding,
                height: TableBlockView.cellVerticalPadding
            )
            probe.textContainer?.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            probe.textStorage?.setAttributedString(attributed)
            if let lm = probe.layoutManager, let tc = probe.textContainer {
                lm.ensureLayout(for: tc)
                let used = lm.usedRect(for: tc)
                return ceil(used.width) + 2 * TableBlockView.cellHorizontalPadding
            }
            return TableBlockView.minColumnWidth
            #else
            let probe = UITextView(
                frame: .zero,
                textContainer: nil
            )
            probe.isEditable = false
            probe.isSelectable = false
            probe.backgroundColor = .clear
            probe.textContainer.lineFragmentPadding = 0
            probe.textContainerInset = UIEdgeInsets(
                top: TableBlockView.cellVerticalPadding,
                left: TableBlockView.cellHorizontalPadding,
                bottom: TableBlockView.cellVerticalPadding,
                right: TableBlockView.cellHorizontalPadding
            )
            probe.attributedText = attributed
            let fitting = probe.sizeThatFits(
                CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            )
            return ceil(fitting.width)
            #endif
        }
    }

    private static func measureViaProbe(
        attributed: NSAttributedString,
        width: CGFloat
    ) -> CGFloat {
        // See `measureNaturalWidthViaProbe` for why this needs a local
        // autorelease pool — same reasoning, this path is hotter
        // because every cell of every row goes through it.
        return autoreleasepool {
            #if canImport(AppKit) && os(macOS)
            let probe = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 1))
            probe.isEditable = false
            probe.isSelectable = false
            probe.drawsBackground = false
            probe.textContainer?.lineFragmentPadding = 0
            probe.textContainer?.widthTracksTextView = true
            probe.textContainerInset = NSSize(
                width: TableBlockView.cellHorizontalPadding,
                height: TableBlockView.cellVerticalPadding
            )
            probe.frame.size.width = width
            probe.textContainer?.size = CGSize(
                width: max(1, width - 2 * TableBlockView.cellHorizontalPadding),
                height: .greatestFiniteMagnitude
            )
            probe.textStorage?.setAttributedString(attributed)
            if let lm = probe.layoutManager, let tc = probe.textContainer {
                lm.ensureLayout(for: tc)
                let used = lm.usedRect(for: tc)
                return ceil(used.height) + 2 * TableBlockView.cellVerticalPadding
            }
            return TableBlockView.minRowHeight
            #else
            let probe = UITextView(
                frame: CGRect(x: 0, y: 0, width: width, height: 1),
                textContainer: nil
            )
            probe.isEditable = false
            probe.isSelectable = false
            probe.backgroundColor = .clear
            probe.textContainer.lineFragmentPadding = 0
            probe.textContainerInset = UIEdgeInsets(
                top: TableBlockView.cellVerticalPadding,
                left: TableBlockView.cellHorizontalPadding,
                bottom: TableBlockView.cellVerticalPadding,
                right: TableBlockView.cellHorizontalPadding
            )
            probe.attributedText = attributed
            let fitting = probe.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            )
            return ceil(fitting.height)
            #endif
        }
    }

    private static func cellIsHeader(_ cell: TreeNode) -> Bool {
        if case .structural(let n, _) = cell { return n.type == "table_header" }
        return false
    }

    static func parseAlignment(_ cell: TreeNode) -> PipeTableAlignment {
        if case .structural(let n, _) = cell {
            switch n.attrs["align"]?.stringValue {
            case "left": return .left
            case "right": return .right
            case "center": return .center
            default: return .none
            }
        }
        return .none
    }

    static func buildAttributedString(
        cell: TreeNode,
        isHeader: Bool,
        alignment: PipeTableAlignment,
        theme: ProseTheme
    ) -> NSAttributedString {
        let baseFont = isHeader
            ? theme.bodyFont.withProseTraits(.bold)
            : theme.bodyFont
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: theme.foregroundColor
        ]
        let result = NSMutableAttributedString()
        guard case .structural(_, let kids) = cell else { return result }
        for kid in kids {
            guard case .structural(let p, let inlineKids) = kid, p.type == "paragraph" else { continue }
            for run in inlineKids {
                if case .inline(let text, let marks) = run, !text.isEmpty {
                    var attrs = baseAttrs
                    if marks.contains(type: "strong") {
                        let f = (attrs[.font] as? PlatformFont) ?? theme.bodyFont
                        attrs[.font] = f.withProseTraits(f.proseTraits.union(.bold))
                    }
                    if marks.contains(type: "em") {
                        let f = (attrs[.font] as? PlatformFont) ?? theme.bodyFont
                        attrs[.font] = f.withProseTraits(f.proseTraits.union(.italic))
                    }
                    if marks.contains(type: "code") {
                        attrs[.font] = theme.monospaceFont
                    }
                    if marks.contains(type: "strike") {
                        attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if let link = marks.marks.first(where: { $0.type == "link" }),
                       let href = link.attrs["href"]?.stringValue {
                        attrs[.foregroundColor] = theme.linkColor
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                        attrs[.link] = URL(string: href) ?? href
                    }
                    result.append(NSAttributedString(string: text, attributes: attrs))
                }
            }
        }
        let para = NSMutableParagraphStyle()
        switch alignment {
        case .left, .none: para.alignment = .natural
        case .right: para.alignment = .right
        case .center: para.alignment = .center
        }
        para.lineBreakMode = .byWordWrapping
        if result.length > 0 {
            result.addAttribute(
                .paragraphStyle,
                value: para,
                range: NSRange(location: 0, length: result.length)
            )
        }
        return result
    }

    /// Walk the live text view's storage and re-derive `[TreeNode]` runs
    /// via `NodePathSynthesizer` so font traits map back to canonical
    /// `proseMarks` before reporting to `onEdit`.
    fileprivate func currentInlineRuns() -> [TreeNode] {
        guard let tv = textView else { return [] }
        let attributed: NSAttributedString
        #if canImport(AppKit) && os(macOS)
        attributed = tv.attributedString()
        #else
        attributed = tv.attributedText ?? NSAttributedString()
        #endif
        let mutable = NSMutableAttributedString(attributedString: attributed)
        guard mutable.length > 0 else { return [] }
        let fullRange = NSRange(location: 0, length: mutable.length)
        NodePathSynthesizer().stampMarks(
            in: mutable,
            blockRange: fullRange,
            spec: .paragraph
        )
        var runs: [TreeNode] = []
        let ns = mutable.string as NSString
        mutable.enumerateAttribute(.proseMarks, in: fullRange) { value, runRange, _ in
            guard runRange.length > 0 else { return }
            let marks = (value as? MarkSetBox)?.marks ?? MarkSet()
            let runText = ns.substring(with: runRange)
            if !runText.isEmpty {
                runs.append(.inline(text: runText, marks: marks))
            }
        }
        return runs
    }

    #if canImport(AppKit) && os(macOS)
    public override func layout() {
        super.layout()
        textView?.frame = bounds
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textView?.frame = bounds
    }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard textView == nil, renderedString.length > 0 else { return }
        let drawRect = inertDrawRect()
        renderedString.draw(in: drawRect)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, textView != nil { seedTextViewStorage() }
    }

    public override func mouseDown(with event: NSEvent) {
        if textView == nil, allowsEditing {
            promoteToTextView()
            if let tv = textView {
                tv.window?.makeFirstResponder(tv)
                // Forward the original mouseDown so the text view places
                // the caret at the click point on the same gesture event.
                tv.mouseDown(with: event)
                return
            }
        }
        super.mouseDown(with: event)
    }
    #else
    public override func layoutSubviews() {
        super.layoutSubviews()
        textView?.frame = bounds
    }

    public override var frame: CGRect {
        didSet {
            textView?.frame = bounds
            // The frame.didSet inherited from UIView doesn't trigger
            // `draw(_:)` on bounds change unless we explicitly mark
            // the layer needs display. Without this, cell text drawn
            // at the previous bounds gets bilinearly stretched into
            // the new bounds via `contentMode`'s default cache.
            if abs(frame.size.width - oldValue.size.width) > 0.5
                || abs(frame.size.height - oldValue.size.height) > 0.5 {
                setNeedsDisplay()
            }
        }
    }

    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard textView == nil, renderedString.length > 0 else { return }
        let drawRect = inertDrawRect()
        renderedString.draw(in: drawRect)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, textView != nil { seedTextViewStorage() }
        if window != nil { setNeedsDisplay() }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if textView == nil, allowsEditing {
            promoteToTextView()
            if let tv = textView {
                tv.becomeFirstResponder()
                if let touch = touches.first {
                    let loc = touch.location(in: tv)
                    if let pos = tv.closestPosition(to: loc) {
                        let off = tv.offset(from: tv.beginningOfDocument, to: pos)
                        tv.selectedRange = NSRange(location: off, length: 0)
                    }
                }
                return
            }
        }
        super.touchesBegan(touches, with: event)
    }
    #endif

    private func inertDrawRect() -> CGRect {
        return CGRect(
            x: TableBlockView.cellHorizontalPadding,
            y: TableBlockView.cellVerticalPadding,
            width: max(0, bounds.width - 2 * TableBlockView.cellHorizontalPadding),
            height: max(0, bounds.height - 2 * TableBlockView.cellVerticalPadding)
        )
    }

    private func makeTextView() -> PlatformTextView {
        #if canImport(AppKit) && os(macOS)
        let tv = NSTextView()
        tv.isEditable = allowsEditing
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainerInset = NSSize(
            width: TableBlockView.cellHorizontalPadding,
            height: TableBlockView.cellVerticalPadding
        )
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.allowsUndo = false
        return tv
        #else
        let tv = UITextView()
        tv.isEditable = allowsEditing
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = UIEdgeInsets(
            top: TableBlockView.cellVerticalPadding,
            left: TableBlockView.cellHorizontalPadding,
            bottom: TableBlockView.cellVerticalPadding,
            right: TableBlockView.cellHorizontalPadding
        )
        return tv
        #endif
    }

    private func promoteToTextView() {
        guard textView == nil else { return }
        let tv = makeTextView()
        tv.frame = bounds
        textView = tv
        wireDelegate()
        addSubview(tv)
        seedTextViewStorage()
        #if canImport(AppKit) && os(macOS)
        setNeedsDisplay(bounds)
        #else
        setNeedsDisplay()
        #endif
    }

    /// Copy `renderedString` into the live text view's storage. Only
    /// runs once the text view is attached to a window — setting storage
    /// on an unattached `NSTextView` triggers `_fixSelectionAfterChange…`
    /// which lazy-instantiates the system cursor UI singleton, and that
    /// must happen on the main thread. In headless tests where the cell
    /// never reaches a window, the text view stays empty (which is
    /// fine — there's no rendering surface to show it on).
    private func seedTextViewStorage() {
        guard let tv = textView else { return }
        guard tv.window != nil else { return }
        suppressOnEdit = true
        #if canImport(AppKit) && os(macOS)
        tv.textStorage?.setAttributedString(renderedString)
        #else
        tv.attributedText = renderedString
        #endif
        suppressOnEdit = false
    }

    fileprivate func demoteFromTextView() {
        guard let tv = textView else { return }
        // Capture latest content so the inert paint shows what the user
        // typed even before the controller round-trip finishes.
        let attributed: NSAttributedString
        #if canImport(AppKit) && os(macOS)
        attributed = tv.attributedString()
        #else
        attributed = tv.attributedText ?? NSAttributedString()
        #endif
        if attributed.length > 0 {
            renderedString = attributed
        }
        tv.removeFromSuperview()
        textView = nil
        delegateProxy = nil
        #if canImport(AppKit) && os(macOS)
        setNeedsDisplay(bounds)
        #else
        setNeedsDisplay()
        #endif
    }

    private func wireDelegate() {
        guard let tv = textView else { return }
        let proxy = CellEditDelegate(
            onChange: { [weak self] in
                guard let self, !self.suppressOnEdit else { return }
                self.onEdit?(self.currentInlineRuns())
            },
            onFocus: { [weak self] in
                self?.markActive()
            },
            onEndEdit: { [weak self] in
                self?.demoteFromTextView()
            },
            onTab: { [weak self] forward in
                self?.tableParent()?.advanceCellFocus(forward: forward) ?? false
            },
            onEscape: { [weak self] in
                guard let table = self?.tableParent() else { return false }
                table.resignActiveCell()
                return true
            }
        )
        self.delegateProxy = proxy
        tv.delegate = proxy
    }

    /// Make this cell's text view the first responder. Used by Tab /
    /// click navigation. Promotes to a live text view if none exists.
    @discardableResult
    public func becomeCellFirstResponder() -> Bool {
        if textView == nil {
            promoteToTextView()
        }
        guard let tv = textView else { return false }
        #if canImport(AppKit) && os(macOS)
        return tv.window?.makeFirstResponder(tv) == true
        #else
        return tv.becomeFirstResponder()
        #endif
    }

    public func resignCellFirstResponder() {
        guard let tv = textView else { return }
        #if canImport(AppKit) && os(macOS)
        tv.window?.makeFirstResponder(nil)
        #else
        tv.resignFirstResponder()
        #endif
    }

    private func markActive() {
        // Walk up to the parent TableBlockView and record this cell as
        // active. Toolbar / command targeting reads it.
        if let table = self.tableParent() {
            table.activeCell = (row, column)
        }
    }

    private func tableParent() -> TableBlockView? {
        var v: PlatformView? = self.superview
        while let cur = v {
            if let t = cur as? TableBlockView { return t }
            v = cur.superview
        }
        return nil
    }

    private var delegateProxy: CellEditDelegate?
}

private final class CellEditDelegate: NSObject {
    fileprivate let onChange: () -> Void
    fileprivate let onFocus: () -> Void
    fileprivate let onEndEdit: () -> Void
    fileprivate let onTab: (Bool) -> Bool
    fileprivate let onEscape: () -> Bool
    init(
        onChange: @escaping () -> Void,
        onFocus: @escaping () -> Void,
        onEndEdit: @escaping () -> Void,
        onTab: @escaping (Bool) -> Bool,
        onEscape: @escaping () -> Bool
    ) {
        self.onChange = onChange
        self.onFocus = onFocus
        self.onEndEdit = onEndEdit
        self.onTab = onTab
        self.onEscape = onEscape
    }

    #if canImport(AppKit) && os(macOS)
    @objc fileprivate func textDidChange(_ notification: Notification) {
        onChange()
    }
    @objc fileprivate func textDidBeginEditing(_ notification: Notification) {
        onFocus()
    }
    @objc fileprivate func textDidEndEditing(_ notification: Notification) {
        onEndEdit()
    }
    #endif
}

#if canImport(AppKit) && os(macOS)
extension CellEditDelegate: NSTextViewDelegate {
    @objc func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return onTab(true)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return onTab(false)
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            return onEscape()
        }
        return false
    }
}
#elseif canImport(UIKit)
extension CellEditDelegate: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        onChange()
    }
    func textViewDidBeginEditing(_ textView: UITextView) {
        onFocus()
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        onEndEdit()
    }
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text == "\t" {
            _ = onTab(true)
            return false
        }
        return true
    }
}
#endif
