import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct TableContext {
    let rows: [NSRange]
    let cells: [[NSRange]]
    let blocks: [MarkdownBlock]
    let lists: [NSTextList]

    var group: GroupToken? { blocks.first?.tableGroup }
    var alignments: [TableColumnAlignment] { blocks.first?.tableAlignments ?? [] }
    var columnCount: Int { max(1, alignments.count, cells.map(\.count).max() ?? 0) }
    var range: NSRange { NSUnionRange(rows[0], rows[rows.count - 1]) }
    var contentEnd: Int { NSMaxRange(cells[cells.count - 1].last ?? rows[rows.count - 1]) }
    var hasTerminator: Bool { NSMaxRange(range) > contentEnd }

    func position(of location: Int) -> (row: Int, column: Int)? {
        for (row, cells) in cells.enumerated() {
            guard let first = cells.first, let last = cells.last,
                  location >= first.location, location <= NSMaxRange(last) else { continue }
            for (column, cell) in cells.enumerated() where location <= NSMaxRange(cell) {
                return (row, column)
            }
        }
        return nil
    }

    func cell(row: Int, column: Int) -> NSRange {
        let rowCells = cells[row]
        return rowCells[min(column, rowCells.count - 1)]
    }

    func isRowEmpty(_ row: Int) -> Bool {
        cells[row].allSatisfy { $0.length == 0 }
    }
}

extension EditorController {
    func tableContext(at location: Int) -> TableContext? {
        let total = textStorage.length
        guard total > 0 else { return nil }
        var probe = min(location, total - 1)
        if location == total {
            let ns = textStorage.string as NSString
            guard ns.character(at: total - 1) != MarkdownParagraph.separator else { return nil }
            probe = total - 1
        }
        let rows = textStorage.markdownTableRowRanges(at: probe)
        guard !rows.isEmpty else { return nil }
        let blocks = rows.map { textStorage.markdownBlock(at: $0.location) ?? .paragraph }
        return TableContext(
            rows: rows,
            cells: rows.map { textStorage.markdownTableCellRanges(inRow: $0) },
            blocks: blocks,
            lists: Self.textLists(in: textStorage, at: rows[0].location)
        )
    }

    var isSelectionInTable: Bool {
        let location = currentSelection.location
        let total = textStorage.length
        guard total > 0 else { return false }
        if location == total {
            let ns = textStorage.string as NSString
            guard ns.character(at: total - 1) != MarkdownParagraph.separator else { return false }
            return textStorage.markdownBlock(at: total - 1)?.isTableRow == true
        }
        return textStorage.markdownBlock(at: textStorage.markdownParagraphRange(at: location).location)?.isTableRow == true
    }

    func selectTableCell(_ range: NSRange) {
        setSelection(range)
        applyTypingAttributes(typingAttributes(at: range.location))
    }

    func tableRowBlock(_ context: TableContext, isHeader: Bool, alignments: [TableColumnAlignment]? = nil) -> MarkdownBlock {
        let base = context.blocks[0]
        let group = context.group ?? .mint()
        return MarkdownBlock(
            leaf: .tableRow(group: group, alignments: alignments ?? context.alignments, isHeader: isHeader),
            containers: base.containers,
            isContinuation: isHeader ? base.isContinuation : base.isListItem,
            task: nil
        )
    }

    func emptyTableRow(columns: Int, block: MarkdownBlock, textLists: [NSTextList]) -> NSMutableAttributedString {
        let attributes = typingAttributes(for: block, textLists: textLists)
        let row = NSMutableAttributedString()
        for _ in 0..<max(0, columns - 1) {
            row.append(tableSeparator(attributes: attributes))
        }
        return row
    }

    func tableSeparator(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var separator = attributes
        separator[.markdownTableSeparator] = true
        separator.markdownInlineIntent = []
        separator.removeValue(forKey: .link)
        return NSAttributedString(string: MarkdownTableSeparator.string, attributes: separator)
    }

    func handleTableTab(backward: Bool) -> Bool? {
        let selection = currentSelection
        guard let context = tableContext(at: selection.location),
              let position = context.position(of: selection.location) else { return nil }
        if backward {
            if position.column > 0 {
                selectTableCell(context.cell(row: position.row, column: position.column - 1))
            } else if position.row > 0 {
                selectTableCell(context.cells[position.row - 1].last ?? context.cell(row: position.row - 1, column: 0))
            }
            return true
        }
        if position.column + 1 < context.cells[position.row].count {
            selectTableCell(context.cell(row: position.row, column: position.column + 1))
        } else if position.row + 1 < context.rows.count {
            selectTableCell(context.cell(row: position.row + 1, column: 0))
        } else {
            appendTableRow(context, caretColumn: 0)
        }
        return true
    }

    func handleTableNewline() -> Bool? {
        let selection = currentSelection
        guard let context = tableContext(at: selection.location),
              let position = context.position(of: selection.location) else { return nil }
        if position.row + 1 < context.rows.count {
            let target = context.cell(row: position.row + 1, column: position.column)
            selectTableCell(NSRange(location: NSMaxRange(target), length: 0))
            return true
        }
        if position.row > 0, context.isRowEmpty(position.row), selection.length == 0 {
            return exitTable(context, replacingRow: position.row)
        }
        appendTableRow(context, caretColumn: position.column)
        return true
    }

    @discardableResult
    func appendTableRow(_ context: TableContext, caretColumn: Int) -> Bool {
        let last = context.rows.count - 1
        let block = tableRowBlock(context, isHeader: false)
        let replaced = NSRange(location: context.contentEnd, length: NSMaxRange(context.range) - context.contentEnd)
        let replacement = NSMutableAttributedString(attributedString: separator(block: context.blocks[last], textLists: context.lists))
        let row = emptyTableRow(columns: context.columnCount, block: block, textLists: context.lists)
        replacement.append(row)
        if context.hasTerminator {
            replacement.append(separator(block: block, textLists: context.lists))
        }
        let rowStart = context.contentEnd + 1
        let caret = rowStart + min(max(0, caretColumn), context.columnCount - 1)
        let applied = replace(replaced, with: replacement, actionName: "Add Row", selection: NSRange(location: caret, length: 0))
        if applied { applyTypingAttributes(typingAttributes(for: block, textLists: context.lists)) }
        return applied
    }

    private func exitTable(_ context: TableContext, replacingRow row: Int) -> Bool {
        let paragraph = context.rows[row]
        let content = textStorage.markdownTableContentRange(ofRow: paragraph)
        let block = context.blocks[row].with(leaf: .paragraph)
        let attributes = paragraphAttributes(for: block, textLists: context.lists)
        let hasTerminator = NSMaxRange(paragraph) > NSMaxRange(content)
        let replacement = hasTerminator ? NSAttributedString(string: "\n", attributes: attributes) : NSAttributedString()
        let target = hasTerminator ? paragraph : content
        let applied = replace(target, with: replacement, actionName: "Exit Table", selection: NSRange(location: paragraph.location, length: 0))
        if applied { applyTypingAttributes(typingAttributes(for: block, textLists: context.lists)) }
        return applied
    }

    func handleTableBackspace(at caret: Int) -> Bool? {
        if let context = tableContext(at: caret), let position = context.position(of: caret) {
            let cell = context.cell(row: position.row, column: position.column)
            guard caret == cell.location else { return nil }
            if position.column > 0 || position.row > 0 {
                setSelection(NSRange(location: caret - 1, length: 0))
                applyTypingAttributes(typingAttributes(at: caret - 1))
                return true
            }
            let tableStart = context.rows[0].location
            guard tableStart > 0 else { return true }
            let previous = paragraphInfo(at: tableStart - 1)
            if previous.isEmpty, !previous.block.isTableRow {
                return replace(
                    previous.range,
                    with: NSAttributedString(),
                    actionName: "Delete",
                    selection: NSRange(location: previous.range.location, length: 0)
                )
            }
            setSelection(NSRange(location: NSMaxRange(previous.content), length: 0))
            return true
        }
        let info = paragraphInfo(at: caret)
        guard caret == info.content.location, info.range.location > 0,
              let context = tableContext(at: info.range.location - 1) else { return nil }
        let end = context.contentEnd
        if info.isTrailingEmpty {
            return replace(
                NSRange(location: end, length: 1),
                with: NSAttributedString(),
                actionName: "Delete",
                selection: NSRange(location: end, length: 0)
            )
        }
        if info.isEmpty {
            return replace(info.range, with: NSAttributedString(), actionName: "Delete", selection: NSRange(location: end, length: 0))
        }
        setSelection(NSRange(location: end, length: 0))
        return true
    }

    func handleForwardDelete() -> Bool {
        guard canApplyKeyRules else { return false }
        let selection = currentSelection
        guard selection.length == 0 else { return false }
        return handleTableForwardDelete(at: selection.location) ?? false
    }

    func handleTableForwardDelete(at caret: Int) -> Bool? {
        if let context = tableContext(at: caret), let position = context.position(of: caret) {
            let cell = context.cell(row: position.row, column: position.column)
            guard caret == NSMaxRange(cell) else { return nil }
            let lastColumn = position.column == context.cells[position.row].count - 1
            if !lastColumn || position.row + 1 < context.rows.count {
                setSelection(NSRange(location: caret + 1, length: 0))
                applyTypingAttributes(typingAttributes(at: caret + 1))
                return true
            }
            guard context.hasTerminator, NSMaxRange(context.range) < textStorage.length else { return true }
            let next = paragraphInfo(at: NSMaxRange(context.range))
            if next.isEmpty, next.hasSeparator {
                return replace(next.range, with: NSAttributedString(), actionName: "Delete", selection: NSRange(location: caret, length: 0))
            }
            setSelection(NSRange(location: next.content.location, length: 0))
            return true
        }
        let info = paragraphInfo(at: caret)
        guard !info.isTrailingEmpty, caret == NSMaxRange(info.content), info.hasSeparator,
              NSMaxRange(info.range) < textStorage.length,
              let context = tableContext(at: NSMaxRange(info.range)) else { return nil }
        if info.isEmpty {
            return replace(info.range, with: NSAttributedString(), actionName: "Delete", selection: NSRange(location: info.range.location, length: 0))
        }
        selectTableCell(NSRange(location: context.cells[0][0].location, length: 0))
        return true
    }

    static func sanitizedCellText(_ text: String) -> String {
        let breaks: Set<Character> = ["\n", "\r", "\r\n", "\t", "\u{2028}", "\u{2029}", "\u{85}"]
        guard text.contains(where: { breaks.contains($0) }) else { return text }
        if text.allSatisfy({ breaks.contains($0) && $0 != "\t" }) { return "" }
        return String(text.map { breaks.contains($0) ? " " : $0 })
    }

    func editTouchesTable(_ target: NSRange) -> Bool {
        isInTableRowContent(target.location)
            || (target.length > 0 && (isInTableRowContent(NSMaxRange(target)) || containsTableRow(in: target)))
    }

    func isInTableRowContent(_ location: Int) -> Bool {
        guard let context = tableContext(at: location) else { return false }
        return context.position(of: location) != nil
    }

    func protectedTableCharacters(in range: NSRange) -> (protected: IndexSet, wholeTables: [TableContext]) {
        let total = textStorage.length
        let target = Normalizer.clamp(range, to: total)
        var protected = IndexSet()
        var wholeTables: [TableContext] = []
        guard target.length > 0 else { return (protected, wholeTables) }
        let ns = textStorage.string as NSString
        var location = target.location
        while location < NSMaxRange(target) {
            if let context = tableContext(at: location), location < NSMaxRange(context.range) {
                let covered = target.location <= context.range.location && NSMaxRange(target) >= context.contentEnd
                if covered {
                    wholeTables.append(context)
                } else {
                    for row in context.rows {
                        let content = textStorage.markdownTableContentRange(ofRow: row)
                        for index in content.location..<NSMaxRange(content) where ns.character(at: index) == MarkdownTableSeparator.utf16 {
                            protected.insert(index)
                        }
                        if NSMaxRange(row) > NSMaxRange(content), NSMaxRange(row) < total || row != context.rows.last {
                            protected.insert(NSMaxRange(content))
                        }
                    }
                    if context.range.location > 0, context.range.location > target.location {
                        protected.insert(context.range.location - 1)
                    }
                }
                location = NSMaxRange(context.range)
                continue
            }
            let paragraph = textStorage.markdownParagraphRange(at: location)
            location = max(location + 1, NSMaxRange(paragraph))
        }
        return (protected, wholeTables)
    }

    func applyTableEdit(range: NSRange, replacement: String?) -> Bool {
        guard canApplyKeyRules, let replacement else { return false }
        let total = textStorage.length
        let target = Normalizer.clamp(range, to: total)
        if target.length == 0, !replacement.isEmpty, let block = trailingBlockAfterTable(at: target.location) {
            var attributes = typingAttributes(for: block, textLists: Self.textLists(in: textStorage, at: total - 1))
            attributes.markdownInlineIntent = adjustedTypingAttributes(hostTypingAttributes).markdownInlineIntent.intersection(.markdownMarks)
            let inserted = NSAttributedString(string: replacement, attributes: attributes)
            replace(target, with: inserted, actionName: "Typing", selection: NSRange(location: total + inserted.length, length: 0))
            return true
        }
        if target.length == 0 {
            guard isInTableRowContent(target.location) else { return false }
            let sanitized = Self.sanitizedCellText(replacement)
            guard sanitized != replacement else { return false }
            guard !sanitized.isEmpty else { return true }
            insertCellText(sanitized, at: target)
            return true
        }
        let touchesTable = tableContext(at: target.location) != nil
            || tableContext(at: max(0, NSMaxRange(target) - 1)) != nil
            || (NSMaxRange(target) < total && tableContext(at: NSMaxRange(target)) != nil
                && textStorage.markdownParagraphRange(at: NSMaxRange(target)).location == NSMaxRange(target))
            || containsTableRow(in: target)
        guard touchesTable else { return false }
        let (protected, wholeTables) = protectedTableCharacters(in: target)
        if protected.isEmpty, wholeTables.isEmpty {
            guard isInTableRowContent(target.location) else { return false }
            let sanitized = Self.sanitizedCellText(replacement)
            guard sanitized != replacement else { return false }
            insertCellText(sanitized, at: target)
            return true
        }
        let selection = currentSelection
        if target.length == 1, replacement.isEmpty, wholeTables.isEmpty, selection.length == 0 {
            if selection.location == target.location {
                _ = handleTableForwardDelete(at: target.location)
                return true
            }
            if selection.location == NSMaxRange(target) {
                if handleTableBackspace(at: selection.location) == nil {
                    setSelection(NSRange(location: target.location, length: 0))
                }
                return true
            }
        }
        replaceRespectingTables(target, protected: protected, wholeTables: wholeTables, with: replacement, actionName: replacement.isEmpty ? "Delete" : "Typing")
        return true
    }

    private func trailingBlockAfterTable(at location: Int) -> MarkdownBlock? {
        let total = textStorage.length
        guard location == total, total > 0,
              (textStorage.string as NSString).character(at: total - 1) == MarkdownParagraph.separator,
              let block = textStorage.markdownBlock(at: total - 1), block.isTableRow else { return nil }
        return block.with(leaf: .paragraph)
    }

    func containsTableRow(in range: NSRange) -> Bool {
        var found = false
        textStorage.enumerateAttribute(.markdownBlock, in: range) { value, _, stop in
            if (value as? MarkdownBlock)?.isTableRow == true {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func insertCellText(_ text: String, at target: NSRange) {
        var attributes = typingAttributes(at: target.location)
        let carried = adjustedTypingAttributes(hostTypingAttributes)
        attributes.markdownInlineIntent = carried.markdownInlineIntent.intersection(.markdownMarks)
        if let link = carried[.link] { attributes[.link] = link }
        let inserted = NSAttributedString(string: text, attributes: attributes)
        replace(
            target,
            with: inserted,
            actionName: "Typing",
            selection: NSRange(location: target.location + inserted.length, length: 0)
        )
    }

    func replaceRespectingTables(_ target: NSRange, with fragment: NSAttributedString, actionName: String) -> Bool {
        let (protected, wholeTables) = protectedTableCharacters(in: target)
        return replaceRespectingTables(target, protected: protected, wholeTables: wholeTables, fragment: fragment, actionName: actionName)
    }

    @discardableResult
    private func replaceRespectingTables(
        _ target: NSRange,
        protected: IndexSet,
        wholeTables: [TableContext],
        with replacement: String,
        actionName: String
    ) -> Bool {
        let attributes = adjustedTypingAttributes(typingAttributes(at: target.location))
        let fragment = NSAttributedString(string: replacement, attributes: attributes)
        return replaceRespectingTables(target, protected: protected, wholeTables: wholeTables, fragment: fragment, actionName: actionName)
    }

    private func replaceRespectingTables(
        _ target: NSRange,
        protected: IndexSet,
        wholeTables: [TableContext],
        fragment: NSAttributedString,
        actionName: String
    ) -> Bool {
        let total = textStorage.length
        var deletable = IndexSet(integersIn: target.location..<NSMaxRange(target))
        deletable.subtract(protected)
        var reblock: [(location: Int, block: MarkdownBlock, lists: [NSTextList])] = []
        for table in wholeTables where table.hasTerminator {
            if fragment.length == 0 {
                deletable.insert(table.contentEnd)
                if NSMaxRange(table.range) >= total, table.range.location > 0 {
                    deletable.insert(table.range.location - 1)
                }
            } else {
                deletable.remove(table.contentEnd)
                reblock.append((table.contentEnd, table.blocks[0].with(leaf: .paragraph), table.lists))
            }
        }
        let pieces = deletable.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
        let insertion = pieces.first?.location ?? target.location
        let cellInsertion = isInTableRowContent(insertion) && !wholeTables.contains { NSLocationInRange(insertion, $0.range) }
        let inserted = cellInsertion ? flattenedForCell(fragment, at: insertion) : NSMutableAttributedString(attributedString: fragment)
        if !cellInsertion, let plain = reblock.first, inserted.length > 0 {
            let full = NSRange(location: 0, length: inserted.length)
            inserted.addAttribute(.markdownBlock, value: plain.block, range: full)
            inserted.addAttribute(.paragraphStyle, value: restyler.paragraphStyle(for: plain.block, textLists: plain.lists), range: full)
        }
        let union = pieces.reduce(target) { NSUnionRange($0, $1) }
        let scratch = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: union))
        for entry in reblock where NSLocationInRange(entry.location, union) {
            let local = NSRange(location: entry.location - union.location, length: 1)
            scratch.addAttribute(.markdownBlock, value: entry.block, range: local)
            scratch.addAttribute(.paragraphStyle, value: restyler.paragraphStyle(for: entry.block, textLists: entry.lists), range: local)
        }
        for piece in pieces.reversed() {
            scratch.deleteCharacters(in: NSRange(location: piece.location - union.location, length: piece.length))
        }
        var removedBefore = 0
        for piece in pieces where piece.location < insertion { removedBefore += piece.length }
        let localInsertion = insertion - removedBefore - union.location
        scratch.insert(inserted, at: max(0, min(localInsertion, scratch.length)))
        let caret = insertion - removedBefore + inserted.length
        let applied = replace(union, with: scratch, actionName: actionName, selection: NSRange(location: caret, length: 0))
        if applied, caret <= textStorage.length {
            applyTypingAttributes(typingAttributes(at: caret))
        }
        return applied
    }

    func flattenedForCell(_ fragment: NSAttributedString, at location: Int) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(attributedString: fragment)
        Self.trimTrailingSeparators(result)
        let ns = result.string as NSString
        for index in stride(from: ns.length - 1, through: 0, by: -1) {
            let unit = ns.character(at: index)
            if unit == MarkdownParagraph.separator || unit == MarkdownBreak.utf16 || unit == MarkdownTableSeparator.utf16
                || unit == 0x0D || unit == 0x2029 || unit == 0x85 {
                result.replaceCharacters(in: NSRange(location: index, length: 1), with: " ")
            }
        }
        let full = NSRange(location: 0, length: result.length)
        guard full.length > 0 else { return result }
        let paragraph = textStorage.markdownParagraphRange(at: location)
        let block = textStorage.markdownBlock(at: paragraph.location) ?? .paragraph
        let style = textStorage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
        result.addAttribute(.markdownBlock, value: block, range: full)
        if let style { result.addAttribute(.paragraphStyle, value: style, range: full) }
        result.removeAttribute(.markdownTableSeparator, range: full)
        return result
    }

    func scheduleTableRepairIfNeeded(in range: NSRange) {
        guard !Normalizer.tableRepairs(in: textStorage, range: Normalizer.affectedRange(for: range, in: textStorage)).isEmpty else { return }
        deferEdit { [weak self] in
            self?.repairTables()
        }
    }

    @discardableResult
    func repairTables() -> Bool {
        guard !hostHasMarkedText, !isSettingMarkedText, !isWritingToolsActive else { return false }
        let repairs = Normalizer.tableRepairs(in: textStorage, range: NSRange(location: 0, length: textStorage.length))
        guard let first = repairs.first else { return false }
        let union = repairs.dropFirst().reduce(first.range) { NSUnionRange($0, $1.range) }
        let selection = currentSelection
        var shift = 0
        for repair in repairs where NSMaxRange(repair.range) <= selection.location {
            shift += (repair.replacement as NSString).length - repair.range.length
        }
        let scratch = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: union))
        for repair in repairs.sorted(by: { $0.range.location > $1.range.location }) {
            let local = NSRange(location: repair.range.location - union.location, length: repair.range.length)
            let anchor = repair.range.length > 0 ? repair.range.location : max(0, repair.range.location - 1)
            var attributes = textStorage.attributes(at: min(anchor, textStorage.length - 1), effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .markdownLiteral)
            if repair.replacement.first == MarkdownTableSeparator.character {
                attributes[.markdownTableSeparator] = true
                attributes.markdownInlineIntent = []
                attributes.removeValue(forKey: .link)
            } else {
                attributes.removeValue(forKey: .markdownTableSeparator)
            }
            scratch.replaceCharacters(in: local, with: NSAttributedString(string: repair.replacement, attributes: attributes))
        }
        return replace(
            union,
            with: scratch,
            actionName: "",
            selection: NSRange(location: max(0, selection.location + shift), length: selection.length),
            ignoringEditability: true
        )
    }
}
