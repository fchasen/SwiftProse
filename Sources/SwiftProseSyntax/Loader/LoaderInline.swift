import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct LoaderInline {
    let source: MarkdownSourceText
    var fallbackRuns = 0
    var projection = ""
    var breaklessProjection = ""
    private var lineContent: ((Int) -> String)?

    init(source: MarkdownSourceText) {
        self.source = source
    }

    mutating func build(
        _ runs: [LoaderRun],
        startByte: Int,
        endByte: Int? = nil,
        lineContent: ((Int) -> String)? = nil
    ) -> NSMutableAttributedString {
        self.lineContent = lineContent
        let out = NSMutableAttributedString()
        let cursor = append(runs, source: source, outerMarks: [], forcedLink: nil, cursor: startByte, allowReparse: true, into: out)
        if let endByte {
            Self.appendEmptyLinks(in: source, cursor..<max(cursor, endByte), intent: runs.last.map(Self.marks) ?? [], into: out)
        }
        return out
    }

    private static func marks(of run: LoaderRun) -> MarkdownInlineIntent {
        run.inline.intersection(.markdownMarks)
    }

    private static func appendEmptyLinks(
        in source: MarkdownSourceText,
        _ gap: Range<Int>,
        intent: MarkdownInlineIntent,
        into out: NSMutableAttributedString
    ) {
        for link in LinkTailScanner.emptyLinks(in: source.bytes, gap) {
            let text = source.string(link)
            let attachment = ChipAttachment.make(
                label: String(text.dropFirst(3).dropLast()),
                systemImage: "link",
                markdownSource: text,
                contentKind: AtomKind.emptyLink
            )
            out.append(atom(attachment, intent: intent, link: nil))
        }
    }

    @discardableResult
    private mutating func append(
        _ runs: [LoaderRun],
        source: MarkdownSourceText,
        outerMarks: MarkdownInlineIntent,
        forcedLink: URL?,
        cursor startCursor: Int,
        allowReparse: Bool,
        into out: NSMutableAttributedString
    ) -> Int {
        var cursor = startCursor
        var index = 0
        let presplit = Self.presplit(runs, source: source)
        while index < runs.count {
            let run = runs[index]
            let marks = run.inline.intersection(.markdownMarks).union(outerMarks)
            let link = forcedLink ?? run.link
            let byteRange = run.position.flatMap { source.byteRange($0) }
            if allowReparse, let byteRange, cursor < byteRange.lowerBound {
                let shared = index > 0 ? Self.marks(of: runs[index - 1]).intersection(marks) : marks
                Self.appendEmptyLinks(in: source, cursor..<byteRange.lowerBound, intent: shared, into: out)
            }
            projection += run.text
            if run.inline.isDisjoint(with: [.softBreak, .lineBreak]) { breaklessProjection += run.text }
            defer {
                if let byteRange { cursor = max(cursor, byteRange.upperBound) }
                index += 1
            }

            if !run.inline.isDisjoint(with: [.softBreak, .lineBreak]) {
                if allowReparse, byteRange == nil {
                    let lineEnd = source.lineByteRange(source.lineIndex(containingByte: cursor)).upperBound
                    if cursor < lineEnd {
                        Self.appendEmptyLinks(in: source, cursor..<lineEnd, intent: marks, into: out)
                        cursor = lineEnd
                    }
                }
                out.append(Self.breakPiece(intent: run.inline.contains(.softBreak) ? [.softBreak] : [], link: link))
                continue
            }
            if let imageURL = run.imageURL {
                if Self.isEmptyAltRun(run) {
                    for _ in run.text.unicodeScalars {
                        let imageSource = Self.imageSource(in: source, altRange: nil, cursor: cursor, url: imageURL, alt: "")
                        if let end = imageSource.end { cursor = max(cursor, end) }
                        out.append(Self.imageAtom(source: imageSource.text, alt: "", intent: marks, link: link))
                    }
                    continue
                }
                var alt = run.text
                var lastIndex = index
                var imageSource = Self.imageSource(in: source, altRange: byteRange, cursor: cursor, url: imageURL, alt: alt)
                while lastIndex + 1 < runs.count, runs[lastIndex + 1].imageURL == imageURL,
                      !runs[lastIndex + 1].inline.contains(.softBreak),
                      Self.continuesImage(runs[lastIndex + 1], endingAt: imageSource.end, in: source) {
                    lastIndex += 1
                    alt += runs[lastIndex].text
                    projection += runs[lastIndex].text
                }
                if imageSource.end == nil {
                    imageSource = Self.imageSource(in: source, altRange: byteRange, cursor: cursor, url: imageURL, alt: alt)
                }
                if let end = imageSource.end { cursor = max(cursor, end) }
                index = lastIndex
                out.append(Self.imageAtom(source: imageSource.text, alt: alt, intent: marks, link: link))
                continue
            }
            if run.inline.contains(.inlineHTML) {
                let span = byteRange.map { source.string($0) }
                let html = span == run.text ? span ?? run.text : run.text
                let attachment = ChipAttachment.make(
                    label: html,
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    markdownSource: html,
                    contentKind: AtomKind.inlineHTML
                )
                out.append(Self.atom(attachment, intent: marks, link: link))
                continue
            }
            if marks.contains(.code) {
                out.append(Self.piece(run.text, intent: marks, link: link))
                continue
            }
            if let pieces = presplit[index] {
                for piece in pieces {
                    switch piece {
                    case .text(let text):
                        out.append(Self.piece(text, intent: marks, link: link))
                    case .literal(let text, let literal):
                        out.append(Self.piece(text, intent: marks, link: link, literal: literal))
                    }
                }
                continue
            }
            let span = byteRange.map { source.string($0) }
            if link != nil, forcedLink == nil, allowReparse,
               let labelSpan = byteRange.map({ labelSource(Self.widenedOverBackticks($0, in: source.bytes)) }),
               labelSpan != run.text {
                let label = MarkdownSourceText(labelSpan)
                let spansLines = labelSpan.contains("\n")
                let options = spansLines ? MarkdownLoader.parsingOptions : Self.inlineOptions
                if let reparsed = try? AttributedString(markdown: labelSpan, options: options) {
                    let nested = NSMutableAttributedString()
                    var inner = LoaderInline(source: label)
                    inner.append(
                        LoaderRun.runs(of: reparsed),
                        source: label,
                        outerMarks: marks,
                        forcedLink: link,
                        cursor: 0,
                        allowReparse: false,
                        into: nested
                    )
                    let matches = spansLines ? inner.breaklessProjection == run.text : inner.projection == run.text
                    if matches, inner.fallbackRuns == 0 {
                        out.append(nested)
                        continue
                    }
                }
            }
            if let span, let pieces = SourceAligner.align(text: run.text, source: span) {
                for piece in pieces {
                    switch piece {
                    case .text(let text):
                        out.append(Self.piece(text, intent: marks, link: link))
                    case .literal(let text, let literal):
                        out.append(Self.piece(text, intent: marks, link: link, literal: literal))
                    }
                }
                continue
            }
            if let position = run.position,
               let pieces = Self.realign(
                   text: run.text,
                   position: position,
                   source: source,
                   followedByLink: index + 1 < runs.count && runs[index + 1].link != nil && link == nil
               ) {
                for piece in pieces {
                    switch piece {
                    case .text(let text):
                        out.append(Self.piece(text, intent: marks, link: link))
                    case .literal(let text, let literal):
                        out.append(Self.piece(text, intent: marks, link: link, literal: literal))
                    }
                }
                continue
            }
            if let link, forcedLink == nil, Self.isAutolinkText(run.text, url: link) {
                out.append(Self.piece(run.text, intent: marks, link: link))
                continue
            }
            fallbackRuns += 1
            #if DEBUG
            MarkdownLoader.logger.debug("Loader fell back to parsed text for run \(run.text, privacy: .public)")
            #endif
            out.append(Self.piece(run.text, intent: marks, link: link))
        }
        return cursor
    }

    private func labelSource(_ range: Range<Int>) -> String {
        let firstLine = source.lineIndex(containingByte: range.lowerBound)
        let lastLine = source.lineIndex(containingByte: max(range.lowerBound, range.upperBound - 1))
        guard lastLine > firstLine, let lineContent else { return source.string(range) }
        var lines = [source.string(range.lowerBound..<min(range.upperBound, source.lineByteRange(firstLine).upperBound))]
        for line in (firstLine + 1)...lastLine {
            let bounds = source.lineByteRange(line)
            let contentStart = bounds.upperBound - lineContent(line).utf8.count
            lines.append(source.string(contentStart..<max(contentStart, min(range.upperBound, bounds.upperBound))))
        }
        return lines.joined(separator: "\n")
    }

    static func widenedOverBackticks(_ range: Range<Int>, in bytes: [UInt8]) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower > 0, lower <= bytes.count, bytes[lower - 1] == UInt8(ascii: "`") { lower -= 1 }
        while upper >= 0, upper < bytes.count, bytes[upper] == UInt8(ascii: "`") { upper += 1 }
        return lower..<upper
    }

    static func isAutolinkText(_ text: String, url: URL) -> Bool {
        guard url.scheme != nil else { return false }
        let absolute = url.absoluteString
        return absolute == text || absolute == "http://" + text || absolute == "mailto:" + text
    }

    static func presplit(_ runs: [LoaderRun], source: MarkdownSourceText) -> [Int: [AlignedPiece]] {
        var result: [Int: [AlignedPiece]] = [:]
        var index = 0
        while index < runs.count {
            let start = index
            index += 1
            guard isGroupable(runs[start]),
                  let position = runs[start].position,
                  let range = source.byteRange(position)
            else { continue }
            var end = start + 1
            while end < runs.count, runs[end].position == nil, isGroupable(runs[end]) {
                end += 1
            }
            guard end > start + 1 else { continue }
            let members = Array(start..<end)
            let text = members.map { runs[$0].text }.joined()
            guard let pieces = SourceAligner.align(text: text, source: source.string(range)),
                  let segments = split(pieces, scalarCounts: members.map { runs[$0].text.unicodeScalars.count })
            else { continue }
            for (member, segment) in zip(members, segments) {
                result[member] = segment
            }
            index = end
        }
        return result
    }

    private static func isGroupable(_ run: LoaderRun) -> Bool {
        run.imageURL == nil && run.inline.isDisjoint(with: [.softBreak, .lineBreak, .inlineHTML, .code])
    }

    static func split(_ pieces: [AlignedPiece], scalarCounts: [Int]) -> [[AlignedPiece]]? {
        var segments: [[AlignedPiece]] = [[]]
        var remaining = scalarCounts.first ?? 0
        var countIndex = 0

        func advanceSegment() -> Bool {
            while remaining == 0, countIndex + 1 < scalarCounts.count {
                countIndex += 1
                remaining = scalarCounts[countIndex]
                segments.append([])
            }
            return remaining > 0
        }

        for piece in pieces {
            switch piece {
            case .literal(let text, _):
                guard advanceSegment() else { return nil }
                let count = text.unicodeScalars.count
                guard count <= remaining else { return nil }
                segments[segments.count - 1].append(piece)
                remaining -= count
            case .text(let text):
                var scalars = Substring(text).unicodeScalars[...]
                while !scalars.isEmpty {
                    guard advanceSegment() else { return nil }
                    let take = min(remaining, scalars.count)
                    let head = scalars.prefix(take)
                    segments[segments.count - 1].append(.text(String(String.UnicodeScalarView(head))))
                    scalars = scalars.dropFirst(take)
                    remaining -= take
                }
            }
        }
        while segments.count < scalarCounts.count { segments.append([]) }
        guard remaining == 0, segments.count == scalarCounts.count else { return nil }
        return segments
    }

    static func realign(
        text: String,
        position: AttributedString.MarkdownSourcePosition,
        source: MarkdownSourceText,
        followedByLink: Bool
    ) -> [AlignedPiece]? {
        if followedByLink, let range = source.byteRange(position),
           let pieces = SourceAligner.align(text: text, source: source.string(range), allowsTrailingSource: true) {
            return pieces
        }
        guard position.startLine == position.endLine, position.startLine <= source.lineCount else { return nil }
        let line = source.lineByteRange(position.startLine)
        let start = line.lowerBound + position.startColumn - 1
        let end = line.lowerBound + position.endColumn
        guard position.startColumn > 1 else { return nil }
        for shift in 1..<position.startColumn {
            let lower = start - shift
            let upper = end - shift
            guard lower >= line.lowerBound, upper <= line.upperBound, lower <= upper else { continue }
            if let pieces = SourceAligner.align(text: text, source: source.string(lower..<upper)) {
                return pieces
            }
        }
        return nil
    }

    static let inlineOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible,
        languageCode: nil,
        appliesSourcePositionAttributes: true
    )

    static func attributes(
        intent: MarkdownInlineIntent,
        link: URL?,
        literal: String? = nil
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        attributes.markdownInlineIntent = intent
        if let link { attributes[.link] = link }
        if let literal { attributes[.markdownLiteral] = literal }
        return attributes
    }

    static func piece(
        _ text: String,
        intent: MarkdownInlineIntent,
        link: URL?,
        literal: String? = nil
    ) -> NSAttributedString {
        if let literal {
            return NSAttributedString(
                string: SeparatorLiteral.storable(text),
                attributes: attributes(intent: intent, link: link, literal: literal)
            )
        }
        return SeparatorLiteral.substituting(text, attributes: attributes(intent: intent, link: link))
    }

    static func breakPiece(intent: MarkdownInlineIntent, link: URL?) -> NSAttributedString {
        NSAttributedString(string: MarkdownBreak.string, attributes: attributes(intent: intent, link: link))
    }

    static func atom(_ attachment: NSTextAttachment, intent: MarkdownInlineIntent, link: URL?) -> NSAttributedString {
        var attributes = attributes(intent: intent, link: link)
        attributes[.attachment] = attachment
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }

    private static func isEmptyAltRun(_ run: LoaderRun) -> Bool {
        run.position == nil && !run.text.isEmpty && run.text.unicodeScalars.allSatisfy { $0 == "\u{FFFC}" }
    }

    private static func continuesImage(_ run: LoaderRun, endingAt end: Int?, in source: MarkdownSourceText) -> Bool {
        if let range = run.position.flatMap({ source.byteRange($0) }) {
            return end.map { range.lowerBound < $0 } ?? true
        }
        return !isEmptyAltRun(run)
    }

    static func imageAtom(source: String, alt: String, intent: MarkdownInlineIntent, link: URL?) -> NSAttributedString {
        let label = alt.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFC}")).isEmpty ? "image" : alt
        let attachment = ChipAttachment.make(
            label: label,
            systemImage: "photo",
            markdownSource: source,
            contentKind: AtomKind.image
        )
        return atom(attachment, intent: intent, link: link)
    }

    static func imageSource(
        in source: MarkdownSourceText,
        altRange: Range<Int>?,
        cursor: Int,
        url: URL,
        alt: String
    ) -> (text: String, end: Int?) {
        let bytes = source.bytes
        var open: Int?
        if let altRange, altRange.lowerBound >= 2,
           bytes[altRange.lowerBound - 2] == UInt8(ascii: "!"),
           bytes[altRange.lowerBound - 1] == UInt8(ascii: "[") {
            open = altRange.lowerBound - 1
        } else {
            var k = max(0, cursor)
            while k + 1 < bytes.count {
                if bytes[k] == UInt8(ascii: "!"), bytes[k + 1] == UInt8(ascii: "[") {
                    open = k + 1
                    break
                }
                k += 1
            }
        }
        if let open, let end = LinkTailScanner.end(of: bytes, openBracket: open) {
            return (source.string((open - 1)..<end), end)
        }
        let cleanAlt = alt == "\u{FFFC}" ? "" : alt
        return ("![\(cleanAlt)](\(url.absoluteString))", nil)
    }
}

enum LinkTailScanner {
    static func end(of bytes: [UInt8], openBracket: Int) -> Int? {
        guard openBracket < bytes.count, bytes[openBracket] == UInt8(ascii: "[") else { return nil }
        var i = openBracket + 1
        var depth = 1
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\\") {
                i += 2
                continue
            }
            if c == UInt8(ascii: "`") {
                i = skipCodeSpan(bytes, at: i)
                continue
            }
            if c == UInt8(ascii: "[") { depth += 1 }
            if c == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { break }
            }
            i += 1
        }
        guard i < bytes.count else { return nil }
        let after = i + 1
        guard after < bytes.count else { return after }
        if bytes[after] == UInt8(ascii: "(") {
            return closingParen(bytes, open: after)
        }
        if bytes[after] == UInt8(ascii: "[") {
            var k = after + 1
            while k < bytes.count, bytes[k] != UInt8(ascii: "]") {
                if bytes[k] == UInt8(ascii: "\\") { k += 1 }
                k += 1
            }
            return k < bytes.count ? k + 1 : after
        }
        return after
    }

    static func emptyLinks(in bytes: [UInt8], _ range: Range<Int>) -> [Range<Int>] {
        var links: [Range<Int>] = []
        let upper = min(range.upperBound, bytes.count)
        var k = max(0, range.lowerBound)
        while k + 2 < upper {
            if bytes[k] == UInt8(ascii: "["), bytes[k + 1] == UInt8(ascii: "]"), bytes[k + 2] == UInt8(ascii: "("),
               k == 0 || (bytes[k - 1] != UInt8(ascii: "!") && bytes[k - 1] != UInt8(ascii: "\\")),
               let end = closingParen(bytes, open: k + 2), end <= upper {
                links.append(k..<end)
                k = end
                continue
            }
            if bytes[k] == UInt8(ascii: "]"), bytes[k + 1] == UInt8(ascii: "("), let end = closingParen(bytes, open: k + 1) {
                k = end
                continue
            }
            k += 1
        }
        return links
    }

    static func isEmptyLinkLine(_ line: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(line)
        let links = emptyLinks(in: bytes, 0..<bytes.count)
        guard !links.isEmpty else { return false }
        var k = 0
        for link in links {
            guard bytes[k..<link.lowerBound].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return false }
            k = link.upperBound
        }
        return bytes[k...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private static func closingParen(_ bytes: [UInt8], open: Int) -> Int? {
        var i = open + 1
        var depth = 1
        var quote: UInt8?
        var inAngle = false
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\\") {
                i += 2
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
            } else if inAngle {
                if c == UInt8(ascii: ">") { inAngle = false }
            } else if c == UInt8(ascii: "<"), i == open + 1 {
                inAngle = true
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'"),
                      [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n")].contains(bytes[i - 1]) {
                quote = c
            } else if c == UInt8(ascii: "(") {
                depth += 1
            } else if c == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return nil
    }

    private static func skipCodeSpan(_ bytes: [UInt8], at start: Int) -> Int {
        var k = start
        while k < bytes.count, bytes[k] == UInt8(ascii: "`") { k += 1 }
        let width = k - start
        var j = k
        while j < bytes.count {
            if bytes[j] == UInt8(ascii: "`") {
                var m = j
                while m < bytes.count, bytes[m] == UInt8(ascii: "`") { m += 1 }
                if m - j == width { return m }
                j = m
            } else {
                j += 1
            }
        }
        return k
    }
}
