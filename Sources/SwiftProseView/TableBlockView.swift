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
///
/// Stage 5 ships read-only cells; stage 6 enables per-cell editing by
/// flipping the cell text views' `isEditable` and wiring `dispatch`.
public final class TableBlockView: PlatformView {
    public private(set) var subtree: TreeNode
    public let theme: ProseTheme
    /// Closure the view calls with `Step.replaceCellInline` transactions
    /// when the user types inside a cell. Stays nil while the editing
    /// surface isn't wired up; cell text views remain non-editable.
    public var dispatch: ((Transaction) -> Void)? {
        didSet { updateCellEditable() }
    }

    private(set) var cellViews: [[CellView]] = []

    /// Minimum cell height. Cell typography sets a higher one if needed.
    static let minRowHeight: CGFloat = 30
    static let minTableWidth: CGFloat = 280
    static let cellHorizontalPadding: CGFloat = 8
    static let cellVerticalPadding: CGFloat = 4
    static let borderWidth: CGFloat = 1

    public init(subtree: TreeNode, theme: ProseTheme) {
        self.subtree = subtree
        self.theme = theme
        super.init(frame: .zero)
        #if canImport(AppKit) && os(macOS)
        wantsLayer = true
        #endif
        rebuild()
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    /// Replace the displayed subtree (e.g. after a structural command).
    public func update(subtree: TreeNode) {
        self.subtree = subtree
        rebuild()
        layoutCells()
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
    }

    public static func intrinsicSize(
        for subtree: TreeNode,
        theme: ProseTheme,
        proposedWidth: CGFloat
    ) -> CGSize {
        let dims = dimensions(of: subtree)
        guard dims.cols > 0, dims.rows > 0 else {
            return CGSize(width: minTableWidth, height: minRowHeight)
        }
        let width = max(proposedWidth, minTableWidth)
        let colWidth = width / CGFloat(dims.cols)
        var totalHeight: CGFloat = 0
        guard case .structural(_, let rows) = subtree else { return .zero }
        for row in rows {
            guard case .structural(_, let cells) = row else { continue }
            var rowHeight = minRowHeight
            for cell in cells {
                let h = CellView.measureHeight(
                    cell: cell,
                    width: colWidth,
                    theme: theme
                )
                rowHeight = max(rowHeight, h)
            }
            totalHeight += rowHeight
        }
        return CGSize(width: width, height: totalHeight + 2 * borderWidth)
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
        let w = bounds.width / CGFloat(dims.cols)
        return Array(repeating: w, count: dims.cols)
    }

    private func rowHeights() -> [CGFloat] {
        guard case .structural(_, let rows) = subtree else { return [] }
        let widths = columnWidths()
        return rows.map { row in
            guard case .structural(_, let cells) = row else { return Self.minRowHeight }
            var h = Self.minRowHeight
            for (idx, cell) in cells.enumerated() {
                let w = idx < widths.count ? widths[idx] : 0
                h = max(h, CellView.measureHeight(cell: cell, width: w, theme: theme))
            }
            return h
        }
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

    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawChrome()
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

/// One cell in a `TableBlockView`. Wraps a platform text input that
/// renders the cell's inline-run subtree. Stage 5: read-only. Stage 6:
/// `setEditable(true)` enables typing; the wrapped text view emits
/// `Transaction`s via the `onEdit` closure.
public final class CellView: PlatformView {
    public let row: Int
    public let column: Int
    public let isHeader: Bool
    public let theme: ProseTheme
    public private(set) var cellNode: TreeNode
    private let textView: PlatformTextView
    private let alignment: PipeTableAlignment
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

        #if canImport(AppKit) && os(macOS)
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NSSize(
            width: TableBlockView.cellHorizontalPadding,
            height: TableBlockView.cellVerticalPadding
        )
        tv.allowsUndo = false
        self.textView = tv
        #else
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = UIEdgeInsets(
            top: TableBlockView.cellVerticalPadding,
            left: TableBlockView.cellHorizontalPadding,
            bottom: TableBlockView.cellVerticalPadding,
            right: TableBlockView.cellHorizontalPadding
        )
        self.textView = tv
        #endif

        super.init(frame: .zero)
        #if canImport(AppKit) && os(macOS)
        wantsLayer = true
        #endif
        addSubview(textView)
        applyAttributedContent()
        wireDelegate()
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    public func setEditable(_ editable: Bool) {
        #if canImport(AppKit) && os(macOS)
        textView.isEditable = editable
        #else
        textView.isEditable = editable
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
        #if canImport(AppKit) && os(macOS)
        textView.textStorage?.setAttributedString(attributed)
        #else
        textView.attributedText = attributed
        #endif
    }

    /// Used by `TableBlockView.intrinsicSize` to size rows before any
    /// view is realized. Walks the cell's inline runs, builds the same
    /// attributed string the view would render, measures wrapping height
    /// at `width`, and adds the cell's vertical padding.
    public static func measureHeight(
        cell: TreeNode,
        width: CGFloat,
        theme: ProseTheme
    ) -> CGFloat {
        guard width > TableBlockView.cellHorizontalPadding * 2 else {
            return TableBlockView.minRowHeight
        }
        let isHeader = cellIsHeader(cell)
        let alignment = parseAlignment(cell)
        let attributed = buildAttributedString(
            cell: cell,
            isHeader: isHeader,
            alignment: alignment,
            theme: theme
        )
        let textWidth = max(0, width - 2 * TableBlockView.cellHorizontalPadding)
        let bounds = attributed.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.height) + 2 * TableBlockView.cellVerticalPadding
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
    /// using the canonical `proseMarks` derivation (font traits etc).
    /// Used by stage 6 cell editing — when the user types, the text
    /// view's content has rendering attributes only; we re-derive marks
    /// before reporting to `onEdit`.
    fileprivate func currentInlineRuns() -> [TreeNode] {
        let attributed: NSAttributedString
        #if canImport(AppKit) && os(macOS)
        attributed = textView.attributedString()
        #else
        attributed = textView.attributedText ?? NSAttributedString()
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
        textView.frame = bounds
    }

    public override var isFlipped: Bool { true }
    #else
    public override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
    }
    #endif

    private func wireDelegate() {
        let proxy = CellEditDelegate { [weak self] in
            guard let self, !self.suppressOnEdit else { return }
            self.onEdit?(self.currentInlineRuns())
        }
        self.delegateProxy = proxy
        #if canImport(AppKit) && os(macOS)
        textView.delegate = proxy
        #else
        textView.delegate = proxy
        #endif
    }

    private var delegateProxy: CellEditDelegate?
}

/// Bridges the text view's edit notification across platforms into a
/// single callback. Held strongly by `CellView` so the delegate doesn't
/// dangle.
private final class CellEditDelegate: NSObject {
    private let onChange: () -> Void
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    #if canImport(AppKit) && os(macOS)
    @objc fileprivate func textDidChange(_ notification: Notification) {
        onChange()
    }
    #endif
}

#if canImport(AppKit) && os(macOS)
extension CellEditDelegate: NSTextViewDelegate {}
#elseif canImport(UIKit)
extension CellEditDelegate: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        onChange()
    }
}
#endif
