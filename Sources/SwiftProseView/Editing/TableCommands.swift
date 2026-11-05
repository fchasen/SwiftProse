import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension EditorController {
    func performTableAction(_ action: EditorAction) {
        switch action {
        case .insertTable(let rows, let columns):
            insertTable(rows: rows, columns: columns)
        case .editTableStructure:
            if let model = tableStructure() { onEditTableStructure?(model) }
        default:
            let selection = currentSelection
            guard let context = tableContext(at: selection.location),
                  let position = context.position(of: selection.location) else { return }
            performTableAction(action, context: context, row: position.row, column: position.column)
        }
    }

    func canPerformTableAction(_ action: EditorAction) -> Bool {
        guard isEditable else { return false }
        if case .insertTable = action {
            return !paragraphInfo(at: currentSelection.location).block.isCode
        }
        return isSelectionInTable
    }

    func currentTableColumnAlignment() -> TableColumnAlignment? {
        let location = currentSelection.location
        guard let context = tableContext(at: location), let position = context.position(of: location) else { return nil }
        let alignments = context.alignments
        return position.column < alignments.count ? alignments[position.column] : TableColumnAlignment.none
    }

    private func performTableAction(_ action: EditorAction, context: TableContext, row: Int, column: Int) {
        var cells = tableCells(context)
        var alignments = paddedAlignments(context)
        let width = alignments.count
        switch action {
        case .insertTableRowAbove, .insertTableRowBelow:
            let index = action == .insertTableRowAbove ? row : row + 1
            cells.insert(Array(repeating: NSAttributedString(), count: width), at: index)
            rewriteTable(context, cells: cells, alignments: alignments, actionName: "Insert Row", caret: (index, column))
        case .insertTableColumnBefore, .insertTableColumnAfter:
            let index = action == .insertTableColumnBefore ? column : column + 1
            for rowIndex in cells.indices {
                cells[rowIndex].insert(NSAttributedString(), at: min(index, cells[rowIndex].count))
            }
            alignments.insert(.none, at: index)
            rewriteTable(context, cells: cells, alignments: alignments, actionName: "Insert Column", caret: (row, index))
        case .deleteTableRow:
            guard cells.count > 1 else {
                deleteTable(context)
                return
            }
            cells.remove(at: row)
            rewriteTable(context, cells: cells, alignments: alignments, actionName: "Delete Row", caret: (min(row, cells.count - 1), column))
        case .deleteTableColumn:
            guard width > 1 else {
                deleteTable(context)
                return
            }
            for rowIndex in cells.indices where column < cells[rowIndex].count {
                cells[rowIndex].remove(at: column)
            }
            alignments.remove(at: column)
            rewriteTable(context, cells: cells, alignments: alignments, actionName: "Delete Column", caret: (row, min(column, width - 2)))
        case .setTableColumnAlignment(let alignment):
            alignments[column] = alignment
            setTableAlignments(alignments, in: context)
        case .deleteTable:
            deleteTable(context)
        default:
            break
        }
    }

    private func paddedAlignments(_ context: TableContext) -> [TableColumnAlignment] {
        let alignments = context.alignments
        let width = context.columnCount
        return alignments.count >= width ? Array(alignments.prefix(width)) : alignments + Array(repeating: .none, count: width - alignments.count)
    }

    func tableCells(_ context: TableContext) -> [[NSAttributedString]] {
        let width = context.columnCount
        return context.cells.map { row in
            var cells = row.map { textStorage.attributedSubstring(from: $0) }
            if cells.count < width { cells += Array(repeating: NSAttributedString(), count: width - cells.count) }
            return cells
        }
    }

    @discardableResult
    func rewriteTable(
        _ context: TableContext,
        cells rows: [[NSAttributedString]],
        alignments: [TableColumnAlignment],
        actionName: String,
        caret: (row: Int, column: Int)?
    ) -> Bool {
        guard !rows.isEmpty else { return deleteTable(context) }
        let built = NSMutableAttributedString()
        var cellStarts: [[Int]] = []
        for (index, cells) in rows.enumerated() {
            let block = tableRowBlock(context, isHeader: index == 0, alignments: alignments)
            let attributes = typingAttributes(for: block, textLists: context.lists)
            var starts: [Int] = []
            for (column, cell) in cells.enumerated() {
                if column > 0 { built.append(tableSeparator(attributes: attributes)) }
                starts.append(context.range.location + built.length)
                let piece = NSMutableAttributedString(attributedString: cell)
                let full = NSRange(location: 0, length: piece.length)
                if full.length > 0 {
                    piece.addAttribute(.markdownBlock, value: block, range: full)
                    if let style = attributes[.paragraphStyle] { piece.addAttribute(.paragraphStyle, value: style, range: full) }
                    piece.removeAttribute(.markdownTableSeparator, range: full)
                }
                built.append(piece)
            }
            cellStarts.append(starts)
            if index < rows.count - 1 || context.hasTerminator {
                built.append(separator(block: block, textLists: context.lists))
            }
        }
        var selection = NSRange(location: context.range.location, length: 0)
        if let caret, cellStarts.indices.contains(caret.row) {
            let starts = cellStarts[caret.row]
            let column = max(0, min(caret.column, starts.count - 1))
            let length = rows[caret.row][column].length
            selection = NSRange(location: starts[column] + length, length: 0)
        }
        let applied = replace(context.range, with: built, actionName: actionName, selection: selection)
        if applied { applyTypingAttributes(typingAttributes(at: selection.location)) }
        return applied
    }

    private func setTableAlignments(_ alignments: [TableColumnAlignment], in context: TableContext) {
        editAttributes(in: context.range, actionName: "Align Column") { storage in
            for (index, row) in context.rows.enumerated() {
                let block = context.blocks[index]
                let leaf = MarkdownBlock.Leaf.tableRow(group: context.group ?? .mint(), alignments: alignments, isHeader: block.isTableHeader)
                storage.addAttribute(.markdownBlock, value: block.with(leaf: leaf), range: row)
            }
        }
    }

    @discardableResult
    func deleteTable(_ context: TableContext) -> Bool {
        var range = context.range
        if !context.hasTerminator, range.location > 0 {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        return replace(range, with: NSAttributedString(), actionName: "Delete Table", selection: NSRange(location: range.location, length: 0))
    }

    @discardableResult
    func insertTable(rows bodyRows: Int, columns: Int) -> Bool {
        let width = max(1, columns)
        let caret = currentSelection.location
        let alignments = [TableColumnAlignment](repeating: .none, count: width)
        let group = GroupToken.mint()
        let total = textStorage.length
        let replaced: NSRange
        let prefix: NSAttributedString?
        let base: MarkdownBlock
        let lists: [NSTextList]
        let headerIsContinuation: Bool
        var needsTerminator: Bool
        if let context = tableContext(at: caret) {
            base = context.blocks[0]
            lists = context.lists
            headerIsContinuation = base.isListItem
            if context.hasTerminator {
                replaced = NSRange(location: NSMaxRange(context.range), length: 0)
                prefix = separator(block: base.with(leaf: .paragraph), textLists: lists)
                needsTerminator = true
            } else {
                replaced = NSRange(location: context.contentEnd, length: 0)
                prefix = NSAttributedString(attributedString: separator(block: context.blocks[context.blocks.count - 1], textLists: lists))
                needsTerminator = false
            }
        } else {
            let info = paragraphInfo(at: caret)
            base = info.block.with(task: nil)
            lists = info.lists
            if info.isEmpty {
                replaced = info.range
                prefix = nil
                headerIsContinuation = info.block.isContinuation
                needsTerminator = info.hasSeparator
            } else {
                replaced = NSRange(location: NSMaxRange(info.content), length: info.range.length - info.content.length)
                prefix = separator(block: info.block, textLists: lists)
                headerIsContinuation = info.block.isListItem
                needsTerminator = info.hasSeparator
            }
        }
        if NSMaxRange(replaced) >= total, !needsTerminator { needsTerminator = true }
        let built = NSMutableAttributedString()
        if let prefix { built.append(prefix) }
        let headerStart = replaced.location + built.length
        for index in 0...max(0, bodyRows) {
            let block = MarkdownBlock(
                leaf: .tableRow(group: group, alignments: alignments, isHeader: index == 0),
                containers: base.containers,
                isContinuation: index == 0 ? headerIsContinuation : base.isListItem
            )
            built.append(emptyTableRow(columns: width, block: block, textLists: lists))
            if index < bodyRows || needsTerminator {
                built.append(separator(block: block, textLists: lists))
            }
        }
        let applied = replace(replaced, with: built, actionName: "Insert Table", selection: NSRange(location: headerStart, length: 0))
        if applied { applyTypingAttributes(typingAttributes(at: headerStart)) }
        return applied
    }

    public func tableStructure() -> TableStructureModel? {
        guard let context = tableContext(at: currentSelection.location) else { return nil }
        let previews = context.cells.map { row in row.map { previewText(of: $0) } }
        return TableStructureModel(previews: previews, alignments: paddedAlignments(context), tableGroup: context.group)
    }

    private func previewText(of range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var text = ""
        let ns = textStorage.string as NSString
        textStorage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            if let attachment = value as? ProseSourceAttachment {
                text += String(repeating: attachment.markdownSource, count: run.length)
            } else {
                text += ns.substring(with: run)
            }
        }
        return text
    }

    @discardableResult
    public func applyTableStructure(_ model: TableStructureModel) -> Bool {
        guard isEditable else { return false }
        let context = model.tableGroup.flatMap(tableContext(forGroup:)) ?? tableContext(at: currentSelection.location)
        guard let context else { return false }
        let existing = tableCells(context)
        var rows: [[NSAttributedString]] = []
        for row in 0..<model.rowCount {
            rows.append((0..<model.columnCount).map { column in
                guard let source = model.sourceCell(row: row, column: column),
                      existing.indices.contains(source.row), existing[source.row].indices.contains(source.column)
                else { return NSAttributedString() }
                return existing[source.row][source.column]
            })
        }
        return rewriteTable(context, cells: rows, alignments: model.alignments, actionName: "Edit Table", caret: (0, 0))
    }

    func tableContext(forGroup group: GroupToken) -> TableContext? {
        var found: Int?
        textStorage.enumerateAttribute(.markdownBlock, in: NSRange(location: 0, length: textStorage.length)) { value, run, stop in
            if (value as? MarkdownBlock)?.tableGroup == group {
                found = run.location
                stop.pointee = true
            }
        }
        return found.flatMap { tableContext(at: $0) }
    }
}
