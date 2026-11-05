import Foundation

extension MarkdownSourceFormatter {
    struct InlineSegment {
        var line: Int
        var range: NSRange
    }

    struct InlineOp {
        var replacements: [(NSRange, String)]
        var start: Int
        var end: Int
        var delta: Int
    }

    func lineSpans(_ doc: SourceDocument, _ index: Int) -> [SourceInlineSpan] {
        SourceInline.spans(in: doc.ns, range: doc.lines[index].contentRange)
    }

    func inlineSegments(_ doc: SourceDocument, _ selection: NSRange) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        for index in doc.selectedLines(selection) where !doc.isCode(index) && !doc.lines[index].isBlank {
            let line = doc.lines[index]
            var start = max(selection.location, line.contentRange.location)
            var end = min(NSMaxRange(selection), line.end)
            while start < end, SourceDocument.isSpace(doc.ns.character(at: start)) { start += 1 }
            while end > start, SourceDocument.isSpace(doc.ns.character(at: end - 1)) { end -= 1 }
            if end > start { segments.append(InlineSegment(line: index, range: NSRange(location: start, length: end - start))) }
        }
        return segments
    }

    func containingSpan(_ kind: SourceInlineKind, _ spans: [SourceInlineSpan], _ segment: NSRange) -> SourceInlineSpan? {
        spans
            .filter { span in
                span.kind == kind
                    && segment.location >= span.outer.location && NSMaxRange(segment) <= NSMaxRange(span.outer)
                    && NSMaxRange(segment) > span.inner.location && segment.location < NSMaxRange(span.inner)
            }
            .min { $0.outer.length < $1.outer.length }
    }

    func caretSpan(_ kind: SourceInlineKind, _ spans: [SourceInlineSpan], _ caret: Int) -> SourceInlineSpan? {
        spans
            .filter { $0.kind == kind && $0.inner.location < caret && caret <= NSMaxRange($0.inner) }
            .min { $0.outer.length < $1.outer.length }
    }

    func caretLocation(_ doc: SourceDocument, _ caret: Int) -> (line: Int, caret: Int)? {
        let index = doc.lineIndex(containing: caret)
        guard !doc.isCode(index) else { return nil }
        let line = doc.lines[index]
        let floor = line.isBlank ? line.start + line.prefix.quoteEnd : line.contentRange.location
        return (index, max(caret, min(floor, line.end)))
    }

    func emptyPair(_ kind: SourceInlineKind, _ doc: SourceDocument, _ caret: Int, line: SourceLine, spans: [SourceInlineSpan]) -> Int? {
        guard caret > line.start, caret < line.end else { return nil }
        let before = doc.ns.character(at: caret - 1)
        let allowed: [unichar]
        switch kind {
        case .strong, .emphasis: allowed = [0x2A, 0x5F]
        case .strikethrough: allowed = [0x7E]
        case .code: allowed = [0x60]
        }
        guard allowed.contains(before), doc.ns.character(at: caret) == before else { return nil }
        var left = 0
        while caret - left - 1 >= line.start, doc.ns.character(at: caret - left - 1) == before { left += 1 }
        let right = SourceInline.runLength(doc.ns, at: caret, end: line.end, char: before)
        guard left == right else { return nil }
        let touched = spans.contains { span in
            NSLocationInRange(caret - 1, span.open) || NSLocationInRange(caret - 1, span.close)
                || NSLocationInRange(caret, span.open) || NSLocationInRange(caret, span.close)
        }
        guard !touched else { return nil }
        switch kind {
        case .strong: return left >= 2 ? 2 : nil
        case .emphasis: return left % 2 == 1 ? 1 : nil
        case .strikethrough: return left <= 2 ? left : nil
        case .code: return left
        }
    }

    func inlineIsActive(_ kind: SourceInlineKind, _ doc: SourceDocument, _ selection: NSRange) -> Bool {
        if selection.length == 0 {
            guard let (index, caret) = caretLocation(doc, selection.location) else { return false }
            let spans = lineSpans(doc, index)
            return caretSpan(kind, spans, caret) != nil
                || emptyPair(kind, doc, caret, line: doc.lines[index], spans: spans) != nil
        }
        let segments = inlineSegments(doc, selection)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { containingSpan(kind, lineSpans(doc, $0.line), $0.range) != nil }
    }

    func toggleInline(_ kind: SourceInlineKind, _ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        if selection.length == 0 { return toggleInlineAtCaret(kind, doc, selection.location) }
        let segments = inlineSegments(doc, selection)
        guard !segments.isEmpty else { return nil }
        let active = segments.allSatisfy { containingSpan(kind, lineSpans(doc, $0.line), $0.range) != nil }
        var replacements: [(NSRange, String)] = []
        var delta = 0
        var newStart: Int?
        var newEnd = 0
        for segment in segments {
            let spans = lineSpans(doc, segment.line)
            let op: InlineOp
            if active, let span = containingSpan(kind, spans, segment.range) {
                op = removeOp(span, segment.range, spans, doc)
            } else {
                op = wrapOp(kind, segment.range, spans, doc)
            }
            replacements.append(contentsOf: op.replacements)
            if newStart == nil { newStart = op.start + delta }
            newEnd = op.end + delta
            delta += op.delta
        }
        guard let start = newStart else { return nil }
        return combine(replacements, doc, selection: NSRange(location: start, length: max(0, newEnd - start)))
    }

    func toggleInlineAtCaret(_ kind: SourceInlineKind, _ doc: SourceDocument, _ location: Int) -> MarkdownSourceEdit? {
        guard let (index, caret) = caretLocation(doc, location) else { return nil }
        let line = doc.lines[index]
        let spans = lineSpans(doc, index)
        if let span = caretSpan(kind, spans, caret) {
            if caret == NSMaxRange(span.inner) {
                return MarkdownSourceEdit(
                    range: NSRange(location: caret, length: 0),
                    replacement: "",
                    selection: NSRange(location: NSMaxRange(span.close), length: 0)
                )
            }
            let removal = delimiterRemoval(span, doc)
            let content = doc.string(NSRange(location: NSMaxRange(removal.open), length: removal.close.location - NSMaxRange(removal.open)))
            let position = min(max(caret, NSMaxRange(removal.open)), removal.close.location) - removal.open.length
            return MarkdownSourceEdit(range: span.outer, replacement: content, selection: NSRange(location: position, length: 0))
        }
        if let count = emptyPair(kind, doc, caret, line: line, spans: spans) {
            return MarkdownSourceEdit(
                range: NSRange(location: caret - count, length: count * 2),
                replacement: "",
                selection: NSRange(location: caret - count, length: 0)
            )
        }
        let delimiter = kind.delimiter
        let length = (delimiter as NSString).length
        return MarkdownSourceEdit(
            range: NSRange(location: caret, length: 0),
            replacement: delimiter + delimiter,
            selection: NSRange(location: caret + length, length: 0)
        )
    }

    func delimiterRemoval(_ span: SourceInlineSpan, _ doc: SourceDocument) -> (open: NSRange, close: NSRange) {
        guard span.kind == .code else { return (span.open, span.close) }
        let inner = span.inner
        guard inner.length >= 2,
              doc.ns.character(at: inner.location) == 0x20,
              doc.ns.character(at: NSMaxRange(inner) - 1) == 0x20,
              !SourceDocument.isBlank(doc.ns, inner)
        else { return (span.open, span.close) }
        return (
            NSRange(location: span.open.location, length: span.open.length + 1),
            NSRange(location: span.close.location - 1, length: span.close.length + 1)
        )
    }

    func removeOp(_ span: SourceInlineSpan, _ segment: NSRange, _ spans: [SourceInlineSpan], _ doc: SourceDocument) -> InlineOp {
        let removal = delimiterRemoval(span, doc)
        let contentStart = NSMaxRange(removal.open)
        let contentEnd = removal.close.location
        let a = min(max(segment.location, contentStart), contentEnd)
        let b = max(min(NSMaxRange(segment), contentEnd), a)
        let nested = spans.filter { $0 != span && NSIntersectionRange($0.outer, span.inner).length == $0.outer.length }
        func skippable(_ index: Int) -> Bool {
            SourceDocument.isSpace(doc.ns.character(at: index))
                || nested.contains { NSLocationInRange(index, $0.open) || NSLocationInRange(index, $0.close) }
        }
        var x1 = a
        while x1 > contentStart, skippable(x1 - 1) { x1 -= 1 }
        var x2 = b
        while x2 < contentEnd, skippable(x2) { x2 += 1 }
        let open = doc.string(span.open)
        let close = doc.string(span.close)
        var replacements: [(NSRange, String)] = []
        var shift = 0
        var delta = 0
        if x1 <= contentStart {
            replacements.append((removal.open, ""))
            shift -= removal.open.length
            delta -= removal.open.length
        } else {
            var insertion = a
            while insertion > contentStart, SourceDocument.isSpace(doc.ns.character(at: insertion - 1)) { insertion -= 1 }
            replacements.append((NSRange(location: insertion, length: 0), close))
            shift += span.close.length
            delta += span.close.length
        }
        if x2 >= contentEnd {
            replacements.append((removal.close, ""))
            delta -= removal.close.length
        } else {
            var insertion = b
            while insertion < contentEnd, SourceDocument.isSpace(doc.ns.character(at: insertion)) { insertion += 1 }
            replacements.append((NSRange(location: insertion, length: 0), open))
            delta += span.open.length
        }
        return InlineOp(replacements: replacements, start: a + shift, end: b + shift, delta: delta)
    }

    func wrapOp(_ kind: SourceInlineKind, _ segment: NSRange, _ spans: [SourceInlineSpan], _ doc: SourceDocument) -> InlineOp {
        let merged = spans.filter { $0.kind == kind && NSIntersectionRange($0.outer, segment).length > 0 }
        var union = segment
        for span in merged { union = NSUnionRange(union, span.outer) }
        var removals: [NSRange] = []
        for span in merged {
            let removal = delimiterRemoval(span, doc)
            removals.append(removal.open)
            removals.append(removal.close)
        }
        removals.sort { $0.location < $1.location }
        var core = ""
        var cursor = union.location
        for removal in removals {
            if removal.location > cursor { core += doc.string(NSRange(location: cursor, length: removal.location - cursor)) }
            cursor = max(cursor, NSMaxRange(removal))
        }
        if NSMaxRange(union) > cursor { core += doc.string(NSRange(location: cursor, length: NSMaxRange(union) - cursor)) }
        let (open, close) = delimiters(for: kind, wrapping: core)
        let replacement = open + core + close
        let start = union.location + (open as NSString).length
        return InlineOp(
            replacements: [(union, replacement)],
            start: start,
            end: start + (core as NSString).length,
            delta: (replacement as NSString).length - union.length
        )
    }

    func delimiters(for kind: SourceInlineKind, wrapping core: String) -> (String, String) {
        guard kind == .code else { return (kind.delimiter, kind.delimiter) }
        let fence = String(repeating: "`", count: SourceInline.longestBacktickRun(in: core as NSString) + 1)
        let trimmed = core.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let pad = core.hasPrefix("`") || core.hasSuffix("`")
            || (core.hasPrefix(" ") && core.hasSuffix(" ") && !trimmed.isEmpty)
        return pad ? (fence + " ", " " + fence) : (fence, fence)
    }

    func combine(_ replacements: [(NSRange, String)], _ doc: SourceDocument, selection: NSRange) -> MarkdownSourceEdit? {
        let sorted = replacements.sorted { $0.0.location < $1.0.location }
        guard let first = sorted.first, let last = sorted.max(by: { NSMaxRange($0.0) < NSMaxRange($1.0) }) else { return nil }
        let range = NSRange(location: first.0.location, length: NSMaxRange(last.0) - first.0.location)
        var output = ""
        var cursor = range.location
        for (target, text) in sorted {
            if target.location > cursor { output += doc.string(NSRange(location: cursor, length: target.location - cursor)) }
            output += text
            cursor = max(cursor, NSMaxRange(target))
        }
        return MarkdownSourceEdit(range: range, replacement: output, selection: selection)
    }
}

// MARK: - Links

extension MarkdownSourceFormatter {
    func activeLink(_ doc: SourceDocument, _ selection: NSRange) -> SourceLink? {
        let index = doc.lineIndex(containing: selection.location)
        guard !doc.isCode(index) else { return nil }
        let links = SourceInline.links(in: doc.ns, range: doc.lines[index].range)
        if selection.length == 0 {
            return links.first { $0.outer.location < selection.location && selection.location <= NSMaxRange($0.outer) }
        }
        return links.first { $0.outer.location <= selection.location && selection.location < NSMaxRange($0.outer) }
    }

    func applyLink(url: String?, label: String?, _ doc: SourceDocument, _ selection: NSRange) -> MarkdownSourceEdit? {
        let url = url.flatMap { $0.isEmpty ? nil : $0 }
        let selected = doc.string(selection)
        let link = activeLink(doc, selection)
        if let url {
            if selection.length > 0, let link, NSMaxRange(selection) <= NSMaxRange(link.outer) {
                return MarkdownSourceEdit(range: link.url, replacement: url, selection: link.text)
            }
            let text = selected.isEmpty ? (label ?? url) : selected
            return MarkdownSourceEdit.insertion("[\(text)](\(url))", replacing: selection)
        }
        if let link {
            let text = doc.string(link.text)
            let textLength = link.text.length
            let newSelection: NSRange
            if selection.length > 0 {
                newSelection = NSRange(location: link.outer.location, length: textLength)
            } else {
                let offset = min(max(selection.location - link.text.location, 0), textLength)
                newSelection = NSRange(location: link.outer.location + offset, length: 0)
            }
            return MarkdownSourceEdit(range: link.outer, replacement: text, selection: newSelection)
        }
        let href = Self.looksLikeURL(selected) ? selected : Self.urlPlaceholder
        let text = selected.isEmpty ? (label ?? Self.linkLabelPlaceholder) : selected
        let replacement = "[\(text)](\(href))"
        if href == Self.urlPlaceholder {
            let location = selection.location + (text as NSString).length + 3
            return MarkdownSourceEdit(
                range: selection,
                replacement: replacement,
                selection: NSRange(location: location, length: (href as NSString).length)
            )
        }
        return MarkdownSourceEdit.insertion(replacement, replacing: selection)
    }

    static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        if trimmed.lowercased().hasPrefix("www.") { return true }
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}
