import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct SourceLineSpan: Equatable {
    var range: NSRange
    var contentsEnd: Int

    var content: NSRange { NSRange(location: range.location, length: contentsEnd - range.location) }
    var next: Int { NSMaxRange(range) }

    static func at(_ location: Int, in ns: NSString) -> SourceLineSpan {
        var start = 0
        var end = 0
        var contentsEnd = 0
        ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return SourceLineSpan(range: NSRange(location: start, length: end - start), contentsEnd: contentsEnd)
    }
}

final class SourceStyler {
    struct Pass: Equatable {
        var restyled: NSRange
        var lines: [NSRange]
        var structureChanged: Bool
    }

    var theme: ProseTheme {
        didSet { fonts = Fonts(theme.monospaceFont) }
    }

    var preservesCodeForeground = false
    private(set) var lastPass = Pass(restyled: NSRange(location: 0, length: 0), lines: [], structureChanged: false)
    private var fonts: Fonts
    private var lookaheads: [Int: SourceLineState.Lookahead] = [:]

    private struct Fonts {
        let regular: PlatformFont
        let bold: PlatformFont
        let italic: PlatformFont
        let boldItalic: PlatformFont

        init(_ base: PlatformFont) {
            regular = base
            bold = base.withFontTraits(.bold)
            italic = base.withFontTraits(.italic)
            boldItalic = base.withFontTraits([.bold, .italic])
        }

        func font(bold isBold: Bool, italic isItalic: Bool) -> PlatformFont {
            switch (isBold, isItalic) {
            case (true, true): return boldItalic
            case (true, false): return bold
            case (false, true): return italic
            case (false, false): return regular
            }
        }
    }

    init(theme: ProseTheme) {
        self.theme = theme
        self.fonts = Fonts(theme.monospaceFont)
    }

    var codeBaseColor: PlatformColor {
        theme.codeBlock.textColor ?? theme.foregroundColor
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: fonts.regular, .foregroundColor: theme.foregroundColor, .paragraphStyle: theme.defaultParagraphStyle()]
    }

    func styleAll(_ storage: NSMutableAttributedString) {
        lookaheads.removeAll()
        defer { lookaheads.removeAll() }
        let ns = storage.string as NSString
        let total = ns.length
        var lines: [NSRange] = []
        var entry = SourceLineState.initial
        var location = 0
        while location < total {
            let line = SourceLineSpan.at(location, in: ns)
            entry = style(storage, ns, line, entry: entry, previous: storedState(storage, line)).state
            lines.append(line.range)
            location = line.next
        }
        lastPass = Pass(restyled: NSRange(location: 0, length: total), lines: lines, structureChanged: true)
    }

    func restyle(_ storage: NSMutableAttributedString, editedRange: NSRange) -> Pass {
        lookaheads.removeAll()
        defer { lookaheads.removeAll() }
        let ns = storage.string as NSString
        let total = ns.length
        guard total > 0 else {
            lastPass = Pass(restyled: NSRange(location: 0, length: 0), lines: [], structureChanged: false)
            return lastPass
        }
        let edited = Normalizer.clamp(editedRange, to: total)
        let first = SourceLineSpan.at(min(edited.location, total - 1), in: ns)
        var styled: [NSRange] = []
        var structureChanged = false
        styleForward(storage, ns, from: first, through: NSMaxRange(edited), styled: &styled, structureChanged: &structureChanged)
        if let earliest = earliestStaleLookahead(storage, ns, before: first) {
            let last = SourceLineSpan.at(first.range.location - 1, in: ns)
            styleForward(storage, ns, from: earliest, through: last.contentsEnd, styled: &styled, structureChanged: &structureChanged)
        }
        var seen = Set<Int>()
        let lines = styled.sorted { $0.location < $1.location }.filter { seen.insert($0.location).inserted }
        let restyled = lines.dropFirst().reduce(lines[0]) { NSUnionRange($0, $1) }
        lastPass = Pass(restyled: restyled, lines: lines, structureChanged: structureChanged)
        return lastPass
    }

    private func styleForward(
        _ storage: NSMutableAttributedString,
        _ ns: NSString,
        from start: SourceLineSpan,
        through limit: Int,
        styled: inout [NSRange],
        structureChanged: inout Bool
    ) {
        let total = ns.length
        var entry = start.range.location > 0 ? (storedState(storage, at: start.range.location - 1) ?? .initial) : .initial
        var line = start
        while true {
            let previous = storedState(storage, line)
            let result = style(storage, ns, line, entry: entry, previous: previous)
            structureChanged = structureChanged || result.codeChanged
            styled.append(line.range)
            entry = result.state
            guard line.next < total else { break }
            if line.contentsEnd >= limit, let previous, previous.carriesSameExit(as: result.state) {
                break
            }
            line = SourceLineSpan.at(line.next, in: ns)
        }
    }

    private func earliestStaleLookahead(_ storage: NSAttributedString, _ ns: NSString, before first: SourceLineSpan) -> SourceLineSpan? {
        var earliest: SourceLineSpan?
        var after = first
        while after.range.location > 0 {
            let line = SourceLineSpan.at(after.range.location - 1, in: ns)
            guard let stored = storedState(storage, line), stored.paragraph else { break }
            let paragraph = ParagraphLine(span: line, prefix: SourceDocument.parsePrefix(ns, line.content), listColumn: stored.listColumn)
            let value: SourceLineState.Lookahead
            switch step(ns, paragraph, next: after) {
            case .terminal(let result):
                value = result
            case .continues(let following):
                value = combine(ns, following, lookaheads[after.range.location] ?? lookahead(ns, for: following))
            }
            guard value != stored.lookahead else { break }
            lookaheads[line.range.location] = value
            earliest = line
            after = line
        }
        return earliest
    }

    private func storedState(_ storage: NSAttributedString, _ line: SourceLineSpan) -> SourceLineState? {
        guard line.range.length > 0 else { return nil }
        return storedState(storage, at: NSMaxRange(line.range) - 1)
    }

    private func storedState(_ storage: NSAttributedString, at index: Int) -> SourceLineState? {
        guard index >= 0, index < storage.length else { return nil }
        return storage.attribute(.markdownSourceLineState, at: index, effectiveRange: nil) as? SourceLineState
    }

    private struct LineResult {
        var state: SourceLineState
        var codeChanged: Bool
    }

    private struct Painter {
        let storage: NSMutableAttributedString

        func color(_ color: PlatformColor, _ range: NSRange) {
            guard range.length > 0 else { return }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    private func style(
        _ storage: NSMutableAttributedString,
        _ ns: NSString,
        _ line: SourceLineSpan,
        entry: SourceLineState,
        previous: SourceLineState?
    ) -> LineResult {
        let full = line.range
        let content = line.content
        let oldCode = full.length > 0 ? storage.markdownBlock(at: full.location) : nil
        let classified = classify(ns, line, entry: entry, previous: previous)
        guard full.length > 0 else {
            return LineResult(state: classified.state, codeChanged: false)
        }
        let painter = Painter(storage: storage)
        let source = theme.source
        let isCodeContent = classified.code != nil
        var base = baseAttributes
        if classified.quoted { base[.foregroundColor] = source.quoteColor }
        if isCodeContent {
            base[.foregroundColor] = codeBaseColor
            if preservesCodeForeground, oldCode?.isCode == true { base.removeValue(forKey: .foregroundColor) }
        }
        storage.removeAttribute(.strikethroughStyle, range: full)
        storage.removeAttribute(.markdownInlineIntent, range: full)
        storage.removeAttribute(.markdownBlock, range: full)
        storage.removeAttribute(.markdownCodePrefix, range: full)
        storage.addAttributes(base, range: full)
        storage.addAttribute(.markdownSourceLineState, value: classified.state, range: full)
        if let code = classified.code {
            storage.addAttribute(.markdownBlock, value: MarkdownBlock(leaf: .code(language: code.info, group: code.group)), range: full)
            if classified.contentStart > full.location {
                storage.addAttribute(
                    .markdownCodePrefix,
                    value: true,
                    range: NSRange(location: full.location, length: classified.contentStart - full.location)
                )
            }
        }
        for marker in classified.markers { painter.color(source.syntaxColor, marker) }
        switch classified.kind {
        case .blank, .codeContent:
            break
        case .fence(let info):
            painter.color(source.syntaxColor, NSRange(location: classified.contentStart, length: line.contentsEnd - classified.contentStart))
            if let info { painter.color(theme.codeBlock.languageTagColor, info) }
        case .html:
            painter.color(source.htmlColor, content)
        case .syntaxLine:
            painter.color(source.syntaxColor, content)
        case .referenceDefinition(let label, let url):
            painter.color(source.syntaxColor, content)
            painter.color(theme.linkColor, label)
            painter.color(source.urlColor, url)
        case .heading(let marker, let closing, let inline, let scan):
            painter.color(source.headingColor, inline)
            painter.color(source.syntaxColor, marker)
            if let closing { painter.color(source.syntaxColor, closing) }
            styleInline(storage, inline, heading: true, tokens: scan.tokens)
        case .paragraph(let inline, let heading, let scan):
            if heading { painter.color(source.headingColor, inline) }
            styleInline(storage, inline, heading: heading, tokens: scan.tokens)
        }
        let newCode = classified.code
        let codeChanged = oldCode?.codeGroup != newCode?.group || (newCode != nil && oldCode?.codeLanguage != newCode?.info)
        return LineResult(state: classified.state, codeChanged: codeChanged)
    }

    private func scanInline(
        _ ns: NSString,
        _ range: NSRange,
        pipes: Bool,
        openingCodeSpan: Int = 0,
        laterRuns: UInt64 = 0
    ) -> SourceInlineScan {
        guard range.length > 0 else { return SourceInlineScan(tokens: [], openCodeSpan: openingCodeSpan) }
        let line = ns.substring(with: range) as NSString
        return SourceInlineScanner.scanLine(
            line,
            range: NSRange(location: 0, length: line.length),
            stylesPipes: pipes,
            openingCodeSpan: openingCodeSpan,
            laterRuns: laterRuns
        )
    }

    private func styleInline(_ storage: NSMutableAttributedString, _ range: NSRange, heading: Bool, tokens: [SourceInlineToken]) {
        guard range.length > 0 else { return }
        var bold = [Bool](repeating: heading, count: range.length)
        var italic = [Bool](repeating: false, count: range.length)
        let source = theme.source
        for token in tokens {
            let global = NSRange(location: range.location + token.range.location, length: token.range.length)
            switch token.kind {
            case .linkText:
                storage.addAttribute(.foregroundColor, value: theme.linkColor, range: global)
            case .strong:
                for i in token.range.location..<NSMaxRange(token.range) { bold[i] = true }
            case .emphasis:
                for i in token.range.location..<NSMaxRange(token.range) { italic[i] = true }
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: global)
            case .code:
                storage.addAttribute(.foregroundColor, value: source.codeColor, range: global)
                storage.addAttribute(.markdownInlineIntent, value: MarkdownInlineIntent.code.attributeValue, range: global)
            case .url:
                storage.addAttribute(.foregroundColor, value: source.urlColor, range: global)
            case .html:
                storage.addAttribute(.foregroundColor, value: source.htmlColor, range: global)
            case .syntax:
                storage.addAttribute(.foregroundColor, value: source.syntaxColor, range: global)
            }
        }
        var runStart = 0
        while runStart < range.length {
            var runEnd = runStart + 1
            while runEnd < range.length, bold[runEnd] == bold[runStart], italic[runEnd] == italic[runStart] { runEnd += 1 }
            if bold[runStart] || italic[runStart] {
                storage.addAttribute(
                    .font,
                    value: fonts.font(bold: bold[runStart], italic: italic[runStart]),
                    range: NSRange(location: range.location + runStart, length: runEnd - runStart)
                )
            }
            runStart = runEnd
        }
    }

    enum LineKind: Equatable {
        case blank
        case codeContent
        case fence(info: NSRange?)
        case html
        case syntaxLine
        case referenceDefinition(label: NSRange, url: NSRange)
        case heading(marker: NSRange, closing: NSRange?, inline: NSRange, scan: SourceInlineScan)
        case paragraph(inline: NSRange, heading: Bool, scan: SourceInlineScan)
    }

    struct Classification {
        var kind: LineKind
        var state: SourceLineState
        var markers: [NSRange] = []
        var quoted = false
        var contentStart: Int
        var code: (group: GroupToken, info: String?)?
    }

    func classify(
        _ ns: NSString,
        _ line: SourceLineSpan,
        entry: SourceLineState,
        previous: SourceLineState?
    ) -> Classification {
        let content = line.content
        let blank = SourceDocument.isBlank(ns, content)
        switch entry.block {
        case .fence(let fence):
            let sourceLine = SourceLine(range: content, prefix: SourceDocument.parsePrefix(ns, content), isBlank: blank)
            let prefix = sourceLine.prefix
            let leavesQuote = prefix.quoteDepth < fence.quoteDepth
            let leavesList = !blank && fence.listColumn > 0 && prefix.quoteDepth == fence.quoteDepth && prefix.indent < fence.listColumn
            if leavesQuote || leavesList {
                return classify(ns, line, entry: .initial, previous: previous)
            }
            if let run = SourceDocument.fenceRun(ns, sourceLine), run.char == fence.marker, run.length >= fence.length,
               SourceDocument.isBlank(ns, NSRange(location: run.end, length: line.contentsEnd - run.end)) {
                let state = SourceLineState(listColumn: fence.listColumn)
                let markers = quoteMarkers(ns, NSRange(location: content.location, length: prefix.quoteEnd))
                return Classification(kind: .fence(info: nil), state: state, markers: markers, contentStart: run.end - run.length)
            }
            let codeStart = Self.codeContentStart(ns, content, quoteDepth: fence.quoteDepth, indent: fence.indent)
            return Classification(
                kind: .codeContent,
                state: SourceLineState(block: .fence(fence), listColumn: fence.listColumn),
                markers: quoteMarkers(ns, NSRange(location: content.location, length: codeStart - content.location)),
                contentStart: codeStart,
                code: (fence.group, fence.info)
            )
        case .html(let end):
            if end == .blankLine, blank {
                return Classification(kind: .blank, state: SourceLineState(listColumn: entry.listColumn), contentStart: content.location)
            }
            let closes = end.isSatisfied(by: ns.substring(with: content))
            let state = closes ? SourceLineState(listColumn: entry.listColumn) : SourceLineState(block: .html(end), listColumn: entry.listColumn)
            return Classification(kind: .html, state: state, contentStart: content.location)
        case .none, .indented:
            break
        }

        if blank {
            return Classification(kind: .blank, state: SourceLineState(listColumn: entry.listColumn), contentStart: content.location)
        }

        let prefix = SourceDocument.parsePrefix(ns, content)
        let base = content.location
        let quoted = prefix.quoteEnd > 0
        var markers = quoteMarkers(ns, NSRange(location: base, length: prefix.quoteEnd))
        let listColumn: Int
        if prefix.marker != nil {
            listColumn = prefix.markerEnd - prefix.quoteEnd
        } else if entry.inList, prefix.indent > 0 || (entry.paragraph && prefix.quoteDepth <= entry.quoteDepth) {
            listColumn = entry.listColumn
        } else {
            listColumn = 0
        }

        if prefix.indent >= 4, !quoted, !entry.paragraph, !entry.inList {
            let group = entry.indentedGroup ?? previous?.indentedGroup ?? GroupToken.mint()
            return Classification(
                kind: .codeContent,
                state: SourceLineState(block: .indented(group)),
                contentStart: Self.codeContentStart(ns, content, quoteDepth: 0, indent: 4),
                code: (group, nil)
            )
        }

        let fenceStart = base + prefix.markerEnd
        if prefix.indent <= 3 || prefix.marker != nil || entry.inList,
           let open = fenceOpen(ns, at: fenceStart, end: line.contentsEnd) {
            if prefix.marker != nil {
                markers.append(NSRange(location: base + prefix.indentEnd, length: prefix.markerEnd - prefix.indentEnd))
            }
            let fence = SourceFenceBlock(
                marker: open.marker,
                length: open.length,
                group: previous?.fenceGroup ?? GroupToken.mint(),
                info: open.info,
                quoteDepth: prefix.quoteDepth,
                indent: prefix.markerEnd - prefix.quoteEnd,
                listColumn: listColumn
            )
            let state = SourceLineState(block: .fence(fence), listColumn: listColumn)
            return Classification(kind: .fence(info: open.infoRange), state: state, markers: markers, quoted: quoted, contentStart: fenceStart)
        }

        if prefix.indent <= 3, prefix.marker == nil,
           let end = htmlBlockStart(ns, at: base + prefix.indentEnd, end: line.contentsEnd, interruptsParagraph: entry.paragraph) {
            let rest = ns.substring(with: NSRange(location: base + prefix.indentEnd, length: line.contentsEnd - base - prefix.indentEnd))
            let closes = end != .blankLine && end.isSatisfied(by: rest)
            let state = closes ? SourceLineState(listColumn: listColumn) : SourceLineState(block: .html(end), listColumn: listColumn)
            return Classification(kind: .html, state: state, markers: markers, quoted: quoted, contentStart: base + prefix.indentEnd)
        }

        if entry.paragraph, let start = Self.containerStart(content, prefix, quoteDepth: entry.quoteDepth, listColumn: entry.listColumn) {
            let rest = ns.substring(with: NSRange(location: start, length: line.contentsEnd - start))
            if entry.pipes, Self.isDelimiterRow(rest) {
                let state = SourceLineState(inTable: true, quoteDepth: entry.quoteDepth, listColumn: listColumn)
                return Classification(kind: .syntaxLine, state: state, markers: markers, quoted: quoted, contentStart: start)
            }
            if Self.setextLevel(rest) != nil {
                return Classification(kind: .syntaxLine, state: SourceLineState(listColumn: listColumn), markers: markers, quoted: quoted, contentStart: start)
            }
        }

        if prefix.marker == nil,
           SourceDocument.isThematicBreak(ns, NSRange(location: base + prefix.quoteEnd, length: line.contentsEnd - base - prefix.quoteEnd)) {
            return Classification(kind: .syntaxLine, state: SourceLineState(listColumn: listColumn), markers: markers, quoted: quoted, contentStart: base + prefix.quoteEnd)
        }

        if !entry.paragraph, !quoted, prefix.marker == nil,
           let definition = Self.referenceDefinition(ns, content) {
            return Classification(
                kind: .referenceDefinition(label: definition.label, url: definition.url),
                state: SourceLineState(listColumn: listColumn),
                contentStart: base
            )
        }

        if prefix.marker != nil {
            markers.append(NSRange(location: base + prefix.indentEnd, length: prefix.markerEnd - prefix.indentEnd))
        }
        if prefix.task != nil {
            markers.append(NSRange(location: base + prefix.markerEnd, length: prefix.taskEnd - prefix.markerEnd))
        }

        if let level = prefix.heading {
            let marker = NSRange(location: base + prefix.taskEnd, length: level)
            let inlineStart = base + prefix.contentStart
            var inlineEnd = line.contentsEnd
            let closing = Self.closingHeadingSequence(ns, start: inlineStart, end: inlineEnd)
            if let closing { inlineEnd = closing.location }
            let inline = NSRange(location: inlineStart, length: inlineEnd - inlineStart)
            return Classification(
                kind: .heading(marker: marker, closing: closing, inline: inline, scan: scanInline(ns, inline, pipes: false)),
                state: SourceLineState(listColumn: listColumn),
                markers: markers,
                quoted: quoted,
                contentStart: inlineStart
            )
        }

        let inlineStart = base + prefix.contentStart
        let inline = NSRange(location: inlineStart, length: line.contentsEnd - inlineStart)
        if entry.inTable, Self.containerStart(content, prefix, quoteDepth: entry.quoteDepth, listColumn: entry.listColumn) != nil {
            return Classification(
                kind: .paragraph(inline: inline, heading: false, scan: scanInline(ns, inline, pipes: true)),
                state: SourceLineState(inTable: true, quoteDepth: entry.quoteDepth, listColumn: listColumn),
                markers: markers,
                quoted: quoted,
                contentStart: inlineStart
            )
        }
        let paragraph = ParagraphLine(span: line, prefix: prefix, listColumn: listColumn)
        let ahead = lookahead(ns, for: paragraph)
        let continuesSpan = entry.paragraph && prefix.marker == nil && prefix.quoteDepth <= entry.quoteDepth
        let scan = scanInline(
            ns,
            inline,
            pipes: ahead.heading == .tableHeader,
            openingCodeSpan: continuesSpan ? entry.codeSpan : 0,
            laterRuns: ahead.laterRuns
        )
        let state = SourceLineState(
            paragraph: true,
            pipes: Self.containsPipe(ns, inline),
            quoteDepth: prefix.quoteDepth,
            listColumn: listColumn,
            codeSpan: scan.openCodeSpan,
            lookahead: ahead
        )
        var heading = false
        if case .setext = ahead.heading { heading = true }
        return Classification(
            kind: .paragraph(inline: inline, heading: heading, scan: scan),
            state: state,
            markers: markers,
            quoted: quoted,
            contentStart: inlineStart
        )
    }

    private struct ParagraphLine {
        var span: SourceLineSpan
        var prefix: SourceLinePrefix
        var listColumn: Int

        var inline: NSRange {
            let start = span.content.location + prefix.contentStart
            return NSRange(location: start, length: span.contentsEnd - start)
        }
    }

    private enum Step {
        case terminal(SourceLineState.Lookahead)
        case continues(ParagraphLine)
    }

    private func step(_ ns: NSString, _ line: ParagraphLine, next: SourceLineSpan) -> Step {
        let content = next.content
        guard content.length > 0, !SourceDocument.isBlank(ns, content) else { return .terminal(.none) }
        let prefix = SourceDocument.parsePrefix(ns, content)
        if let start = Self.containerStart(content, prefix, quoteDepth: line.prefix.quoteDepth, listColumn: line.listColumn) {
            let rest = ns.substring(with: NSRange(location: start, length: next.contentsEnd - start))
            if Self.containsPipe(ns, line.inline), Self.isDelimiterRow(rest) {
                return .terminal(SourceLineState.Lookahead(heading: .tableHeader))
            }
            if let level = Self.setextLevel(rest) {
                return .terminal(SourceLineState.Lookahead(heading: .setext(level)))
            }
        }
        guard continuesParagraph(ns, next, prefix, quoteDepth: line.prefix.quoteDepth, inList: line.listColumn > 0) else {
            return .terminal(.none)
        }
        return .continues(ParagraphLine(span: next, prefix: prefix, listColumn: line.listColumn))
    }

    private func continuesParagraph(_ ns: NSString, _ line: SourceLineSpan, _ prefix: SourceLinePrefix, quoteDepth: Int, inList: Bool) -> Bool {
        let base = line.content.location
        if prefix.quoteDepth > quoteDepth || prefix.marker != nil || prefix.heading != nil { return false }
        if prefix.indent <= 3 || inList, fenceOpen(ns, at: base + prefix.markerEnd, end: line.contentsEnd) != nil { return false }
        if prefix.indent <= 3,
           htmlBlockStart(ns, at: base + prefix.indentEnd, end: line.contentsEnd, interruptsParagraph: true) != nil {
            return false
        }
        return !SourceDocument.isThematicBreak(ns, NSRange(location: base + prefix.quoteEnd, length: line.contentsEnd - base - prefix.quoteEnd))
    }

    private func combine(_ ns: NSString, _ next: ParagraphLine, _ value: SourceLineState.Lookahead) -> SourceLineState.Lookahead {
        if value.heading == .tableHeader { return .none }
        return SourceLineState.Lookahead(
            heading: value.heading,
            laterRuns: value.laterRuns | SourceInlineScanner.backtickRuns(in: ns, range: next.inline)
        )
    }

    private func lookahead(_ ns: NSString, for line: ParagraphLine) -> SourceLineState.Lookahead {
        if let known = lookaheads[line.span.range.location] { return known }
        var chain = [line]
        var value = SourceLineState.Lookahead.none
        scanning: while true {
            let current = chain[chain.count - 1]
            guard current.span.next < ns.length else { break }
            let next = SourceLineSpan.at(current.span.next, in: ns)
            switch step(ns, current, next: next) {
            case .terminal(let result):
                value = result
                break scanning
            case .continues(let following):
                if let known = lookaheads[next.range.location] {
                    value = combine(ns, following, known)
                    break scanning
                }
                chain.append(following)
            }
        }
        lookaheads[chain[chain.count - 1].span.range.location] = value
        for index in stride(from: chain.count - 2, through: 0, by: -1) {
            value = combine(ns, chain[index + 1], value)
            lookaheads[chain[index].span.range.location] = value
        }
        return value
    }

    static func containerStart(_ content: NSRange, _ prefix: SourceLinePrefix, quoteDepth: Int, listColumn: Int) -> Int? {
        guard prefix.quoteDepth == quoteDepth, prefix.marker == nil, prefix.indent >= listColumn else { return nil }
        return content.location + prefix.quoteEnd + listColumn
    }

    static func codeContentStart(_ ns: NSString, _ content: NSRange, quoteDepth: Int, indent: Int) -> Int {
        let end = NSMaxRange(content)
        var pos = content.location
        var depth = 0
        while depth < quoteDepth {
            var probe = pos
            var spaces = 0
            while spaces < 3, probe < end, ns.character(at: probe) == 0x20 { probe += 1; spaces += 1 }
            guard probe < end, ns.character(at: probe) == 0x3E else { break }
            probe += 1
            if probe < end, ns.character(at: probe) == 0x20 { probe += 1 }
            pos = probe
            depth += 1
        }
        var column = 0
        while column < indent, pos < end {
            let c = ns.character(at: pos)
            if c == 0x20 {
                column += 1
            } else if c == 0x09 {
                column += 4 - column % 4
            } else {
                break
            }
            pos += 1
        }
        return pos
    }

    private func quoteMarkers(_ ns: NSString, _ range: NSRange) -> [NSRange] {
        var markers: [NSRange] = []
        for i in range.location..<NSMaxRange(range) where ns.character(at: i) == 0x3E {
            markers.append(NSRange(location: i, length: 1))
        }
        return markers
    }

    private struct FenceOpen {
        var marker: unichar
        var length: Int
        var info: String?
        var infoRange: NSRange?
    }

    private func fenceOpen(_ ns: NSString, at start: Int, end: Int) -> FenceOpen? {
        guard start < end else { return nil }
        let c = ns.character(at: start)
        guard c == 0x60 || c == 0x7E else { return nil }
        var run = start
        while run < end, ns.character(at: run) == c { run += 1 }
        guard run - start >= 3 else { return nil }
        let infoText = ns.substring(with: NSRange(location: run, length: end - run))
        if c == 0x60, infoText.contains("`") { return nil }
        var infoStart = run
        while infoStart < end, SourceDocument.isSpace(ns.character(at: infoStart)) { infoStart += 1 }
        var infoEnd = end
        while infoEnd > infoStart, SourceDocument.isSpace(ns.character(at: infoEnd - 1)) { infoEnd -= 1 }
        let infoRange = infoEnd > infoStart ? NSRange(location: infoStart, length: infoEnd - infoStart) : nil
        return FenceOpen(
            marker: c,
            length: run - start,
            info: infoRange.map { ns.substring(with: $0) },
            infoRange: infoRange
        )
    }

    private static let rawTextStart = try! NSRegularExpression(pattern: #"^<(?:script|pre|style|textarea)(?:\s|>|$)"#, options: .caseInsensitive)
    private static let blockTags = "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul"
    private static let blockTagStart = try! NSRegularExpression(pattern: "^</?(?:\(blockTags))(?:\\s|/?>|$)", options: .caseInsensitive)
    private static let completeTag = try! NSRegularExpression(
        pattern: #"^(?:<[A-Za-z][A-Za-z0-9\-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:\-]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*/?>|</[A-Za-z][A-Za-z0-9\-]*\s*>)\s*$"#
    )

    private func htmlBlockStart(_ ns: NSString, at start: Int, end: Int, interruptsParagraph: Bool) -> SourceHTMLEnd? {
        guard start < end, ns.character(at: start) == 0x3C else { return nil }
        let rest = ns.substring(with: NSRange(location: start, length: end - start))
        let full = NSRange(location: 0, length: (rest as NSString).length)
        if Self.rawTextStart.firstMatch(in: rest, range: full) != nil { return .rawText }
        if rest.hasPrefix("<!--") { return .comment }
        if rest.hasPrefix("<?") { return .processingInstruction }
        if rest.hasPrefix("<![CDATA[") { return .cdata }
        if rest.count > 2, rest.hasPrefix("<!"), rest.dropFirst(2).first?.isLetter == true { return .declaration }
        if Self.blockTagStart.firstMatch(in: rest, range: full) != nil { return .blankLine }
        if !interruptsParagraph, Self.completeTag.firstMatch(in: rest, range: full) != nil { return .blankLine }
        return nil
    }

    private static let delimiterRow = try! NSRegularExpression(pattern: #"^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    private static let setextUnderline = try! NSRegularExpression(pattern: #"^ {0,3}(=+|-+)[ \t]*$"#)
    private static let reference = try! NSRegularExpression(
        pattern: #"^ {0,3}\[((?:[^\]\\]|\\.)+)\]:[ \t]*(<[^>]*>|\S+)(?:[ \t]+(?:"[^"]*"|'[^']*'|\([^)]*\)))?[ \t]*$"#
    )

    static func isDelimiterRow(_ text: String) -> Bool {
        guard text.contains("|") else { return false }
        return delimiterRow.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func setextLevel(_ text: String) -> Int? {
        guard let match = setextUnderline.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        return (text as NSString).substring(with: match.range(at: 1)).hasPrefix("=") ? 1 : 2
    }

    static func containsPipe(_ ns: NSString, _ range: NSRange) -> Bool {
        var i = range.location
        while i < NSMaxRange(range) {
            let c = ns.character(at: i)
            if c == 0x5C {
                i += 2
                continue
            }
            if c == 0x7C { return true }
            i += 1
        }
        return false
    }

    static func referenceDefinition(_ ns: NSString, _ content: NSRange) -> (label: NSRange, url: NSRange)? {
        let text = ns.substring(with: content)
        guard let match = reference.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        let label = match.range(at: 1)
        let url = match.range(at: 2)
        return (
            NSRange(location: content.location + label.location, length: label.length),
            NSRange(location: content.location + url.location, length: url.length)
        )
    }

    static func closingHeadingSequence(_ ns: NSString, start: Int, end: Int) -> NSRange? {
        var trimmed = end
        while trimmed > start, SourceDocument.isSpace(ns.character(at: trimmed - 1)) { trimmed -= 1 }
        var hashes = trimmed
        while hashes > start, ns.character(at: hashes - 1) == 0x23 { hashes -= 1 }
        guard hashes < trimmed else { return nil }
        if hashes == start { return NSRange(location: hashes, length: end - hashes) }
        guard SourceDocument.isSpace(ns.character(at: hashes - 1)) else { return nil }
        return NSRange(location: hashes, length: end - hashes)
    }
}
