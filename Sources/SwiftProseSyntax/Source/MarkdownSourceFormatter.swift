import Foundation

public struct MarkdownSourceFormatter: Sendable {
    public static let urlPlaceholder = "url"
    public static let linkLabelPlaceholder = "link"

    public init() {}

    public func edit(for action: EditorAction, in text: String, selection: NSRange) -> MarkdownSourceEdit? {
        let doc = SourceDocument(text)
        let selection = Self.normalized(selection, in: doc)
        guard canPerform(action, doc, selection) else { return nil }
        let raw: MarkdownSourceEdit?
        switch action {
        case .bold: raw = toggleInline(.strong, doc, selection)
        case .italic: raw = toggleInline(.emphasis, doc, selection)
        case .strikethrough: raw = toggleInline(.strikethrough, doc, selection)
        case .codeSpan: raw = toggleInline(.code, doc, selection)
        case .heading(let level): raw = toggleHeading(level, doc, selection)
        case .unorderedList: raw = toggleBulletList(doc, selection)
        case .orderedList: raw = toggleOrderedList(doc, selection)
        case .taskList: raw = toggleTaskList(doc, selection)
        case .blockquote: raw = toggleQuote(doc, selection)
        case .codeBlock: raw = toggleCodeBlock(doc, selection)
        case .link(let url, let label): raw = applyLink(url: url, label: label, doc, selection)
        case .horizontalRule: raw = insertBlock(["---"], caret: nil, doc, selection)
        case .indent: raw = indent(doc, selection)
        case .outdent: raw = outdent(doc, selection)
        case .insertTable(let rows, let columns): raw = insertTable(rows: rows, columns: columns, doc, selection)
        case .insertTableRowAbove, .insertTableRowBelow, .insertTableColumnBefore, .insertTableColumnAfter,
             .deleteTableRow, .deleteTableColumn, .setTableColumnAlignment, .deleteTable, .editTableStructure:
            raw = nil
        }
        guard let raw else { return nil }
        let edit = raw.minimized(against: doc.ns)
        if edit.range.length == 0, edit.replacement.isEmpty, edit.selection == selection { return nil }
        return edit
    }

    public struct ActionStates: Equatable, Sendable {
        public var active: Set<String> = []
        public var disabled: Set<String> = []

        public init(active: Set<String> = [], disabled: Set<String> = []) {
            self.active = active
            self.disabled = disabled
        }

        public func isActive(_ action: EditorAction) -> Bool { active.contains(action.stableID) }
        public func canPerform(_ action: EditorAction) -> Bool { !disabled.contains(action.stableID) }
    }

    public func states(for actions: [EditorAction], in text: String, selection: NSRange) -> ActionStates {
        let doc = SourceDocument(text)
        let selection = Self.normalized(selection, in: doc)
        var states = ActionStates()
        for action in actions {
            if isActive(action, doc, selection) { states.active.insert(action.stableID) }
            if !canPerform(action, doc, selection) { states.disabled.insert(action.stableID) }
        }
        return states
    }

    public func isActive(_ action: EditorAction, in text: String, selection: NSRange) -> Bool {
        let doc = SourceDocument(text)
        return isActive(action, doc, Self.normalized(selection, in: doc))
    }

    func isActive(_ action: EditorAction, _ doc: SourceDocument, _ selection: NSRange) -> Bool {
        switch action {
        case .bold: return inlineIsActive(.strong, doc, selection)
        case .italic: return inlineIsActive(.emphasis, doc, selection)
        case .strikethrough: return inlineIsActive(.strikethrough, doc, selection)
        case .codeSpan: return inlineIsActive(.code, doc, selection)
        case .heading(let level):
            let targets = headingTargets(doc, selection)
            return !targets.isEmpty && targets.allSatisfy { doc.lines[$0].prefix.heading == level }
        case .unorderedList:
            let targets = listTargets(doc, selection)
            return !targets.isEmpty && targets.allSatisfy { isBullet(doc.lines[$0]) && doc.lines[$0].prefix.task == nil }
        case .orderedList:
            let targets = listTargets(doc, selection)
            return !targets.isEmpty && targets.allSatisfy { doc.lines[$0].prefix.marker?.isOrdered == true }
        case .taskList:
            let targets = listTargets(doc, selection)
            return !targets.isEmpty && targets.allSatisfy { doc.lines[$0].prefix.task != nil }
        case .blockquote:
            let targets = quoteCheckTargets(doc, selection)
            return !targets.isEmpty && targets.allSatisfy { doc.lines[$0].prefix.quoteEnd > 0 }
        case .codeBlock:
            return doc.selectedLines(selection).allSatisfy { doc.fenceIndex($0) != nil }
        case .link:
            return activeLink(doc, selection) != nil
        case .horizontalRule, .indent, .outdent,
             .insertTable, .insertTableRowAbove, .insertTableRowBelow, .insertTableColumnBefore,
             .insertTableColumnAfter, .deleteTableRow, .deleteTableColumn, .setTableColumnAlignment,
             .deleteTable, .editTableStructure:
            return false
        }
    }

    public func canPerform(_ action: EditorAction, in text: String, selection: NSRange) -> Bool {
        let doc = SourceDocument(text)
        return canPerform(action, doc, Self.normalized(selection, in: doc))
    }

    func canPerform(_ action: EditorAction, _ doc: SourceDocument, _ selection: NSRange) -> Bool {
        let lines = doc.selectedLines(selection)
        let hasProse = lines.contains { !doc.isCode($0) }
        switch action {
        case .bold, .italic, .strikethrough, .codeSpan, .link,
             .heading, .unorderedList, .orderedList, .taskList:
            return hasProse
        case .blockquote, .codeBlock:
            return true
        case .horizontalRule, .insertTable:
            return !doc.isCodeContent(lines.upperBound)
        case .indent, .outdent:
            let candidates = lines.filter { !doc.lines[$0].isBlank }
            return !candidates.isEmpty && candidates.allSatisfy {
                !doc.isCode($0) && (doc.lines[$0].prefix.isListItem || doc.isContinuation($0))
            }
        case .insertTableRowAbove, .insertTableRowBelow, .insertTableColumnBefore, .insertTableColumnAfter,
             .deleteTableRow, .deleteTableColumn, .setTableColumnAlignment, .deleteTable, .editTableStructure:
            return false
        }
    }

    static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location == NSNotFound ? length : range.location), length)
        let end = min(max(location, range.location == NSNotFound ? location : NSMaxRange(range)), length)
        return NSRange(location: location, length: end - location)
    }

    static func snap(_ range: NSRange, in ns: NSString) -> NSRange {
        guard ns.length > 0 else { return range }
        func boundary(_ location: Int) -> Int {
            guard location > 0, location < ns.length else { return location }
            let composed = ns.rangeOfComposedCharacterSequence(at: location)
            return composed.location == location ? location : composed.location
        }
        let start = boundary(range.location)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        var end = NSMaxRange(range)
        if end < ns.length {
            let composed = ns.rangeOfComposedCharacterSequence(at: end)
            if composed.location != end { end = NSMaxRange(composed) }
        }
        return NSRange(location: start, length: end - start)
    }

    static func normalized(_ range: NSRange, in doc: SourceDocument) -> NSRange {
        snap(clamp(range, to: doc.length), in: doc.ns)
    }

    func isBullet(_ line: SourceLine) -> Bool {
        if case .bullet = line.prefix.marker?.kind { return true }
        return false
    }
}

// MARK: - Line rewrites

struct SourceLineRewrite {
    var index: Int
    var oldPrefixLength: Int
    var newPrefix: String
}

extension MarkdownSourceFormatter {
    func prefixText(_ doc: SourceDocument, _ index: Int, _ length: Int) -> String {
        doc.string(NSRange(location: doc.lines[index].start, length: length))
    }

    func rewrite(_ doc: SourceDocument, _ rewrites: [SourceLineRewrite], selection: NSRange) -> MarkdownSourceEdit? {
        guard let first = rewrites.map(\.index).min(), let last = rewrites.map(\.index).max() else { return nil }
        var byIndex: [Int: SourceLineRewrite] = [:]
        for item in rewrites { byIndex[item.index] = item }
        var output: [String] = []
        var newStarts: [Int: Int] = [:]
        let rangeStart = doc.lines[first].start
        var cursor = rangeStart
        for index in first...last {
            let line = doc.lines[index]
            newStarts[index] = cursor
            let text: String
            if let item = byIndex[index] {
                let rest = doc.string(NSRange(location: line.start + item.oldPrefixLength, length: line.range.length - item.oldPrefixLength))
                text = item.newPrefix + rest
            } else {
                text = doc.string(line.range)
            }
            output.append(text)
            cursor += (text as NSString).length + 1
        }
        let range = NSRange(location: rangeStart, length: doc.lines[last].end - rangeStart)
        let replacement = output.joined(separator: "\n")
        let delta = (replacement as NSString).length - range.length

        func map(_ position: Int, keepLineStart: Bool) -> Int {
            if position < range.location { return position }
            if position > NSMaxRange(range) { return position + delta }
            let index = doc.lineIndex(containing: position)
            guard index >= first, index <= last, let start = newStarts[index] else { return position + delta }
            let column = position - doc.lines[index].start
            guard let item = byIndex[index] else { return start + column }
            let newLength = (item.newPrefix as NSString).length
            if column == 0, keepLineStart { return start }
            if column >= item.oldPrefixLength { return start + newLength + column - item.oldPrefixLength }
            return start + newLength
        }

        let keep = doc.selectedLines(selection).count > 1
        let newStart = map(selection.location, keepLineStart: keep)
        let newEnd = selection.length > 0 ? map(NSMaxRange(selection), keepLineStart: false) : newStart
        return MarkdownSourceEdit(
            range: range,
            replacement: replacement,
            selection: NSRange(location: newStart, length: max(0, newEnd - newStart))
        )
    }
}

// MARK: - Headings, lists, quotes

extension MarkdownSourceFormatter {
    func headingTargets(_ doc: SourceDocument, _ selection: NSRange) -> [Int] {
        let prose = doc.selectedLines(selection).filter { !doc.isCode($0) }
        let filled = prose.filter { !doc.lines[$0].isBlank }
        return filled.isEmpty ? prose : filled
    }

    func listTargets(_ doc: SourceDocument, _ selection: NSRange) -> [Int] {
        let prose = doc.selectedLines(selection).filter { !doc.isCode($0) }
        let filled = prose.filter { !doc.lines[$0].isBlank && !doc.isContinuation($0) }
        if !filled.isEmpty { return filled }
        return prose.filter { doc.lines[$0].isBlank }
    }

    func quoteCheckTargets(_ doc: SourceDocument, _ selection: NSRange) -> [Int] {
        let lines = Array(doc.selectedLines(selection))
        let filled = lines.filter { !doc.lines[$0].isBlank }
        return filled.isEmpty ? lines : filled
    }

    func toggleHeading(_ level: Int, _ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        let targets = headingTargets(doc, selection)
        guard !targets.isEmpty else { return nil }
        let removing = targets.allSatisfy { doc.lines[$0].prefix.heading == level }
        let rewrites = targets.map { index -> SourceLineRewrite in
            let line = doc.lines[index]
            let keptLength: Int
            if line.isBlank {
                keptLength = line.prefix.quoteEnd
            } else {
                keptLength = removing ? line.prefix.taskEnd : line.prefix.markerEnd
            }
            let marker = removing ? "" : String(repeating: "#", count: level) + " "
            let oldLength = line.isBlank ? line.range.length : line.prefix.contentStart
            return SourceLineRewrite(index: index, oldPrefixLength: oldLength, newPrefix: prefixText(doc, index, keptLength) + marker)
        }
        return rewrite(doc, rewrites, selection: selection)
    }

    func listBase(_ doc: SourceDocument, _ index: Int) -> String {
        let line = doc.lines[index]
        return prefixText(doc, index, line.isBlank ? line.prefix.quoteEnd : line.prefix.indentEnd)
    }

    func oldListPrefixLength(_ line: SourceLine) -> Int {
        line.isBlank ? line.range.length : line.prefix.taskEnd
    }

    func toggleBulletList(_ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        let targets = listTargets(doc, selection)
        guard !targets.isEmpty else { return nil }
        let removing = targets.allSatisfy { isBullet(doc.lines[$0]) && doc.lines[$0].prefix.task == nil }
        let rewrites = targets.map { index -> SourceLineRewrite in
            let line = doc.lines[index]
            var marker = ""
            if !removing {
                if case .bullet(let char) = line.prefix.marker?.kind { marker = "\(char) " } else { marker = "- " }
            }
            return SourceLineRewrite(index: index, oldPrefixLength: oldListPrefixLength(line), newPrefix: listBase(doc, index) + marker)
        }
        return rewrite(doc, rewrites, selection: selection)
    }

    func toggleOrderedList(_ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        let targets = listTargets(doc, selection)
        guard !targets.isEmpty else { return nil }
        let removing = targets.allSatisfy { doc.lines[$0].prefix.marker?.isOrdered == true }
        var counters: [Int: Int] = [:]
        let rewrites = targets.map { index -> SourceLineRewrite in
            let line = doc.lines[index]
            var marker = ""
            if !removing {
                let indent = line.isBlank ? 0 : line.prefix.indent
                counters = counters.filter { $0.key <= indent }
                let number = counters[indent].map { $0 + 1 } ?? orderedStart(doc, before: index, indent: indent)
                counters[indent] = number
                marker = "\(number). "
            }
            return SourceLineRewrite(index: index, oldPrefixLength: oldListPrefixLength(line), newPrefix: listBase(doc, index) + marker)
        }
        return rewrite(doc, rewrites, selection: selection)
    }

    func orderedStart(_ doc: SourceDocument, before index: Int, indent: Int) -> Int {
        var i = index - 1
        while i >= 0 {
            let line = doc.lines[i]
            if doc.isCode(i) { return 1 }
            if line.isBlank { i -= 1; continue }
            if let marker = line.prefix.marker {
                if line.prefix.indent == indent {
                    if case .ordered(let number, _) = marker.kind { return number + 1 }
                    return 1
                }
                if line.prefix.indent < indent { return 1 }
            } else if line.prefix.indent <= indent {
                return 1
            }
            i -= 1
        }
        return 1
    }

    func toggleTaskList(_ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        let targets = listTargets(doc, selection)
        guard !targets.isEmpty else { return nil }
        let removing = targets.allSatisfy { doc.lines[$0].prefix.task != nil }
        let rewrites = targets.map { index -> SourceLineRewrite in
            let line = doc.lines[index]
            if removing {
                return SourceLineRewrite(index: index, oldPrefixLength: line.prefix.taskEnd, newPrefix: listBase(doc, index))
            }
            let oldLength = line.isBlank ? line.range.length : line.prefix.contentStart
            if line.prefix.marker != nil {
                let task = line.prefix.task == nil
                    ? "[ ] "
                    : doc.string(NSRange(location: line.start + line.prefix.markerEnd, length: line.prefix.taskEnd - line.prefix.markerEnd))
                let marker = prefixText(doc, index, line.prefix.markerEnd)
                let spacer = marker.hasSuffix(" ") ? "" : " "
                let box = task.hasSuffix(" ") ? task : task + " "
                return SourceLineRewrite(index: index, oldPrefixLength: oldLength, newPrefix: marker + spacer + box)
            }
            return SourceLineRewrite(index: index, oldPrefixLength: oldLength, newPrefix: listBase(doc, index) + "- [ ] ")
        }
        return rewrite(doc, rewrites, selection: selection)
    }

    func toggleQuote(_ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        let lines = Array(doc.selectedLines(selection))
        let check = quoteCheckTargets(doc, selection)
        let removing = check.allSatisfy { doc.lines[$0].prefix.quoteEnd > 0 }
        var rewrites: [SourceLineRewrite] = []
        for index in lines {
            let line = doc.lines[index]
            if removing {
                guard line.prefix.quoteEnd > 0 else { continue }
                var pos = 0
                while doc.ns.character(at: line.start + pos) != 0x3E { pos += 1 }
                pos += 1
                if pos < line.range.length, doc.ns.character(at: line.start + pos) == 0x20 { pos += 1 }
                rewrites.append(SourceLineRewrite(index: index, oldPrefixLength: pos, newPrefix: ""))
            } else if line.isBlank, lines.count > 1 {
                rewrites.append(SourceLineRewrite(index: index, oldPrefixLength: line.range.length, newPrefix: ">"))
            } else if line.isBlank {
                rewrites.append(SourceLineRewrite(index: index, oldPrefixLength: line.range.length, newPrefix: "> "))
            } else {
                rewrites.append(SourceLineRewrite(index: index, oldPrefixLength: 0, newPrefix: "> "))
            }
        }
        return rewrite(doc, rewrites, selection: selection)
    }
}

// MARK: - Indent / outdent

extension MarkdownSourceFormatter {
    func owningItem(_ doc: SourceDocument, _ index: Int) -> Int? {
        var i = index
        while i >= 0 {
            if doc.lines[i].prefix.isListItem { return i }
            if doc.lines[i].isBlank || doc.isCode(i) { return nil }
            i -= 1
        }
        return nil
    }

    func itemBlock(_ doc: SourceDocument, _ selection: NSRange) -> (base: Int, lines: [Int])? {
        let selected = doc.selectedLines(selection)
        guard let head = selected.first(where: { !doc.lines[$0].isBlank }),
              let base = owningItem(doc, head) else { return nil }
        let baseIndent = doc.lines[base].prefix.indent
        var last = selected.upperBound
        while last + 1 < doc.lines.count {
            let next = doc.lines[last + 1]
            guard !next.isBlank, !doc.isCode(last + 1), next.prefix.indent > baseIndent else { break }
            last += 1
        }
        return (base, Array(base...last))
    }

    func spaces(_ count: Int) -> String { String(repeating: " ", count: max(0, count)) }

    func indent(_ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        guard let block = itemBlock(doc, selection) else { return nil }
        let baseLine = doc.lines[block.base]
        let baseIndent = baseLine.prefix.indent
        var sibling: Int?
        var i = block.base - 1
        while i >= 0 {
            let line = doc.lines[i]
            if doc.isCode(i) { break }
            if line.isBlank { i -= 1; continue }
            if line.prefix.isListItem {
                if line.prefix.indent == baseIndent { sibling = i; break }
                if line.prefix.indent < baseIndent { break }
            } else if line.prefix.indent <= baseIndent {
                break
            }
            i -= 1
        }
        guard let sibling else { return nil }
        let siblingLine = doc.lines[sibling]
        let width = max(2, siblingLine.prefix.markerEnd - siblingLine.prefix.indentEnd + (siblingLine.prefix.markerEnd == siblingLine.end ? 1 : 0))
        let newIndent = baseIndent + width
        var counter: Int?
        if baseLine.prefix.marker?.isOrdered == true {
            var start = 1
            for j in (sibling + 1)..<block.base {
                let line = doc.lines[j]
                if line.prefix.indent == newIndent, case .ordered(let number, _) = line.prefix.marker?.kind { start = number + 1 }
            }
            counter = start
        }
        var rewrites: [SourceLineRewrite] = []
        for index in block.lines {
            let line = doc.lines[index]
            guard !line.isBlank else { continue }
            let quote = prefixText(doc, index, line.prefix.quoteEnd)
            let indentText = doc.string(NSRange(location: line.start + line.prefix.quoteEnd, length: line.prefix.indent))
            if line.prefix.indent == baseIndent, let number = counter,
               case .ordered(_, let delimiter) = line.prefix.marker?.kind {
                counter = number + 1
                rewrites.append(SourceLineRewrite(
                    index: index,
                    oldPrefixLength: line.prefix.markerEnd,
                    newPrefix: quote + spaces(width) + indentText + "\(number)\(delimiter) "
                ))
            } else {
                rewrites.append(SourceLineRewrite(
                    index: index,
                    oldPrefixLength: line.prefix.indentEnd,
                    newPrefix: quote + spaces(width) + indentText
                ))
            }
        }
        return rewrite(doc, rewrites, selection: selection)
    }

    func outdent(_ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        guard let block = itemBlock(doc, selection) else { return nil }
        let baseLine = doc.lines[block.base]
        let baseIndent = baseLine.prefix.indent
        var rewrites: [SourceLineRewrite] = []
        if baseIndent == 0 {
            var width = 0
            for index in block.lines {
                let line = doc.lines[index]
                guard !line.isBlank else { continue }
                let quote = prefixText(doc, index, line.prefix.quoteEnd)
                if line.prefix.indent == 0, line.prefix.isListItem {
                    width = line.prefix.markerEnd - line.prefix.indentEnd
                    rewrites.append(SourceLineRewrite(index: index, oldPrefixLength: line.prefix.taskEnd, newPrefix: quote))
                } else {
                    let keep = max(0, line.prefix.indent - width)
                    let indentText = doc.string(NSRange(location: line.start + line.prefix.indentEnd - keep, length: keep))
                    rewrites.append(SourceLineRewrite(index: index, oldPrefixLength: line.prefix.indentEnd, newPrefix: quote + indentText))
                }
            }
            return rewrite(doc, rewrites, selection: selection)
        }
        var parent: Int?
        var i = block.base - 1
        while i >= 0 {
            let line = doc.lines[i]
            if doc.isCode(i) { break }
            if line.isBlank { i -= 1; continue }
            if line.prefix.isListItem, line.prefix.indent < baseIndent { parent = i; break }
            if !line.prefix.isListItem, line.prefix.indent == 0 { break }
            i -= 1
        }
        let parentIndent = parent.map { doc.lines[$0].prefix.indent } ?? 0
        let shift = baseIndent - parentIndent
        var counter: Int?
        if baseLine.prefix.marker?.isOrdered == true, let parent,
           case .ordered(let number, _) = doc.lines[parent].prefix.marker?.kind {
            counter = number + 1
        }
        for index in block.lines {
            let line = doc.lines[index]
            guard !line.isBlank else { continue }
            let quote = prefixText(doc, index, line.prefix.quoteEnd)
            let keep = max(0, line.prefix.indent - shift)
            let indentText = doc.string(NSRange(location: line.start + line.prefix.indentEnd - keep, length: keep))
            if line.prefix.indent == baseIndent, let number = counter,
               case .ordered(_, let delimiter) = line.prefix.marker?.kind {
                counter = number + 1
                rewrites.append(SourceLineRewrite(index: index, oldPrefixLength: line.prefix.markerEnd, newPrefix: quote + indentText + "\(number)\(delimiter) "))
            } else {
                rewrites.append(SourceLineRewrite(index: index, oldPrefixLength: line.prefix.indentEnd, newPrefix: quote + indentText))
            }
        }
        return rewrite(doc, rewrites, selection: selection)
    }
}

// MARK: - Code blocks

extension MarkdownSourceFormatter {
    func toggleCodeBlock(_ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        let selected = doc.selectedLines(selection)
        let fenceIDs = Set(selected.compactMap { doc.fenceIndex($0) })
        let removing = selected.allSatisfy { doc.fenceIndex($0) != nil }
        var first = selected.lowerBound
        var last = selected.upperBound
        var fenceLines = Set<Int>()
        for id in fenceIDs {
            let fence = doc.fences[id]
            first = min(first, fence.open)
            last = max(last, fence.lastLine)
            fenceLines.insert(fence.open)
            if let close = fence.close { fenceLines.insert(close) }
        }
        let kept = (first...last).filter { !fenceLines.contains($0) }
        var output: [String] = []
        var opening: String?
        if !removing {
            var longest = 0
            for index in kept {
                if let run = SourceDocument.fenceRun(doc.ns, doc.lines[index]), run.char == 0x60 { longest = max(longest, run.length) }
            }
            let filled = kept.filter { !doc.lines[$0].isBlank }
            var quote = ""
            if let head = filled.first, filled.allSatisfy({ doc.lines[$0].prefix.quoteEnd > 0 }) {
                quote = prefixText(doc, head, doc.lines[head].prefix.quoteEnd)
            }
            let fence = quote + String(repeating: "`", count: max(3, longest + 1))
            opening = fence
            output.append(fence)
        }
        var newStarts: [Int: Int] = [:]
        let rangeStart = doc.lines[first].start
        var cursor = rangeStart + (opening.map { ($0 as NSString).length + 1 } ?? 0)
        for index in kept {
            newStarts[index] = cursor
            let text = doc.string(doc.lines[index].range)
            output.append(text)
            cursor += (text as NSString).length + 1
        }
        if let opening { output.append(opening) }
        let range = NSRange(location: rangeStart, length: doc.lines[last].end - rangeStart)
        let replacement = output.joined(separator: "\n")
        let replacementEnd = rangeStart + (replacement as NSString).length

        func map(_ position: Int) -> Int {
            let index = doc.lineIndex(containing: position)
            if let start = newStarts[index] { return start + position - doc.lines[index].start }
            if let next = kept.first(where: { $0 > index }), let start = newStarts[next] { return start }
            if let previous = kept.last(where: { $0 < index }), let start = newStarts[previous] {
                return start + doc.lines[previous].range.length
            }
            return min(rangeStart, replacementEnd)
        }
        let start = map(selection.location)
        let end = selection.length > 0 ? map(NSMaxRange(selection)) : start
        return MarkdownSourceEdit(range: range, replacement: replacement, selection: NSRange(location: start, length: max(0, end - start)))
    }
}

// MARK: - Block insertion

extension MarkdownSourceFormatter {
    func insertBlock(_ block: [String], caret: Int?, _ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit {
        let index = doc.selectedLines(selection).upperBound
        let line = doc.lines[index]
        let range = line.isBlank ? line.range : NSRange(location: line.end, length: 0)
        let before = doc.string(NSRange(location: 0, length: range.location))
        let after = doc.string(NSRange(location: NSMaxRange(range), length: doc.length - NSMaxRange(range)))
        let prefix: String
        if before.isEmpty || before.hasSuffix("\n\n") {
            prefix = ""
        } else if before.hasSuffix("\n") {
            prefix = "\n"
        } else {
            prefix = "\n\n"
        }
        let suffix: String
        if after.isEmpty {
            suffix = "\n"
        } else if after.hasPrefix("\n\n") {
            suffix = ""
        } else {
            suffix = "\n"
        }
        let body = block.joined(separator: "\n")
        let replacement = prefix + body + suffix
        let bodyStart = range.location + (prefix as NSString).length
        let location = caret.map { bodyStart + $0 } ?? bodyStart + (body as NSString).length + 1
        return MarkdownSourceEdit(range: range, replacement: replacement, selection: NSRange(location: location, length: 0))
    }

    func insertTable(rows: Int, columns: Int, _ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit {
        let columns = max(1, columns)
        let rows = max(0, rows)
        let empty = "|" + String(repeating: "     |", count: columns)
        let delimiter = "|" + String(repeating: " --- |", count: columns)
        let lines = [empty, delimiter] + Array(repeating: empty, count: rows)
        return insertBlock(lines, caret: 2, doc, selection)
    }
}
