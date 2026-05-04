import Foundation

/// Per-column horizontal alignment encoded by the alignment row of a GFM
/// pipe table:
///
/// - `:---` → `.left`
/// - `---:` → `.right`
/// - `:---:` → `.center`
/// - `---` → `.none` (renderer's default; usually left)
public enum PipeTableAlignment: Equatable, Sendable, Hashable {
    case none
    case left
    case right
    case center

    public var alignmentRowToken: String {
        switch self {
        case .none: return "---"
        case .left: return ":---"
        case .right: return "---:"
        case .center: return ":---:"
        }
    }

    public init?(alignmentRowCell: String) {
        let trimmed = alignmentRowCell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let leading = trimmed.first == ":"
        let trailing = trimmed.last == ":"
        // Body must be all `-` (≥ 1 dash).
        let body: Substring = {
            var s = trimmed[...]
            if leading { s = s.dropFirst() }
            if trailing { s = s.dropLast() }
            return s
        }()
        guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
        switch (leading, trailing) {
        case (true, true): self = .center
        case (true, false): self = .left
        case (false, true): self = .right
        case (false, false): self = .none
        }
    }
}

/// Parsed view of a contiguous run of GFM pipe-table source lines. Built on
/// demand by walking `.pipeTable` paragraphs in storage; never persisted —
/// markdown source is the source of truth.
///
/// Layout:
/// - `headerCells` — first source line, split on unescaped `|`
/// - `alignments` — second source line, parsed per column
/// - `bodyRows` — every line after, split per column
/// - `columnCount` — `max(headerCells.count, alignments.count, max(bodyRows.count))`
///   (cells beyond a row's split are treated as empty)
///
/// `lineKinds` records the role of each source line in the original range —
/// `[.header, .alignment, .body, .body, ...]` — so the layout fragment can
/// dispatch per-line decoration without re-parsing.
public struct PipeTableModel: Equatable, Hashable, Sendable {
    public enum LineKind: Equatable, Hashable, Sendable {
        case header
        case alignment
        case body(rowIndex: Int)
    }

    /// Source range (in NSAttributedString or source string) the model was
    /// parsed from — every line covered.
    public let sourceRange: NSRange
    /// One entry per source line covered.
    public let lineRanges: [NSRange]
    public let lineKinds: [LineKind]
    public let headerCells: [String]
    public let alignments: [PipeTableAlignment]
    /// `bodyRows[r][c]` — text of cell `c` in body row `r`, with surrounding
    /// whitespace and outer `|` already stripped.
    public let bodyRows: [[String]]
    public let columnCount: Int

    public init(
        sourceRange: NSRange,
        lineRanges: [NSRange],
        lineKinds: [LineKind],
        headerCells: [String],
        alignments: [PipeTableAlignment],
        bodyRows: [[String]],
        columnCount: Int
    ) {
        self.sourceRange = sourceRange
        self.lineRanges = lineRanges
        self.lineKinds = lineKinds
        self.headerCells = headerCells
        self.alignments = alignments
        self.bodyRows = bodyRows
        self.columnCount = columnCount
    }

    // MARK: - Parsing

    /// Parse a GFM pipe table from a plain source string. The string MUST be
    /// the table's source lines and nothing else (newlines OK; trailing
    /// newline OK). Returns nil for malformed input — missing alignment row,
    /// fewer than 2 source lines, or a non-table-shaped first line.
    public static func parse(source: String, sourceLocation: Int = 0) -> PipeTableModel? {
        let ns = source as NSString
        var lineRanges: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let r = ns.lineRange(for: NSRange(location: cursor, length: 0))
            lineRanges.append(NSRange(location: r.location + sourceLocation, length: r.length))
            if r.length == 0 { break }
            cursor = r.location + r.length
        }
        guard lineRanges.count >= 2 else { return nil }

        // Split each line.
        var lineCells: [[String]] = []
        for r in lineRanges {
            let local = NSRange(location: r.location - sourceLocation, length: r.length)
            let raw = ns.substring(with: local)
            let stripped = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
            lineCells.append(splitPipeRow(stripped))
        }

        // Detect alignment row (line index 1 by GFM convention).
        let alignmentLineIndex = 1
        let alignmentCells = lineCells[alignmentLineIndex]
        let alignments = alignmentCells.compactMap(PipeTableAlignment.init(alignmentRowCell:))
        guard alignments.count == alignmentCells.count, !alignments.isEmpty else { return nil }

        let header = lineCells[0]
        var bodies: [[String]] = []
        var kinds: [LineKind] = []
        var rowIndex = 0
        for (i, _) in lineCells.enumerated() {
            switch i {
            case 0: kinds.append(.header)
            case alignmentLineIndex: kinds.append(.alignment)
            default:
                kinds.append(.body(rowIndex: rowIndex))
                bodies.append(lineCells[i])
                rowIndex += 1
            }
        }

        let columnCount = max(
            header.count,
            alignments.count,
            bodies.map(\.count).max() ?? 0
        )
        let sourceRange = NSRange(
            location: lineRanges.first?.location ?? sourceLocation,
            length: (lineRanges.last?.upperBound ?? sourceLocation) - (lineRanges.first?.location ?? sourceLocation)
        )

        return PipeTableModel(
            sourceRange: sourceRange,
            lineRanges: lineRanges,
            lineKinds: kinds,
            headerCells: header,
            alignments: alignments,
            bodyRows: bodies,
            columnCount: columnCount
        )
    }

    /// Parse the table that contains `location` in `attributed`. Walks
    /// outward from the cursor's paragraph as long as adjacent paragraphs
    /// carry `BlockSpec.Kind.pipeTable`. Returns nil if `location` is not
    /// inside a pipe-table run, or if the collected source doesn't parse.
    public static func parse(at location: Int, in attributed: NSAttributedString) -> PipeTableModel? {
        guard let runRange = pipeTableRunRange(at: location, in: attributed) else { return nil }
        let ns = attributed.string as NSString
        let source = ns.substring(with: runRange)
        return parse(source: source, sourceLocation: runRange.location)
    }

    /// Returns the source range of the contiguous `.pipeTable` paragraph
    /// run containing `location`, or nil if `location` isn't in such a run.
    public static func pipeTableRunRange(at location: Int, in attributed: NSAttributedString) -> NSRange? {
        guard location >= 0, location <= attributed.length else { return nil }
        let probe = min(location, max(0, attributed.length - 1))
        guard probe < attributed.length else { return nil }
        guard let spec = attributed.blockSpec(at: probe), case .pipeTable = spec.kind else { return nil }
        let ns = attributed.string as NSString

        // Walk backward over .pipeTable paragraphs.
        var startLine = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        while startLine.location > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: startLine.location - 1, length: 0))
            guard let prevSpec = attributed.blockSpec(at: prev.location),
                  case .pipeTable = prevSpec.kind else { break }
            startLine = prev
        }
        // Walk forward.
        var endLine = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        while endLine.upperBound < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: endLine.upperBound, length: 0))
            guard let nextSpec = attributed.blockSpec(at: next.location),
                  case .pipeTable = nextSpec.kind else { break }
            endLine = next
        }
        return NSRange(location: startLine.location, length: endLine.upperBound - startLine.location)
    }

    // MARK: - Cell content location

    /// Locate the absolute storage offset of cell `column`'s textual content
    /// within `lineRange`. Used by the click handler to land a cursor inside
    /// the cell's source text when the user taps a rendered table cell.
    /// Skips the leading `|` (if present) and any whitespace padding so the
    /// cursor lands on the first non-blank character.
    public static func cellContentStart(
        in attributed: NSAttributedString,
        lineRange: NSRange,
        column: Int
    ) -> Int? {
        let ns = attributed.string as NSString
        guard lineRange.length > 0,
              lineRange.location >= 0,
              lineRange.location + lineRange.length <= ns.length,
              column >= 0 else { return nil }
        var raw = ns.substring(with: lineRange)
        if raw.hasSuffix("\n") { raw = String(raw.dropLast()) }
        let line = raw as NSString
        guard line.length > 0 else { return nil }
        // Collect unescaped pipe positions.
        var pipes: [Int] = []
        var i = 0
        while i < line.length {
            let c = line.character(at: i)
            if c == 0x5C, i + 1 < line.length, line.character(at: i + 1) == 0x7C {
                i += 2
                continue
            }
            if c == 0x7C { pipes.append(i) }
            i += 1
        }
        guard !pipes.isEmpty else { return nil }
        let hasLeading = line.character(at: 0) == 0x7C
        let cellStart: Int
        let cellEnd: Int
        if hasLeading {
            guard column < pipes.count else { return nil }
            cellStart = pipes[column] + 1
            cellEnd = (column + 1 < pipes.count) ? pipes[column + 1] : line.length
        } else {
            if column == 0 {
                cellStart = 0
                cellEnd = pipes.first ?? line.length
            } else {
                guard column - 1 < pipes.count else { return nil }
                cellStart = pipes[column - 1] + 1
                cellEnd = (column < pipes.count) ? pipes[column] : line.length
            }
        }
        var pos = cellStart
        while pos < cellEnd {
            let c = line.character(at: pos)
            if c == 0x20 || c == 0x09 { pos += 1 } else { break }
        }
        return lineRange.location + pos
    }

    // MARK: - Serialization

    /// Re-emit canonical pipe-table source from this model. Cells get one
    /// space of padding on each side; column widths match the widest cell
    /// per column for visual alignment in raw mode. Alignment row uses the
    /// canonical token from `PipeTableAlignment.alignmentRowToken`.
    public func renderSource() -> String {
        let widths: [Int] = (0..<columnCount).map { col in
            var w = max(3, alignments[safe: col]?.alignmentRowToken.count ?? 3)
            if let h = headerCells[safe: col] { w = max(w, h.count) }
            for row in bodyRows {
                if let cell = row[safe: col] { w = max(w, cell.count) }
            }
            return w
        }
        var out: [String] = []
        out.append(renderRow(cells: headerCells, widths: widths))
        out.append(renderAlignmentRow(widths: widths))
        for row in bodyRows {
            out.append(renderRow(cells: row, widths: widths))
        }
        return out.joined(separator: "\n") + "\n"
    }

    private func renderRow(cells: [String], widths: [Int]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(columnCount)
        for col in 0..<columnCount {
            let raw = cells[safe: col] ?? ""
            let padded = raw.padding(toLength: widths[col], withPad: " ", startingAt: 0)
            parts.append(" \(padded) ")
        }
        return "|" + parts.joined(separator: "|") + "|"
    }

    private func renderAlignmentRow(widths: [Int]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(columnCount)
        for col in 0..<columnCount {
            let alignment = alignments[safe: col] ?? .none
            let dashes = max(3, widths[col])
            switch alignment {
            case .none:
                parts.append(" " + String(repeating: "-", count: dashes) + " ")
            case .left:
                parts.append(":" + String(repeating: "-", count: dashes - 1) + " ")
            case .right:
                parts.append(" " + String(repeating: "-", count: dashes - 1) + ":")
            case .center:
                parts.append(":" + String(repeating: "-", count: dashes - 2) + ":")
            }
        }
        return "|" + parts.joined(separator: "|") + "|"
    }

    // MARK: - Mutations (return new model; caller re-emits source)

    public func insertingRow(after rowIndex: Int) -> PipeTableModel {
        var rows = bodyRows
        let insertAt = min(max(0, rowIndex + 1), rows.count)
        let blank = Array(repeating: "", count: columnCount)
        rows.insert(blank, at: insertAt)
        return rebuilt(headerCells: headerCells, alignments: alignments, bodyRows: rows)
    }

    public func deletingRow(at rowIndex: Int) -> PipeTableModel {
        guard bodyRows.indices.contains(rowIndex) else { return self }
        var rows = bodyRows
        rows.remove(at: rowIndex)
        return rebuilt(headerCells: headerCells, alignments: alignments, bodyRows: rows)
    }

    public func insertingColumn(after columnIndex: Int) -> PipeTableModel {
        let insertAt = min(max(0, columnIndex + 1), columnCount)
        var newHeader = headerCells
        var newAligns = alignments
        var newBodies = bodyRows
        // Pad to columnCount first, then insert.
        newHeader = pad(newHeader, to: columnCount)
        newAligns = pad(newAligns, to: columnCount, with: .none)
        newBodies = newBodies.map { pad($0, to: columnCount) }
        newHeader.insert("", at: insertAt)
        newAligns.insert(.none, at: insertAt)
        newBodies = newBodies.map { var r = $0; r.insert("", at: insertAt); return r }
        return rebuilt(headerCells: newHeader, alignments: newAligns, bodyRows: newBodies)
    }

    public func deletingColumn(at columnIndex: Int) -> PipeTableModel {
        guard (0..<columnCount).contains(columnIndex) else { return self }
        var newHeader = pad(headerCells, to: columnCount)
        var newAligns = pad(alignments, to: columnCount, with: .none)
        var newBodies = bodyRows.map { pad($0, to: columnCount) }
        newHeader.remove(at: columnIndex)
        newAligns.remove(at: columnIndex)
        newBodies = newBodies.map { var r = $0; r.remove(at: columnIndex); return r }
        return rebuilt(headerCells: newHeader, alignments: newAligns, bodyRows: newBodies)
    }

    public func settingAlignment(_ alignment: PipeTableAlignment, forColumn columnIndex: Int) -> PipeTableModel {
        guard (0..<columnCount).contains(columnIndex) else { return self }
        var newAligns = pad(alignments, to: columnCount, with: .none)
        newAligns[columnIndex] = alignment
        return rebuilt(headerCells: headerCells, alignments: newAligns, bodyRows: bodyRows)
    }

    public func settingCellText(_ text: String, row: Int, column: Int) -> PipeTableModel {
        let cleaned = text.replacingOccurrences(of: "|", with: "\\|")
                          .replacingOccurrences(of: "\n", with: " ")
        switch row {
        case -1:
            // Header row.
            var newHeader = pad(headerCells, to: columnCount)
            guard newHeader.indices.contains(column) else { return self }
            newHeader[column] = cleaned
            return rebuilt(headerCells: newHeader, alignments: alignments, bodyRows: bodyRows)
        default:
            guard bodyRows.indices.contains(row) else { return self }
            var newBodies = bodyRows.map { pad($0, to: columnCount) }
            guard newBodies[row].indices.contains(column) else { return self }
            newBodies[row][column] = cleaned
            return rebuilt(headerCells: headerCells, alignments: alignments, bodyRows: newBodies)
        }
    }

    /// Build a fresh stub model — the table inserted by the format-menu
    /// "Insert Table" command. Header cells are blank, all columns left-
    /// aligned, `bodyRowCount` blank body rows.
    public static func stub(columnCount: Int, bodyRowCount: Int) -> PipeTableModel {
        let cols = max(1, columnCount)
        let bodyCount = max(0, bodyRowCount)
        let header = Array(repeating: "", count: cols)
        let aligns = Array(repeating: PipeTableAlignment.none, count: cols)
        let bodies: [[String]] = Array(repeating: Array(repeating: "", count: cols), count: bodyCount)
        // Rendered ranges are placeholders — caller writes the source then
        // re-parses to get the real ranges.
        let placeholder = NSRange(location: 0, length: 0)
        let lineCount = 2 + bodyCount
        let lineRanges = Array(repeating: placeholder, count: lineCount)
        var kinds: [LineKind] = [.header, .alignment]
        for r in 0..<bodyCount { kinds.append(.body(rowIndex: r)) }
        return PipeTableModel(
            sourceRange: placeholder,
            lineRanges: lineRanges,
            lineKinds: kinds,
            headerCells: header,
            alignments: aligns,
            bodyRows: bodies,
            columnCount: cols
        )
    }

    private func rebuilt(
        headerCells: [String],
        alignments: [PipeTableAlignment],
        bodyRows: [[String]]
    ) -> PipeTableModel {
        let cols = max(headerCells.count, alignments.count, bodyRows.map(\.count).max() ?? 0)
        var kinds: [LineKind] = [.header, .alignment]
        for r in 0..<bodyRows.count { kinds.append(.body(rowIndex: r)) }
        // Ranges become invalid after mutation; caller is expected to
        // renderSource() and re-parse if needed. We keep the original
        // sourceRange so the caller can locate the table in storage.
        return PipeTableModel(
            sourceRange: sourceRange,
            lineRanges: [],
            lineKinds: kinds,
            headerCells: headerCells,
            alignments: alignments,
            bodyRows: bodyRows,
            columnCount: cols
        )
    }

    private func pad<T>(_ array: [T], to count: Int, with filler: T) -> [T] {
        if array.count >= count { return array }
        return array + Array(repeating: filler, count: count - array.count)
    }

    private func pad(_ array: [String], to count: Int) -> [String] {
        pad(array, to: count, with: "")
    }
}

// MARK: - Cell splitting

/// Split a single GFM pipe-table source line into its cells. Honors `\|`
/// escaping. Discards the leading and trailing `|` if present (per GFM
/// convention; both forms `|a|b|` and `a|b` are valid).
func splitPipeRow(_ line: String) -> [String] {
    let chars = Array(line)
    var cells: [String] = []
    var current = ""
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\\", i + 1 < chars.count, chars[i + 1] == "|" {
            current.append("|")
            i += 2
            continue
        }
        if c == "|" {
            cells.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            i += 1
            continue
        }
        current.append(c)
        i += 1
    }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    // Strip leading / trailing empty cells produced by a leading or
    // trailing `|` so `|a|b|` parses to ["a","b"], not ["","a","b",""].
    if cells.first == "" { cells.removeFirst() }
    if cells.last == "" { cells.removeLast() }
    return cells
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension NSRange {
    var upperBound: Int { location + length }
}
