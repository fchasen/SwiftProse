import Foundation

public struct MarkdownWriter: DocumentWriter {
    public init() {}

    public func write(_ document: EditorDocument) -> String {
        var output = LineOutput()
        output.write(document.blocks, context: .top)
        return output.text
    }

    public func markdown(from storage: NSAttributedString) -> String {
        write(StorageReader().document(from: storage))
    }

    public func markdown(from storage: NSAttributedString, range: NSRange) -> String {
        write(StorageReader().document(from: storage, range: range))
    }

    static func thematicBreak(source: String, itemBullet: Character?) -> String {
        let fallback = itemBullet == "-" ? "***" : "---"
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        let marks = trimmed.filter { $0 != " " && $0 != "\t" }
        guard let mark = marks.first, "-*_".contains(mark), marks.count >= 3,
              marks.allSatisfy({ $0 == mark }), !trimmed.contains("\n") else {
            return fallback
        }
        return mark == itemBullet ? fallback : trimmed
    }

    static func longestRun(of character: Character, in text: String) -> Int {
        guard let target = character.asciiValue else { return 0 }
        var longest = 0
        var current = 0
        for byte in text.utf8 {
            if byte == target {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

private struct LineOutput {
    enum Context {
        case top
        case quote
        case item
    }

    private enum Prefix {
        case quote
        case item(head: String, indent: String, isFirstLine: Bool)

        var fillsEmptyLine: Bool {
            switch self {
            case .quote: return true
            case .item(_, _, let isFirstLine): return isFirstLine
            }
        }
    }

    private(set) var text = ""
    private var prefixes: [Prefix] = []
    private var itemBullet: Character = "-"
    private var lineCount = 0

    mutating func write(_ blocks: [EditorDocument.Block], context: Context) {
        var previous: EditorDocument.Block?
        var usesAlternateMarker = false
        for block in blocks {
            let firstBullet: Character? = context == .item && previous == nil ? itemBullet : nil
            switch block {
            case .paragraph(let runs):
                let rendered = InlineSerializer.serialize(runs, inHeading: false)
                guard !rendered.isEmpty else { continue }
                separate(block, after: previous, context: context)
                lines(Self.protectingLeadingIndent(rendered))
            case .list(let list):
                guard !list.items.isEmpty else { continue }
                separate(block, after: previous, context: context)
                if case .list(let prior)? = previous, prior.kind.isOrdered == list.kind.isOrdered {
                    if list.separatesFromPrevious { usesAlternateMarker.toggle() }
                } else {
                    usesAlternateMarker = false
                }
                write(list, alternateMarker: usesAlternateMarker)
            case .heading(let level, let runs):
                separate(block, after: previous, context: context)
                let marker = String(repeating: "#", count: max(1, min(6, level)))
                let rendered = InlineSerializer.serialize(runs, inHeading: true)
                line(rendered.isEmpty ? marker : marker + " " + rendered)
            case .code(let code):
                separate(block, after: previous, context: context)
                if Self.writesIndented(code, after: previous, context: context) {
                    for body in code.lines { line(body.isEmpty ? body : "    " + body) }
                } else {
                    write(code)
                }
            case .thematicBreak:
                separate(block, after: previous, context: context)
                line(MarkdownWriter.thematicBreak(source: "---", itemBullet: firstBullet))
            case .atom(let atom):
                separate(block, after: previous, context: context)
                if atom.kind == AtomKind.thematicBreak {
                    line(MarkdownWriter.thematicBreak(source: atom.source, itemBullet: firstBullet))
                } else {
                    lines(atom.source)
                }
            case .table(let table):
                separate(block, after: previous, context: context)
                for row in TableSerializer.lines(table) { line(row) }
            case .quote(let inner):
                separate(block, after: previous, context: context)
                let start = lineCount
                prefixes.append(.quote)
                write(inner, context: .quote)
                prefixes.removeLast()
                if lineCount == start { line(">") }
            }
            previous = block
        }
    }

    private mutating func separate(_ block: EditorDocument.Block, after previous: EditorDocument.Block?, context: Context) {
        guard let previous else { return }
        guard context == .item, !Self.needsBlankLine(after: previous, before: block) else {
            line("")
            return
        }
        let needsBlankLine: Bool
        switch block {
        case .list(let list):
            var startsAtOne = true
            if case .ordered(let start) = list.kind { startsAtOne = start == 1 }
            needsBlankLine = !startsAtOne || Self.rendersNothing(list.items[0].blocks)
        case .code(let code):
            needsBlankLine = Self.writesIndented(code, after: previous, context: context)
        case .heading, .quote:
            needsBlankLine = false
        case .paragraph, .thematicBreak, .atom, .table:
            needsBlankLine = true
        }
        if needsBlankLine { line("") }
    }

    private static func needsBlankLine(after previous: EditorDocument.Block, before block: EditorDocument.Block) -> Bool {
        switch (previous, block) {
        case (.atom(let atom), _):
            return atom.kind != AtomKind.thematicBreak
        case (.quote, .quote):
            return true
        default:
            return false
        }
    }

    private static func writesIndented(
        _ code: EditorDocument.CodeBlock,
        after previous: EditorDocument.Block?,
        context: Context
    ) -> Bool {
        guard code.isIndented, code.language == nil,
              let first = code.lines.first, let last = code.lines.last,
              !isBlankLine(first), !isBlankLine(last)
        else { return false }
        switch previous {
        case .list?: return false
        case nil: return context != .item
        default: return true
        }
    }

    private static func isBlankLine(_ line: String) -> Bool {
        line.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private static func protectingLeadingIndent(_ rendered: String) -> String {
        var column = 0
        for byte in rendered.utf8 {
            switch byte {
            case 0x20: column += 1
            case 0x09: column += 4 - column % 4
            default: return rendered
            }
            if column >= 4 { break }
        }
        guard column >= 4, let first = rendered.utf8.first else { return rendered }
        return (first == 0x09 ? "&#9;" : "&#32;") + rendered.dropFirst()
    }

    private static func rendersNothing(_ blocks: [EditorDocument.Block]) -> Bool {
        blocks.allSatisfy { block in
            switch block {
            case .paragraph(let runs): return InlineSerializer.serialize(runs, inHeading: false).isEmpty
            case .list(let list): return list.items.isEmpty
            default: return false
            }
        }
    }

    private mutating func write(_ list: EditorDocument.ListBlock, alternateMarker: Bool) {
        let enclosingBullet = itemBullet
        itemBullet = alternateMarker && !list.kind.isOrdered ? "*" : "-"
        defer { itemBullet = enclosingBullet }
        for (index, item) in list.items.enumerated() {
            let marker: String
            switch list.kind {
            case .bullet:
                marker = alternateMarker ? "*" : "-"
            case .ordered(let start):
                marker = "\(start + index)" + (alternateMarker ? ")" : ".")
            }
            let head: String
            switch item.task {
            case .none: head = marker
            case .unchecked?: head = marker + " [ ]"
            case .checked?: head = marker + " [x]"
            }
            let indent = String(repeating: " ", count: marker.count + 1)
            let start = lineCount
            prefixes.append(.item(head: head, indent: indent, isFirstLine: true))
            write(item.blocks, context: .item)
            prefixes.removeLast()
            if lineCount == start { line(head) }
        }
    }

    private mutating func write(_ code: EditorDocument.CodeBlock) {
        let info = code.language ?? ""
        let fenceCharacter: Character = info.contains("`") ? "~" : "`"
        var longest = 0
        for line in code.lines {
            longest = max(longest, MarkdownWriter.longestRun(of: fenceCharacter, in: line))
        }
        let fence = String(repeating: fenceCharacter, count: max(3, longest + 1))
        line(fence + info)
        if code.lines != [""] {
            for body in code.lines { line(body) }
        }
        line(fence)
    }

    private mutating func lines(_ content: String) {
        let utf8 = content.utf8
        var start = utf8.startIndex
        var index = start
        while index < utf8.endIndex {
            if utf8[index] == 0x0A {
                line(Substring(utf8[start..<index]))
                start = utf8.index(after: index)
            }
            index = utf8.index(after: index)
        }
        line(Substring(utf8[start..<utf8.endIndex]))
    }

    private mutating func line(_ content: String) {
        line(content[...])
    }

    private mutating func line(_ content: Substring) {
        if lineCount > 0 { text.append("\n") }
        lineCount += 1
        let isEmpty = content.isEmpty
        let lastFilling = isEmpty ? prefixes.lastIndex(where: \.fillsEmptyLine) : nil
        for index in prefixes.indices {
            let innerIsEmpty = isEmpty && (lastFilling.map { $0 <= index } ?? true)
            switch prefixes[index] {
            case .quote:
                text.append(innerIsEmpty ? ">" : "> ")
            case .item(let head, let indent, let isFirstLine):
                if isFirstLine {
                    text.append(head)
                    text.append(" ")
                    prefixes[index] = .item(head: head, indent: indent, isFirstLine: false)
                } else if !innerIsEmpty {
                    text.append(indent)
                }
            }
        }
        text.append(contentsOf: content)
    }
}

enum TableSerializer {
    typealias Run = EditorDocument.InlineRun

    static func lines(_ table: EditorDocument.TableBlock) -> [String] {
        let width = table.columnCount
        var output = [row(table.header, width: width)]
        output.append(delimiter(table.alignments, width: width))
        for body in table.body {
            output.append(row(body, width: width))
        }
        return output
    }

    static func delimiter(_ alignments: [TableColumnAlignment], width: Int) -> String {
        let cells = (0..<width).map { column -> String in
            switch column < alignments.count ? alignments[column] : .none {
            case .none: return "---"
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            }
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    static func row(_ cells: [EditorDocument.TableCell], width: Int) -> String {
        let rendered = (0..<width).map { column in
            column < cells.count ? cell(cells[column]) : ""
        }
        return "|" + rendered.map { $0.isEmpty ? " " : " " + $0 + " " }.joined(separator: "|") + "|"
    }

    static func cell(_ runs: [Run]) -> String {
        let escaped = splittingPipes(runs.map(escaping))
        let rendered = InlineSerializer.serialize(escaped, inHeading: true)
        return rendered.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    private static func escaping(_ run: Run) -> Run {
        var run = run
        switch run.content {
        case .softBreak, .hardBreak:
            run.content = .text(" ")
            run.marks = run.marks.minus(.code)
        case .text(let text) where run.marks.has(.code) && text.contains("|"):
            run.content = .text(text.replacingOccurrences(of: "|", with: "\\|"))
        case .literal(let text, let source) where source.contains("|") && source != "\\|":
            run.content = .literal(text: text, source: source.replacingOccurrences(of: "|", with: "\\|"))
        case .atom(var atom) where atom.source.contains("|"):
            atom.source = atom.source.replacingOccurrences(of: "|", with: "\\|")
            run.content = .atom(atom)
        default:
            break
        }
        return run
    }

    private static func splittingPipes(_ runs: [Run]) -> [Run] {
        var output: [Run] = []
        for run in runs {
            guard case .text(let text) = run.content, !run.marks.has(.code), text.contains("|") else {
                output.append(run)
                continue
            }
            let parts = text.components(separatedBy: "|")
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    output.append(EditorDocument.InlineRun(.literal(text: "|", source: "\\|"), marks: run.marks, link: run.link))
                }
                if !part.isEmpty {
                    output.append(.text(part, marks: run.marks, link: run.link))
                }
            }
        }
        return output
    }
}

enum InlineSerializer {
    typealias Run = EditorDocument.InlineRun
    typealias Marks = EditorDocument.InlineMarks

    static let nestingOrder: [Marks] = [.strikethrough, .strong, .emphasis]
    static let delimiterMarks: Marks = [.strikethrough, .strong, .emphasis]

    static func serialize(_ runs: [Run], inHeading: Bool) -> String {
        if runs.count == 1, case .text(let text) = runs[0].content, runs[0].marks.isEmpty, runs[0].link == nil {
            return text
        }
        if !runs.contains(where: { $0.content == .softBreak || $0.content == .hardBreak }) {
            return runs.isEmpty ? "" : render(runs)
        }
        var segments: [[Run]] = [[]]
        var breaks: [Bool] = []
        for run in runs {
            switch run.content {
            case .softBreak, .hardBreak:
                breaks.append(run.content == .hardBreak)
                segments.append([])
            default:
                segments[segments.count - 1].append(run)
            }
        }
        for index in segments.indices {
            if index > 0 { trimLeading(&segments[index]) }
            if index < segments.count - 1 { trimTrailing(&segments[index]) }
        }
        joinLinkedSegments(&segments, breaks: &breaks, inHeading: inHeading)

        var output = ""
        var pendingBreak: Bool?
        var hasContent = false
        for index in 0..<segments.count {
            let segment = segments[index]
            if !segment.isEmpty {
                if let hard = pendingBreak, hasContent {
                    output += inHeading ? " " : (hard ? "  \n" : "\n")
                }
                output += render(segment)
                hasContent = true
                pendingBreak = nil
            }
            if index < breaks.count, hasContent {
                pendingBreak = (pendingBreak ?? false) || breaks[index]
            }
        }
        return output
    }

    private static func joinLinkedSegments(_ segments: inout [[Run]], breaks: inout [Bool], inHeading: Bool) {
        guard !breaks.isEmpty else { return }
        var joined: [[Run]] = [segments[0]]
        var joinedBreaks: [Bool] = []
        for index in breaks.indices {
            let next = segments[index + 1]
            if let link = joined[joined.count - 1].last?.link, link == next.first?.link {
                let separator = inHeading ? " " : (breaks[index] ? "  \n" : "\n")
                joined[joined.count - 1].append(.text(separator, link: link))
                joined[joined.count - 1].append(contentsOf: next)
            } else {
                joinedBreaks.append(breaks[index])
                joined.append(next)
            }
        }
        segments = joined
        breaks = joinedBreaks
    }

    private static func isTrimmable(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    private static func trimLeading(_ runs: inout [Run]) {
        while let first = runs.first, case .text(let text) = first.content, !first.marks.has(.code) {
            let trimmed = String(text.unicodeScalars.drop(while: isTrimmable))
            if trimmed.isEmpty {
                runs.removeFirst()
                continue
            }
            runs[0].content = .text(trimmed)
            return
        }
    }

    private static func trimTrailing(_ runs: inout [Run]) {
        while let last = runs.last, case .text(let text) = last.content, !last.marks.has(.code) {
            var trimmed = Substring(text).unicodeScalars
            while let scalar = trimmed.last, isTrimmable(scalar) { trimmed.removeLast() }
            if trimmed.isEmpty {
                runs.removeLast()
                continue
            }
            runs[runs.count - 1].content = .text(String(trimmed))
            return
        }
    }

    private static func render(_ segment: [Run]) -> String {
        if emitsVerbatim(segment) {
            var output = ""
            for run in segment { output += emittedText(of: run) }
            return output
        }
        var runs = merge(detachWhitespace(segment))
        bridgeWhitespaceGaps(&runs)
        runs = merge(runs)
        let items = group(runs)
        var emitter = PieceEmitter()
        emitter.emit(items)
        return emitter.render()
    }

    private static func emitsVerbatim(_ segment: [Run]) -> Bool {
        var previousIsCode = false
        for run in segment {
            guard run.link == nil, run.marks.and(delimiterMarks).rawValue == 0 else { return false }
            guard case .text(let text) = run.content else {
                previousIsCode = false
                continue
            }
            let isCode = run.marks.has(.code)
            if text.isEmpty {
                if isCode { return false }
                continue
            }
            if isCode, previousIsCode { return false }
            previousIsCode = isCode
        }
        return true
    }

    static func isWhitespaceOnly(_ run: Run) -> Bool {
        guard case .text(let text) = run.content, !run.marks.has(.code) else { return false }
        return !text.isEmpty && text.unicodeScalars.allSatisfy(isUnicodeWhitespace)
    }

    private static func detachWhitespace(_ runs: [Run]) -> [Run] {
        var output: [Run] = []
        output.reserveCapacity(runs.count)
        for run in runs {
            guard case .text(let text) = run.content,
                  !run.marks.has(.code),
                  run.marks.and(delimiterMarks).rawValue != 0 else {
                output.append(run)
                continue
            }
            let bare = run.marks.minus(delimiterMarks)
            let scalars = text.unicodeScalars
            guard let first = scalars.firstIndex(where: { !isUnicodeWhitespace($0) }),
                  let last = scalars.lastIndex(where: { !isUnicodeWhitespace($0) }) else {
                output.append(.text(text, marks: bare, link: run.link))
                continue
            }
            let coreEnd = scalars.index(after: last)
            if first == scalars.startIndex, coreEnd == scalars.endIndex {
                output.append(run)
                continue
            }
            if first > scalars.startIndex {
                output.append(.text(String(scalars[..<first]), marks: bare, link: run.link))
            }
            output.append(.text(String(scalars[first..<coreEnd]), marks: run.marks, link: run.link))
            if coreEnd < scalars.endIndex {
                output.append(.text(String(scalars[coreEnd...]), marks: bare, link: run.link))
            }
        }
        return output
    }

    private static func merge(_ runs: [Run]) -> [Run] {
        var output: [Run] = []
        output.reserveCapacity(runs.count)
        for run in runs {
            if case .text(let text) = run.content, text.isEmpty { continue }
            if let last = output.last,
               case .text(let previous) = last.content,
               case .text(let text) = run.content,
               last.marks == run.marks,
               last.link == run.link {
                output[output.count - 1].content = .text(previous + text)
            } else {
                output.append(run)
            }
        }
        return output
    }

    private static func bridgeWhitespaceGaps(_ runs: inout [Run]) {
        guard runs.count >= 3 else { return }
        for index in 1..<(runs.count - 1) where isWhitespaceOnly(runs[index]) {
            let before = runs[index - 1]
            let after = runs[index + 1]
            let shared = before.marks.and(after.marks).and(delimiterMarks)
            runs[index].marks = runs[index].marks.plus(shared)
            if runs[index].link == nil, let link = before.link, link == after.link {
                runs[index].link = link
            }
        }
    }

    enum Item {
        case run(Run, marks: Marks)
        case link(url: String, marks: Marks, runs: [Run], bare: String?)

        var marks: Marks {
            switch self {
            case .run(_, let marks), .link(_, let marks, _, _): return marks
            }
        }
    }

    private static func group(_ runs: [Run]) -> [Item] {
        var items: [Item] = []
        var index = 0
        while index < runs.count {
            let run = runs[index]
            guard let url = run.link else {
                items.append(.run(run, marks: run.marks.and(delimiterMarks)))
                index += 1
                continue
            }
            var end = index + 1
            while end < runs.count, runs[end].link == url { end += 1 }
            let members = Array(runs[index..<end])
            var shared = delimiterMarks
            for member in members { shared = shared.and(member.marks) }
            let previous = index > 0 ? lastCharacter(of: runs[index - 1]) : nil
            let next = end < runs.count ? firstCharacter(of: runs[end]) : nil
            let bare = bareAutolink(members, url: url, outer: shared, previous: previous, next: next)
            items.append(.link(url: url, marks: shared, runs: members, bare: bare))
            index = end
        }
        return items
    }

    private static func bareAutolink(_ members: [Run], url: String, outer: Marks, previous: Character?, next: Character?) -> String? {
        guard members.count == 1,
              case .text(let text) = members[0].content,
              members[0].marks.minus(outer).rawValue == 0,
              let last = text.last,
              !text.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }),
              !".,:;!?*_~)'\"".contains(last) else { return nil }
        let matches = (text == url && (text.hasPrefix("http://") || text.hasPrefix("https://")))
            || (text.hasPrefix("www.") && "http://" + text == url)
            || (text.contains("@") && "mailto:" + text == url)
        guard matches else { return nil }
        if let previous, !previous.isWhitespace, !"*_~(".contains(previous) { return nil }
        if let next, !next.isWhitespace, !".,:;!?*_~)'\"".contains(next) { return nil }
        return text
    }

    static func emittedText(of run: Run) -> String {
        switch run.content {
        case .text(let text): return run.marks.has(.code) ? codeSpan(text) : text
        case .literal(_, let source): return source
        case .atom(let atom): return atom.source
        case .softBreak, .hardBreak: return ""
        }
    }

    private static func firstCharacter(of run: Run) -> Character? {
        switch run.content {
        case .text(let text): return run.marks.has(.code) ? "`" : text.first
        case .literal(_, let source): return source.first
        case .atom(let atom): return atom.source.first
        case .softBreak, .hardBreak: return nil
        }
    }

    private static func lastCharacter(of run: Run) -> Character? {
        switch run.content {
        case .text(let text): return run.marks.has(.code) ? "`" : text.last
        case .literal(_, let source): return source.last
        case .atom(let atom): return atom.source.last
        case .softBreak, .hardBreak: return nil
        }
    }

    static func codeSpan(_ text: String) -> String {
        let fence = String(repeating: "`", count: MarkdownWriter.longestRun(of: "`", in: text) + 1)
        let needsPadding = text.first == "`" || text.last == "`"
            || (text.first == " " && text.last == " " && text.contains { $0 != " " })
        let padding = needsPadding ? " " : ""
        return fence + padding + text + padding + fence
    }

    static func destination(_ url: String) -> String {
        let url = encodingUnsafeDestinationCharacters(url)
        if url.utf8.allSatisfy({ $0 < 0x80 }) {
            return asciiDestination(url)
        }
        var depth = 0
        var balanced = true
        for character in url {
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth < 0 { balanced = false }
            }
        }
        if depth != 0 { balanced = false }
        let needsAngle = !balanced || url.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7F }
        return needsAngle ? "<" + url + ">" : url
    }

    private static let destinationAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    private static func encodingUnsafeDestinationCharacters(_ url: String) -> String {
        let needsEncoding = url.utf8.contains { byte in
            switch byte {
            case 0x3C, 0x3E, 0x5C, 0x0A, 0x0D: return true
            default: return false
            }
        }
        guard needsEncoding else { return url }
        return url.addingPercentEncoding(withAllowedCharacters: destinationAllowed) ?? url
    }
}

extension InlineSerializer {
    fileprivate static func asciiDestination(_ url: String) -> String {
        var depth = 0
        var balanced = true
        var hasSpace = false
        for byte in url.utf8 {
            switch byte {
            case UInt8(ascii: "("):
                depth += 1
            case UInt8(ascii: ")"):
                depth -= 1
                if depth < 0 { balanced = false }
            case 0x00...0x20, 0x7F:
                hasSpace = true
            default:
                break
            }
        }
        if depth != 0 { balanced = false }
        return !balanced || hasSpace ? "<" + url + ">" : url
    }
}

private struct PieceEmitter {
    typealias Marks = EditorDocument.InlineMarks

    enum Piece {
        case text(String)
        case plain(String)
        case open(Marks, Int)
        case close(Marks, Int)
    }

    private var pieces: [Piece] = []
    private var nextID = 0
    private struct Span {
        let open: Int
        let close: Int
    }

    private struct OpenMark {
        let mark: Marks
        let id: Int
    }

    private var emphasisSpans: [Span] = []
    private var openEmphasis: [Int: Int] = [:]

    mutating func emit(_ items: [InlineSerializer.Item]) {
        let count = items.count
        var extents: [[Int]] = InlineSerializer.nestingOrder.map { _ in Array(repeating: 0, count: count + 1) }
        for slot in 0..<InlineSerializer.nestingOrder.count {
            let mark = InlineSerializer.nestingOrder[slot]
            var index = count - 1
            while index >= 0 {
                extents[slot][index] = items[index].marks.has(mark) ? extents[slot][index + 1] + 1 : 0
                index -= 1
            }
        }

        var stack: [OpenMark] = []
        for index in 0..<count {
            let item = items[index]
            let needed = item.marks
            if let firstStale = stack.firstIndex(where: { !needed.has($0.mark) }) {
                for entry in stack[firstStale...].reversed() { close(entry.mark, entry.id) }
                stack.removeSubrange(firstStale...)
            }
            var opened = Marks()
            for entry in stack { opened = opened.plus(entry.mark) }
            var missing: [Int] = []
            for slot in 0..<InlineSerializer.nestingOrder.count {
                let mark = InlineSerializer.nestingOrder[slot]
                if needed.has(mark), !opened.has(mark) { missing.append(slot) }
            }
            if missing.count > 1 {
                missing.sort { lhs, rhs in
                    let left = extents[lhs][index]
                    let right = extents[rhs][index]
                    return left != right ? left > right : lhs < rhs
                }
            }
            for slot in missing {
                let mark = InlineSerializer.nestingOrder[slot]
                stack.append(OpenMark(mark: mark, id: open(mark)))
            }
            emitContent(of: item)
        }
        for entry in stack.reversed() { close(entry.mark, entry.id) }
    }

    private mutating func emitContent(of item: InlineSerializer.Item) {
        switch item {
        case .run(let run, _):
            if case .text(let text) = run.content, !run.marks.has(.code) {
                pieces.append(.plain(text))
            } else {
                pieces.append(.text(InlineSerializer.emittedText(of: run)))
            }
        case .link(let url, let outer, let runs, let bare):
            if let bare {
                pieces.append(.text(bare))
                return
            }
            pieces.append(.text("["))
            let inner = runs.map { run in
                InlineSerializer.Item.run(run, marks: run.marks.and(InlineSerializer.delimiterMarks).minus(outer))
            }
            emit(inner)
            pieces.append(.text("](" + InlineSerializer.destination(url) + ")"))
        }
    }

    private mutating func open(_ mark: Marks) -> Int {
        nextID += 1
        if mark == .emphasis { openEmphasis[nextID] = pieces.count }
        pieces.append(.open(mark, nextID))
        return nextID
    }

    private mutating func close(_ mark: Marks, _ id: Int) {
        if mark == .emphasis, let openIndex = openEmphasis.removeValue(forKey: id) {
            emphasisSpans.append(Span(open: openIndex, close: pieces.count))
        }
        pieces.append(.close(mark, id))
    }

    func render() -> String {
        var underscore = Set<Int>()
        for span in emphasisSpans where usesUnderscore(span) {
            underscore.insert(span.open)
            underscore.insert(span.close)
        }
        let repairs = flankingRepairs(underscore: underscore)
        var output = ""
        for index in 0..<pieces.count {
            switch pieces[index] {
            case .text(let text):
                output += text
            case .plain(let text):
                if repairs.isEmpty {
                    output += text
                } else {
                    output += Self.repaired(text, first: repairs.contains(Repair(piece: index, atStart: true)),
                                            last: repairs.contains(Repair(piece: index, atStart: false)))
                }
            case .open(let mark, _), .close(let mark, _):
                if mark == .emphasis {
                    output += underscore.contains(index) ? "_" : "*"
                } else {
                    output += Self.token(mark)
                }
            }
        }
        return output
    }

    private struct Repair: Equatable {
        let piece: Int
        let atStart: Bool
    }

    private func delimiterByte(_ index: Int, underscore: Set<Int>) -> UInt8? {
        switch pieces[index] {
        case .open(let mark, _), .close(let mark, _):
            if mark == .emphasis { return underscore.contains(index) ? UInt8(ascii: "_") : UInt8(ascii: "*") }
            return mark == .strikethrough ? UInt8(ascii: "~") : UInt8(ascii: "*")
        case .text, .plain:
            return nil
        }
    }

    private func isEmptyText(_ index: Int) -> Bool {
        switch pieces[index] {
        case .text(let text), .plain(let text): return text.isEmpty
        case .open, .close: return false
        }
    }

    private func edgeScalar(_ index: Int, last: Bool, underscore: Set<Int>) -> Unicode.Scalar? {
        switch pieces[index] {
        case .text(let text), .plain(let text):
            return last ? text.unicodeScalars.last : text.unicodeScalars.first
        case .open, .close:
            return delimiterByte(index, underscore: underscore).map { Unicode.Scalar($0) }
        }
    }

    private func flankingRepairs(underscore: Set<Int>) -> [Repair] {
        var repairs: [Repair] = []
        var index = 0
        while index < pieces.count {
            guard let byte = delimiterByte(index, underscore: underscore) else {
                index += 1
                continue
            }
            var end = index
            var opens = false
            var closes = false
            while end < pieces.count, delimiterByte(end, underscore: underscore) == byte {
                if case .open = pieces[end] { opens = true } else { closes = true }
                end += 1
            }
            var before = index - 1
            while before >= 0, isEmptyText(before) { before -= 1 }
            var after = end
            while after < pieces.count, isEmptyText(after) { after += 1 }
            index = end
            guard before >= 0 || after < pieces.count else { continue }
            var previous = before >= 0 ? edgeScalar(before, last: true, underscore: underscore) : nil
            let next = after < pieces.count ? edgeScalar(after, last: false, underscore: underscore) : nil
            if before >= 0, repairs.last == Repair(piece: before, atStart: true),
               case .plain(let text) = pieces[before], text.unicodeScalars.count == 1 {
                previous = ";"
            }
            if opens, before >= 0, case .plain = pieces[before], let previous, let next,
               Self.isPunctuation(next), !Self.isFlankingSpace(previous), !Self.isPunctuation(previous) {
                repairs.append(Repair(piece: before, atStart: false))
            }
            if closes, after < pieces.count, case .plain = pieces[after], let previous, let next,
               Self.isPunctuation(previous), !Self.isFlankingSpace(next), !Self.isPunctuation(next) {
                repairs.append(Repair(piece: after, atStart: true))
            }
        }
        return repairs
    }

    private static func repaired(_ text: String, first: Bool, last: Bool) -> String {
        guard first || last else { return text }
        var scalars = Substring(text).unicodeScalars
        var head = ""
        var tail = ""
        if first, let scalar = scalars.first {
            head = entity(scalar)
            scalars.removeFirst()
        }
        if last, let scalar = scalars.last {
            tail = entity(scalar)
            scalars.removeLast()
        }
        return head + String(scalars) + tail
    }

    private static func entity(_ scalar: Unicode.Scalar) -> String {
        "&#\(scalar.value);"
    }

    private static func isFlankingSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\t", "\n", "\u{0C}", "\r": return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return SourceAligner.isASCIIPunctuation(scalar) }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func token(_ mark: Marks) -> String {
        switch mark {
        case .strong: return "**"
        case .strikethrough: return "~~"
        default: return "*"
        }
    }

    private func piece(_ index: Int) -> Piece? {
        pieces.indices.contains(index) ? pieces[index] : nil
    }

    private func usesUnderscore(_ span: Span) -> Bool {
        let before = piece(span.open - 1)
        let after = piece(span.close + 1)
        let innerFirst = piece(span.open + 1)
        let innerLast = piece(span.close - 1)

        if case .open(.strong, let a)? = before, case .close(.strong, let b)? = after, a == b {
            return false
        }
        let touchesStrong = [before, after, innerFirst, innerLast].contains { Self.isStrongToken($0) }
        let touchesStar = Self.lastCharacter(before) == "*" || Self.firstCharacter(after) == "*"
            || Self.firstCharacter(innerFirst) == "*" || Self.lastCharacter(innerLast) == "*"
        guard touchesStrong || touchesStar else { return false }

        let outerLeft = Self.lastCharacter(before)
        let outerRight = Self.firstCharacter(after)
        if let outerLeft, outerLeft.isLetter || outerLeft.isNumber || outerLeft == "_" { return false }
        if let outerRight, outerRight.isLetter || outerRight.isNumber || outerRight == "_" { return false }
        if Self.firstCharacter(innerFirst) == "_" || Self.lastCharacter(innerLast) == "_" { return false }
        return true
    }

    private static func isStrongToken(_ piece: Piece?) -> Bool {
        switch piece {
        case .open(.strong, _)?, .close(.strong, _)?: return true
        default: return false
        }
    }

    private static func firstCharacter(_ piece: Piece?) -> Character? {
        switch piece {
        case .text(let text)?, .plain(let text)?: return text.first
        case .open(let mark, _)?, .close(let mark, _)?: return token(mark).first
        case nil: return nil
        }
    }

    private static func lastCharacter(_ piece: Piece?) -> Character? {
        switch piece {
        case .text(let text)?, .plain(let text)?: return text.last
        case .open(let mark, _)?, .close(let mark, _)?: return token(mark).last
        case nil: return nil
        }
    }
}

extension EditorDocument.InlineMarks {
    @inline(__always) func has(_ mark: Self) -> Bool { rawValue & mark.rawValue != 0 }
    @inline(__always) func and(_ other: Self) -> Self { Self(rawValue: rawValue & other.rawValue) }
    @inline(__always) func minus(_ other: Self) -> Self { Self(rawValue: rawValue & ~other.rawValue) }
    @inline(__always) func plus(_ other: Self) -> Self { Self(rawValue: rawValue | other.rawValue) }
}

@inline(__always) func isUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.value < 0x80 {
        return scalar == " " || (scalar.value >= 0x09 && scalar.value <= 0x0D)
    }
    return scalar.properties.isWhitespace
}
