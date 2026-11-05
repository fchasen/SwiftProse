import Foundation
import CoreGraphics

extension NSAttributedString.Key {
    package static let markdownTableGeometry = NSAttributedString.Key("swiftprose.tableGeometry")
}

package enum TableMetrics {
    package static let cellPadding = CGSize(width: 8, height: 4)
    package static let minimumColumnWidth: CGFloat = 40
    package static let edgeSpacing: CGFloat = 6
}

package final class TableRowGeometry: NSObject {
    package let columnEdges: [CGFloat]
    package let rowIndex: Int
    package let rowCount: Int

    package init(columnEdges: [CGFloat], rowIndex: Int, rowCount: Int) {
        self.columnEdges = columnEdges
        self.rowIndex = rowIndex
        self.rowCount = rowCount
        super.init()
    }

    package var isFirst: Bool { rowIndex == 0 }
    package var isLast: Bool { rowIndex == rowCount - 1 }

    package override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableRowGeometry else { return false }
        return columnEdges == other.columnEdges && rowIndex == other.rowIndex && rowCount == other.rowCount
    }

    package override var hash: Int {
        var hasher = Hasher()
        hasher.combine(columnEdges)
        hasher.combine(rowIndex)
        hasher.combine(rowCount)
        return hasher.finalize()
    }
}

extension NSAttributedString {
    package func markdownTableRowRanges(at index: Int) -> [NSRange] {
        guard index >= 0, index < length else { return [] }
        let paragraph = markdownParagraphRange(at: index)
        guard let group = markdownBlock(at: paragraph.location)?.tableGroup else { return [] }
        var rows = [paragraph]
        var start = paragraph.location
        while start > 0 {
            let previous = markdownParagraphRange(at: start - 1)
            guard markdownBlock(at: previous.location)?.tableGroup == group else { break }
            rows.insert(previous, at: 0)
            start = previous.location
        }
        var end = NSMaxRange(paragraph)
        while end < length {
            let next = markdownParagraphRange(at: end)
            guard next.length > 0, markdownBlock(at: next.location)?.tableGroup == group else { break }
            rows.append(next)
            end = NSMaxRange(next)
        }
        return rows
    }

    package func markdownTableContentRange(ofRow paragraph: NSRange) -> NSRange {
        let ns = string as NSString
        var content = paragraph
        if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == MarkdownParagraph.separator {
            content.length -= 1
        }
        return content
    }

    package func markdownTableCellRanges(inRow paragraph: NSRange) -> [NSRange] {
        let content = markdownTableContentRange(ofRow: paragraph)
        let ns = string as NSString
        var cells: [NSRange] = []
        var start = content.location
        for index in content.location..<NSMaxRange(content) where ns.character(at: index) == MarkdownTableSeparator.utf16 {
            cells.append(NSRange(location: start, length: index - start))
            start = index + 1
        }
        cells.append(NSRange(location: start, length: NSMaxRange(content) - start))
        return cells
    }
}
