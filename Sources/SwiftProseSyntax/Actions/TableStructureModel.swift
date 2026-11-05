import Foundation

public struct TableStructureModel: Equatable, Sendable {
    public struct Column: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var alignment: TableColumnAlignment
        public let source: Int?

        public init(id: UUID = UUID(), alignment: TableColumnAlignment = .none, source: Int? = nil) {
            self.id = id
            self.alignment = alignment
            self.source = source
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let source: Int?

        public init(id: UUID = UUID(), source: Int? = nil) {
            self.id = id
            self.source = source
        }
    }

    public private(set) var columns: [Column]
    public private(set) var rows: [Row]
    public let previews: [[String]]
    public let tableGroup: GroupToken?

    public init(previews: [[String]], alignments: [TableColumnAlignment], tableGroup: GroupToken? = nil) {
        let width = max(1, alignments.count, previews.map(\.count).max() ?? 0)
        self.previews = previews
        self.tableGroup = tableGroup
        self.columns = (0..<width).map { index in
            Column(alignment: index < alignments.count ? alignments[index] : .none, source: index)
        }
        self.rows = (0..<max(1, previews.count)).map { Row(source: previews.isEmpty ? nil : $0) }
    }

    public init(columns: Int, bodyRows: Int) {
        self.previews = []
        self.tableGroup = nil
        self.columns = (0..<max(1, columns)).map { _ in Column() }
        self.rows = (0...max(0, bodyRows)).map { _ in Row() }
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { columns.count }

    public func preview(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), columns.indices.contains(column),
              let sourceRow = rows[row].source, let sourceColumn = columns[column].source,
              previews.indices.contains(sourceRow), previews[sourceRow].indices.contains(sourceColumn)
        else { return "" }
        return previews[sourceRow][sourceColumn]
    }

    public mutating func insertRow(at index: Int) {
        rows.insert(Row(), at: max(0, min(index, rows.count)))
    }

    public mutating func deleteRow(at index: Int) {
        guard rows.count > 1, rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    public mutating func moveRow(from source: Int, to destination: Int) {
        guard rows.indices.contains(source) else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: max(0, min(destination, rows.count)))
    }

    public mutating func moveRows(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.sorted().filter { rows.indices.contains($0) }.map { rows[$0] }
        guard !moving.isEmpty else { return }
        let before = offsets.filter { $0 < destination }.count
        rows.removeAll { row in moving.contains { $0.id == row.id } }
        rows.insert(contentsOf: moving, at: max(0, min(destination - before, rows.count)))
    }

    public mutating func insertColumn(at index: Int, alignment: TableColumnAlignment = .none) {
        columns.insert(Column(alignment: alignment), at: max(0, min(index, columns.count)))
    }

    public mutating func deleteColumn(at index: Int) {
        guard columns.count > 1, columns.indices.contains(index) else { return }
        columns.remove(at: index)
    }

    public mutating func moveColumn(from source: Int, to destination: Int) {
        guard columns.indices.contains(source) else { return }
        let column = columns.remove(at: source)
        columns.insert(column, at: max(0, min(destination, columns.count)))
    }

    public mutating func setAlignment(_ alignment: TableColumnAlignment, forColumn index: Int) {
        guard columns.indices.contains(index) else { return }
        columns[index].alignment = alignment
    }

    public mutating func setRowCount(_ count: Int) {
        let target = max(1, count)
        while rows.count < target { rows.append(Row()) }
        if rows.count > target { rows.removeLast(rows.count - target) }
    }

    public mutating func setColumnCount(_ count: Int) {
        let target = max(1, count)
        while columns.count < target { columns.append(Column()) }
        if columns.count > target { columns.removeLast(columns.count - target) }
    }

    public var alignments: [TableColumnAlignment] { columns.map(\.alignment) }

    public func sourceCell(row: Int, column: Int) -> (row: Int, column: Int)? {
        guard rows.indices.contains(row), columns.indices.contains(column),
              let sourceRow = rows[row].source, let sourceColumn = columns[column].source else { return nil }
        return (sourceRow, sourceColumn)
    }
}
