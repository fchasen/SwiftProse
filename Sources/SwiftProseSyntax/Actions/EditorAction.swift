import Foundation

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
    case setTableColumnAlignment(TableColumnAlignment)
    case deleteTable
    case editTableStructure

    public static let link: EditorAction = .link(url: nil, label: nil)

    public static let tableActions: [EditorAction] = [
        .editTableStructure,
        .insertTableRowAbove,
        .insertTableRowBelow,
        .insertTableColumnBefore,
        .insertTableColumnAfter,
        .deleteTableRow,
        .deleteTableColumn,
        .setTableColumnAlignment(.none),
        .setTableColumnAlignment(.left),
        .setTableColumnAlignment(.center),
        .setTableColumnAlignment(.right),
        .deleteTable
    ]
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
        case .insertTable(let rows, let columns): return "insertTable:\(rows)x\(columns)"
        case .insertTableRowAbove: return "insertTableRowAbove"
        case .insertTableRowBelow: return "insertTableRowBelow"
        case .insertTableColumnBefore: return "insertTableColumnBefore"
        case .insertTableColumnAfter: return "insertTableColumnAfter"
        case .deleteTableRow: return "deleteTableRow"
        case .deleteTableColumn: return "deleteTableColumn"
        case .setTableColumnAlignment(let alignment): return "setTableColumnAlignment:\(alignment.rawValue)"
        case .deleteTable: return "deleteTable"
        case .editTableStructure: return "editTableStructure"
        }
    }
}

extension EditorAction {
    package var systemImage: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .heading(let level): return "h\(level).square"
        case .unorderedList: return "list.bullet"
        case .orderedList: return "list.number"
        case .taskList: return "checklist"
        case .blockquote: return "text.quote"
        case .codeSpan: return "chevron.left.slash.chevron.right"
        case .codeBlock: return "curlybraces"
        case .link: return "link"
        case .horizontalRule: return "minus"
        case .indent: return "increase.indent"
        case .outdent: return "decrease.indent"
        case .insertTable: return "tablecells"
        case .insertTableRowAbove: return "arrow.up.to.line"
        case .insertTableRowBelow: return "arrow.down.to.line"
        case .insertTableColumnBefore: return "arrow.left.to.line"
        case .insertTableColumnAfter: return "arrow.right.to.line"
        case .deleteTableRow: return "minus.rectangle"
        case .deleteTableColumn: return "minus.square"
        case .setTableColumnAlignment(let alignment):
            switch alignment {
            case .none: return "text.justify"
            case .left: return "text.alignleft"
            case .center: return "text.aligncenter"
            case .right: return "text.alignright"
            }
        case .deleteTable: return "trash"
        case .editTableStructure: return "tablecells.badge.ellipsis"
        }
    }

    package var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .heading(let level): return "Heading \(level)"
        case .unorderedList: return "Bullet List"
        case .orderedList: return "Numbered List"
        case .taskList: return "Task List"
        case .blockquote: return "Quote"
        case .codeSpan: return "Inline Code"
        case .codeBlock: return "Code Block"
        case .link: return "Link"
        case .horizontalRule: return "Horizontal Rule"
        case .indent: return "Indent"
        case .outdent: return "Outdent"
        case .insertTable: return "Insert Table"
        case .insertTableRowAbove: return "Insert Row Above"
        case .insertTableRowBelow: return "Insert Row Below"
        case .insertTableColumnBefore: return "Insert Column Before"
        case .insertTableColumnAfter: return "Insert Column After"
        case .deleteTableRow: return "Delete Row"
        case .deleteTableColumn: return "Delete Column"
        case .setTableColumnAlignment(let alignment):
            switch alignment {
            case .none: return "Default Alignment"
            case .left: return "Align Left"
            case .center: return "Align Center"
            case .right: return "Align Right"
            }
        case .deleteTable: return "Delete Table"
        case .editTableStructure: return "Edit Table…"
        }
    }

    package var helpText: String {
        switch self {
        case .bold: return "Bold (⌘B)"
        case .italic: return "Italic (⌘I)"
        case .strikethrough: return "Strikethrough"
        case .heading(let level): return "Heading \(level)"
        case .unorderedList: return "Bullet list"
        case .orderedList: return "Numbered list"
        case .taskList: return "Task list"
        case .blockquote: return "Blockquote"
        case .codeSpan: return "Inline code"
        case .codeBlock: return "Code block"
        case .link: return "Link (⌘K)"
        case .horizontalRule: return "Horizontal rule"
        case .indent: return "Indent (⌘])"
        case .outdent: return "Outdent (⌘[)"
        case .insertTable: return "Insert table"
        case .insertTableRowAbove: return "Insert row above"
        case .insertTableRowBelow: return "Insert row below"
        case .insertTableColumnBefore: return "Insert column before"
        case .insertTableColumnAfter: return "Insert column after"
        case .deleteTableRow: return "Delete row"
        case .deleteTableColumn: return "Delete column"
        case .setTableColumnAlignment(let alignment):
            switch alignment {
            case .none: return "Default column alignment"
            case .left: return "Align column left"
            case .center: return "Align column center"
            case .right: return "Align column right"
            }
        case .deleteTable: return "Delete table"
        case .editTableStructure: return "Edit table structure"
        }
    }
}
