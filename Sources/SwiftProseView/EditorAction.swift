import Foundation
import SwiftProseSyntax

public enum EditorAction: Sendable, Equatable {
    case bold
    case italic
    case strikethrough
    case heading(level: Int)
    case unorderedList
    case orderedList
    case taskList
    case blockquote
    case codeSpan
    case codeBlock
    case link(url: String? = nil, label: String? = nil)
    case horizontalRule
    case indent
    case outdent
    case insertTable(rows: Int, columns: Int)
    case insertTableRowAbove
    case insertTableRowBelow
    case insertTableColumnBefore
    case insertTableColumnAfter
    case deleteTableRow
    case deleteTableColumn
    case setTableColumnAlignment(PipeTableAlignment)

    public static let link: EditorAction = .link(url: nil, label: nil)
    public static let insertTable: EditorAction = .insertTable(rows: 2, columns: 3)
}

extension EditorAction {
    public var stableID: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .heading(let level): return "heading:\(level)"
        case .unorderedList: return "unorderedList"
        case .orderedList: return "orderedList"
        case .taskList: return "taskList"
        case .blockquote: return "blockquote"
        case .codeSpan: return "codeSpan"
        case .codeBlock: return "codeBlock"
        case .link: return "link"
        case .horizontalRule: return "horizontalRule"
        case .indent: return "indent"
        case .outdent: return "outdent"
        case .insertTable: return "insertTable"
        case .insertTableRowAbove: return "insertTableRowAbove"
        case .insertTableRowBelow: return "insertTableRowBelow"
        case .insertTableColumnBefore: return "insertTableColumnBefore"
        case .insertTableColumnAfter: return "insertTableColumnAfter"
        case .deleteTableRow: return "deleteTableRow"
        case .deleteTableColumn: return "deleteTableColumn"
        case .setTableColumnAlignment: return "setTableColumnAlignment"
        }
    }
}
