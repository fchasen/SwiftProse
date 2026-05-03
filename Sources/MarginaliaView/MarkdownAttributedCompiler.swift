import Foundation
import MarginaliaSyntax
import MarginaliaRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class MarkdownAttributedCompiler {

    public typealias Dialect = MarginaliaView.Dialect

    private let blockParser: MarkdownParser
    private let inlineParser: MarkdownParser
    private let highlighter: HighlightApplier

    public init() throws {
        self.blockParser = try MarkdownParser(grammar: .block)
        self.inlineParser = try MarkdownParser(grammar: .inline)
        self.highlighter = try HighlightApplier()
    }

    public func compile(
        _ markdown: String,
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSAttributedString {
        switch mode {
        case .source: return compileSource(markdown, dialect: dialect, theme: theme)
        case .rich: return compileRich(markdown, dialect: dialect, theme: theme)
        }
    }

    // MARK: - source mode

    private func compileSource(
        _ markdown: String,
        dialect: Dialect,
        theme: MarginaliaTheme
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: markdown,
            attributes: [
                .font: theme.monospaceFont,
                .foregroundColor: theme.foregroundColor
            ]
        )
        let highlights = parseAndHighlight(markdown)
        for span in highlights {
            switch span.tag {
            case .punctuationSpecial, .punctuationDelimiter:
                result.addAttribute(.foregroundColor, value: theme.markupColor, range: span.range)
            case .textTitle:
                result.addAttribute(.foregroundColor, value: theme.linkColor, range: span.range)
            case .textURI:
                result.addAttribute(.foregroundColor, value: theme.linkURLColor, range: span.range)
            case .textReference:
                result.addAttribute(.foregroundColor, value: theme.linkColor, range: span.range)
            case .textLiteral, .stringEscape, .textEmphasis, .textStrong, .none, .unknown:
                break
            }
        }
        return result
    }

    // MARK: - rich mode

    private func compileRich(
        _ markdown: String,
        dialect: Dialect,
        theme: MarginaliaTheme
    ) -> NSAttributedString {
        guard !markdown.isEmpty else {
            return NSAttributedString(string: "", attributes: baseAttributes(theme: theme))
        }
        // No-op marker — appendStyled at each segment site applies BlockSpec.

        guard let blockTree = blockParser.parse(markdown),
              let blockRoot = blockTree.rootNode else {
            return NSAttributedString(string: markdown, attributes: baseAttributes(theme: theme))
        }
        let blockMapping = blockParser.mapping
        let segments = BlockSegmenter.segment(rootNode: blockRoot, mapping: blockMapping)

        let blockHighlights = highlighter.highlights(
            rootNode: blockRoot, in: blockTree, mapping: blockMapping, grammar: .block
        )

        let inlineTree = inlineParser.parse(markdown)
        let inlineMapping = inlineParser.mapping
        let inlineHighlights: [HighlightSpan]
        if let inlineRoot = inlineTree?.rootNode, let it = inlineTree {
            inlineHighlights = highlighter.highlights(
                rootNode: inlineRoot, in: it, mapping: inlineMapping, grammar: .inline
            )
        } else {
            inlineHighlights = []
        }

        let result = NSMutableAttributedString()
        var lastEmittedEnd: Int = 0
        for segment in segments {
            // Bridge unsegmented gaps (e.g. blank lines between blocks).
            if segment.range.location > lastEmittedEnd {
                let gapRange = NSRange(location: lastEmittedEnd, length: segment.range.location - lastEmittedEnd)
                appendVerbatim(in: gapRange, source: markdown, theme: theme, into: result)
            }
            appendSegment(
                segment,
                source: markdown,
                blockHighlights: blockHighlights,
                inlineHighlights: inlineHighlights,
                theme: theme,
                dialect: dialect,
                into: result
            )
            lastEmittedEnd = segment.range.location + segment.range.length
        }
        // Trailing tail (e.g. trailing blank line beyond the last segment).
        let totalLength = (markdown as NSString).length
        if lastEmittedEnd < totalLength {
            let tail = NSRange(location: lastEmittedEnd, length: totalLength - lastEmittedEnd)
            appendVerbatim(in: tail, source: markdown, theme: theme, into: result)
        }
        return result
    }

    private func parseAndHighlight(_ markdown: String) -> [HighlightSpan] {
        guard let blockTree = blockParser.parse(markdown),
              let blockRoot = blockTree.rootNode else { return [] }
        let blockMapping = blockParser.mapping
        let blockSpans = highlighter.highlights(
            rootNode: blockRoot, in: blockTree, mapping: blockMapping, grammar: .block
        )
        let inlineTree = inlineParser.parse(markdown)
        let inlineMapping = inlineParser.mapping
        var inlineSpans: [HighlightSpan] = []
        if let inlineRoot = inlineTree?.rootNode, let it = inlineTree {
            inlineSpans = highlighter.highlights(
                rootNode: inlineRoot, in: it, mapping: inlineMapping, grammar: .inline
            )
        }
        return blockSpans + inlineSpans
    }

    // MARK: - segment emission

    private func appendSegment(
        _ segment: BlockSegment,
        source: String,
        blockHighlights: [HighlightSpan],
        inlineHighlights: [HighlightSpan],
        theme: MarginaliaTheme,
        dialect: Dialect,
        into out: NSMutableAttributedString
    ) {
        switch segment.tag {
        case .paragraph,
             .heading,
             .unorderedListItem,
             .orderedListItem,
             .taskListItem:
            appendInlineBlock(
                segment,
                source: source,
                inlineHighlights: inlineHighlights,
                blockHighlights: blockHighlights,
                theme: theme,
                dialect: dialect,
                into: out
            )
        case .fencedCode, .indentedCode:
            appendCodeBlock(segment, source: source, theme: theme, into: out)
        case .horizontalRule:
            appendHorizontalRule(segment, source: source, theme: theme, into: out)
        case .htmlBlock, .linkReferenceDefinition, .pipeTable:
            // Emit verbatim with block tag so the serializer can round-trip.
            appendOpaqueBlock(segment, source: source, theme: theme, into: out)
        }
    }

    /// Emit a paragraph-shaped segment (paragraph, heading, blockquote,
    /// list-item) where inline content is rendered with markup characters
    /// stripped and inline emphasis/strong/code/link applied as attributes.
    private func appendInlineBlock(
        _ segment: BlockSegment,
        source: String,
        inlineHighlights: [HighlightSpan],
        blockHighlights: [HighlightSpan],
        theme: MarginaliaTheme,
        dialect: Dialect,
        into out: NSMutableAttributedString
    ) {
        let nsSource = source as NSString
        let segRange = segment.range
        let blockMarkup = blockHighlights.filter { span in
            span.tag == .punctuationSpecial && rangesIntersect(span.range, segRange)
        }
        let inlineSpans = inlineHighlights.filter { rangesIntersect($0.range, segRange) }
        let inlineMarkupSpans = inlineSpans.filter { $0.tag == .punctuationDelimiter }

        // Block-level markup tokens (`#`, `>`, `-`, `1.`, fence backticks)
        // cover only the marker; extend each through any horizontal
        // whitespace that follows so the rendered storage drops the
        // post-marker space too. Inline markup (emphasis/link delimiters)
        // never absorbs surrounding whitespace.
        let blockStrip = blockMarkup.map {
            extendThroughTrailingHorizontalWhitespace($0.range, in: nsSource)
        }
        var stripRanges = blockStrip + inlineMarkupSpans.map { $0.range }
        // Task list markers (`[ ]` / `[x]`) aren't tagged by the bundled
        // highlight queries; strip them by lookahead within the segment.
        if segment.tag == .taskListItem {
            if let taskRange = taskMarkerRange(in: segRange, source: nsSource) {
                stripRanges.append(taskRange)
            }
        }
        let strip = unionRanges(stripRanges)

        let stripped = stripCharacters(in: segRange, source: nsSource, stripping: strip)
        var content = stripped.text
        // Trailing newline handling: a paragraph segment's range usually ends
        // with a `\n`. Keep one trailing newline so paragraphs remain
        // separated; trim any extras (e.g. a setext underline that got
        // stripped).
        while content.hasSuffix("\n\n") { content.removeLast() }
        if !content.hasSuffix("\n") { content.append("\n") }

        // Project inline style spans onto stripped coordinates.
        var styleRuns: [(NSRange, [NSAttributedString.Key: Any])] = []
        for span in inlineSpans where span.tag != .punctuationDelimiter {
            guard let projected = stripped.project(sourceRange: span.range) else { continue }
            switch span.tag {
            case .textStrong:
                styleRuns.append((projected, [.font: themedFont(theme.bodyFont, traits: [.bold])]))
            case .textEmphasis:
                styleRuns.append((projected, [.font: themedFont(theme.bodyFont, traits: [.italic])]))
            case .textLiteral:
                styleRuns.append((projected, [
                    .font: theme.monospaceFont,
                    .backgroundColor: subtleBackground(theme: theme),
                    .marginaliaInline: InlineTag.codeSpan
                ]))
            case .textURI, .textReference:
                styleRuns.append((projected, [
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .marginaliaInline: InlineTag.link
                ]))
            default:
                break
            }
        }

        let baseFont: PlatformFont
        switch segment.tag {
        case .heading:
            let scale = theme.headingScale[segment.level] ?? 1.0
            baseFont = themedFont(theme.bodyFont, scale: scale, traits: [.bold])
        default:
            baseFont = theme.bodyFont
        }

        let paragraphStyle = paragraphStyleFor(tag: segment.tag,
                                                level: segment.level,
                                                blockquoteDepth: segment.blockquoteDepth,
                                                listLevel: segment.listLevel,
                                                theme: theme)

        let paragraphAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: paragraphStyle
        ]

        let attributed = NSMutableAttributedString(string: content, attributes: paragraphAttrs)

        // Apply inline style runs FIRST — their ranges are computed in
        // stripped-body coordinates, so prepending the marker before
        // these run would slide every range to the left by the marker
        // length and bold "**bold**" would land on the marker glyph
        // instead of the word.
        for (range, attrs) in styleRuns {
            let safe = clampedRange(range, in: attributed.length)
            guard safe.length > 0 else { continue }
            for (k, v) in attrs {
                if k == .font {
                    if let baseRun = attributed.safeAttribute(.font, at: safe.location) as? PlatformFont,
                       let trait = (v as? PlatformFont).flatMap({ traitsOf($0) }) {
                        let merged = themedFont(baseRun, traits: trait)
                        attributed.addAttribute(.font, value: merged, range: safe)
                    } else {
                        attributed.addAttribute(.font, value: v, range: safe)
                    }
                } else {
                    attributed.addAttribute(k, value: v, range: safe)
                }
            }
        }

        switch segment.tag {
        case .taskListItem:
            let attachment = CheckboxAttachment()
            attachment.isChecked = segment.isChecked ?? false
            var attachmentAttrs = paragraphAttrs
            attachmentAttrs[.attachment] = attachment
            attachmentAttrs[.marginaliaListMarker] = true
            attributed.insert(
                NSAttributedString(string: "\u{FFFC} ", attributes: attachmentAttrs),
                at: 0
            )
        case .unorderedListItem:
            let attachment = BulletGlyphAttachment(level: segment.listLevel, color: theme.foregroundColor)
            var markerAttrs = paragraphAttrs
            markerAttrs[.attachment] = attachment
            markerAttrs[.foregroundColor] = theme.foregroundColor
            markerAttrs[.marginaliaListMarker] = true
            attributed.insert(
                NSAttributedString(string: "\u{FFFC} ", attributes: markerAttrs),
                at: 0
            )
        case .orderedListItem:
            let style = OrderedMarkerFormatter.style(forLevel: segment.listLevel)
            let marker = OrderedMarkerFormatter.format(index: segment.orderedIndex ?? 1, style: style)
            var markerAttrs = paragraphAttrs
            markerAttrs[.foregroundColor] = theme.markupColor
            markerAttrs[.marginaliaListMarker] = true
            attributed.insert(
                NSAttributedString(string: "\(marker) ", attributes: markerAttrs),
                at: 0
            )
        default:
            break
        }

        appendStyled(attributed, spec: BlockSpec(blockSegment: segment), into: out)
    }

    private func appendCodeBlock(
        _ segment: BlockSegment,
        source: String,
        theme: MarginaliaTheme,
        into out: NSMutableAttributedString
    ) {
        let nsSource = source as NSString
        let raw = nsSource.substring(with: segment.range)
        let paragraphAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.monospaceFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: paragraphStyleFor(tag: segment.tag,
                                                level: 0,
                                                blockquoteDepth: segment.blockquoteDepth,
                                                listLevel: segment.listLevel,
                                                theme: theme)
        ]
        var content = raw
        if !content.hasSuffix("\n") { content.append("\n") }
        appendStyled(
            NSAttributedString(string: content, attributes: paragraphAttrs),
            spec: BlockSpec(blockSegment: segment),
            into: out
        )
    }

    private func appendHorizontalRule(
        _ segment: BlockSegment,
        source: String,
        theme: MarginaliaTheme,
        into out: NSMutableAttributedString
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.markupColor
        ]
        let nsSource = source as NSString
        var content = nsSource.substring(with: segment.range)
        if !content.hasSuffix("\n") { content.append("\n") }
        appendStyled(
            NSAttributedString(string: content, attributes: attrs),
            spec: BlockSpec(blockSegment: segment),
            into: out
        )
    }

    private func appendOpaqueBlock(
        _ segment: BlockSegment,
        source: String,
        theme: MarginaliaTheme,
        into out: NSMutableAttributedString
    ) {
        let nsSource = source as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: segment.tag == .pipeTable ? theme.monospaceFont : theme.bodyFont,
            .foregroundColor: theme.foregroundColor
        ]
        var content = nsSource.substring(with: segment.range)
        if !content.hasSuffix("\n") { content.append("\n") }
        appendStyled(
            NSAttributedString(string: content, attributes: attrs),
            spec: BlockSpec(blockSegment: segment),
            into: out
        )
    }

    private func appendVerbatim(
        in range: NSRange,
        source: String,
        theme: MarginaliaTheme,
        into out: NSMutableAttributedString
    ) {
        guard range.length > 0 else { return }
        let nsSource = source as NSString
        let s = nsSource.substring(with: range)
        appendStyled(
            NSAttributedString(string: s, attributes: baseAttributes(theme: theme)),
            spec: .paragraph,
            into: out
        )
    }

    private func appendStyled(
        _ attributed: NSAttributedString,
        spec: BlockSpec,
        into out: NSMutableAttributedString
    ) {
        let startIdx = out.length
        out.append(attributed)
        let endIdx = out.length
        guard endIdx > startIdx else { return }
        out.setBlockSpec(spec, in: NSRange(location: startIdx, length: endIdx - startIdx))
    }

    // MARK: - paragraph styles

    public func makeListItem(
        kind: ListItemKind,
        level: Int,
        orderedIndex: Int? = nil,
        isChecked: Bool? = nil,
        content: String = "",
        theme: MarginaliaTheme
    ) -> NSAttributedString {
        let blockTag: BlockTag
        switch kind {
        case .bullet: blockTag = .unorderedListItem
        case .ordered: blockTag = .orderedListItem
        case .task: blockTag = .taskListItem
        }
        let paragraphStyle = paragraphStyleFor(
            tag: blockTag,
            level: 0,
            blockquoteDepth: 0,
            listLevel: level,
            theme: theme
        )
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: paragraphStyle
        ]
        let result = NSMutableAttributedString()
        var markerAttrs = baseAttrs
        markerAttrs[.marginaliaListMarker] = true
        switch kind {
        case .bullet:
            let attachment = BulletGlyphAttachment(level: level, color: theme.foregroundColor)
            markerAttrs[.attachment] = attachment
            markerAttrs[.foregroundColor] = theme.foregroundColor
            result.append(NSAttributedString(string: "\u{FFFC} ", attributes: markerAttrs))
        case .ordered:
            let style = OrderedMarkerFormatter.style(forLevel: level)
            let s = OrderedMarkerFormatter.format(index: orderedIndex ?? 1, style: style)
            markerAttrs[.foregroundColor] = theme.markupColor
            result.append(NSAttributedString(string: "\(s) ", attributes: markerAttrs))
        case .task:
            let attachment = CheckboxAttachment()
            attachment.isChecked = isChecked ?? false
            markerAttrs[.attachment] = attachment
            result.append(NSAttributedString(string: "\u{FFFC} ", attributes: markerAttrs))
        }
        result.append(NSAttributedString(string: content + "\n", attributes: baseAttrs))
        let kindSpec: BlockSpec.Kind
        switch kind {
        case .bullet: kindSpec = .unorderedListItem
        case .ordered: kindSpec = .orderedListItem(index: orderedIndex ?? 1)
        case .task: kindSpec = .taskListItem(checked: isChecked ?? false)
        }
        let spec = BlockSpec(kind: kindSpec, listLevel: level)
        result.setBlockSpec(spec, in: NSRange(location: 0, length: result.length))
        return result
    }

    public func paragraphStyle(forListLevel level: Int, theme: MarginaliaTheme) -> NSParagraphStyle {
        paragraphStyleFor(tag: .unorderedListItem, level: 0, blockquoteDepth: 0, listLevel: level, theme: theme)
    }

    public func makeBlockquoteLine(
        depth: Int = 1,
        content: String = "",
        theme: MarginaliaTheme
    ) -> NSAttributedString {
        let paragraphStyle = paragraphStyleFor(
            tag: .paragraph,
            level: 0,
            blockquoteDepth: max(1, depth),
            listLevel: 0,
            theme: theme
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: paragraphStyle
        ]
        let result = NSMutableAttributedString(string: content + "\n", attributes: attrs)
        let spec = BlockSpec(kind: .paragraph, blockquoteDepth: max(1, depth))
        result.setBlockSpec(spec, in: NSRange(location: 0, length: result.length))
        return result
    }

    private func paragraphStyleFor(
        tag: BlockTag,
        level: Int,
        blockquoteDepth: Int,
        listLevel: Int,
        theme: MarginaliaTheme
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping

        let blockquoteIndent = CGFloat(blockquoteDepth) * 16

        switch tag {
        case .heading:
            style.paragraphSpacingBefore = CGFloat(max(0, 7 - level)) * 2
            style.paragraphSpacing = 4
            style.firstLineHeadIndent = blockquoteIndent
            style.headIndent = blockquoteIndent
        case .unorderedListItem, .orderedListItem, .taskListItem:
            let outer: CGFloat = 12
            let perLevel: CGFloat = 18
            let bodyOffset: CGFloat = 22
            let firstLine = blockquoteIndent + outer + CGFloat(max(0, listLevel)) * perLevel
            style.firstLineHeadIndent = firstLine
            style.headIndent = firstLine + bodyOffset
        case .fencedCode, .indentedCode:
            style.firstLineHeadIndent = blockquoteIndent + 8
            style.headIndent = blockquoteIndent + 8
            style.paragraphSpacing = 2
        default:
            style.firstLineHeadIndent = blockquoteIndent
            style.headIndent = blockquoteIndent
        }
        return style
    }

    // MARK: - helpers

    private func baseAttributes(theme: MarginaliaTheme) -> [NSAttributedString.Key: Any] {
        [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor
        ]
    }

    private func subtleBackground(theme: MarginaliaTheme) -> PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.12)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.12)
        #endif
    }

    private func isListItemTag(_ tag: BlockTag) -> Bool {
        tag == .unorderedListItem || tag == .orderedListItem || tag == .taskListItem
    }

    private func listKind(forTag tag: BlockTag) -> ListItemKind {
        switch tag {
        case .orderedListItem: return .ordered
        case .taskListItem: return .task
        default: return .bullet
        }
    }

    private func rangesIntersect(_ a: NSRange, _ b: NSRange) -> Bool {
        let aEnd = a.location + a.length
        let bEnd = b.location + b.length
        return a.location < bEnd && b.location < aEnd
    }

    private func clampedRange(_ range: NSRange, in length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        let remaining = max(0, length - location)
        return NSRange(location: location, length: max(0, min(range.length, remaining)))
    }

    /// Walk forward from a strip range's end as long as the next character
    /// is a horizontal whitespace (` ` or `\t`). Used to absorb the trailing
    /// space that follows block-markup tokens like `#`, `>`, list markers.
    private func extendThroughTrailingHorizontalWhitespace(_ range: NSRange, in source: NSString) -> NSRange {
        var end = range.location + range.length
        while end < source.length {
            let ch = source.character(at: end)
            if ch == 0x20 || ch == 0x09 { end += 1 } else { break }
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    /// Find the `[ ]` / `[x]` / `[X]` bracket range (including the trailing
    /// space) inside a task-list-item segment.
    private func taskMarkerRange(in segRange: NSRange, source: NSString) -> NSRange? {
        let pattern = #"^[ \t]*[-*+]\s+(\[[ xX]\]\s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let scan = NSRange(location: segRange.location, length: min(segRange.length, 32))
        let raw = source.substring(with: scan)
        guard let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) else { return nil }
        let bracket = match.range(at: 1)
        return NSRange(location: scan.location + bracket.location, length: bracket.length)
    }

    private func unionRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for r in sorted {
            if var last = merged.last, last.location + last.length >= r.location {
                let upper = max(last.location + last.length, r.location + r.length)
                last.length = upper - last.location
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private struct StripResult {
        let text: String
        /// Source location → stripped index. -1 means "stripped out"; otherwise
        /// the index into `text` where the source character maps to.
        let projection: [Int]
        /// Source range start used for projection lookups.
        let sourceStart: Int

        func project(sourceRange: NSRange) -> NSRange? {
            let lo = sourceRange.location - sourceStart
            let hi = lo + sourceRange.length
            guard lo >= 0, hi <= projection.count else { return nil }
            // Find first/last non-stripped indices in [lo..hi).
            var startIdx: Int?
            var endIdx: Int?
            for i in lo..<hi {
                let mapped = projection[i]
                if mapped >= 0 {
                    if startIdx == nil { startIdx = mapped }
                    endIdx = mapped + 1
                }
            }
            guard let s = startIdx, let e = endIdx, e > s else { return nil }
            return NSRange(location: s, length: e - s)
        }
    }

    private func stripCharacters(
        in range: NSRange,
        source: NSString,
        stripping ranges: [NSRange]
    ) -> StripResult {
        let safe = NSRange(
            location: max(0, min(range.location, source.length)),
            length: max(0, min(range.length, source.length - max(0, min(range.location, source.length))))
        )
        var out = ""
        out.reserveCapacity(safe.length)
        var projection: [Int] = Array(repeating: -1, count: safe.length)
        // For O(n+m), scan ranges and source together. ranges are non-overlapping.
        var rangeIdx = 0
        var srcIdx = 0
        let segStart = safe.location
        while srcIdx < safe.length {
            let absIdx = segStart + srcIdx
            // Skip past finished strip ranges.
            while rangeIdx < ranges.count {
                let r = ranges[rangeIdx]
                if r.location + r.length <= absIdx {
                    rangeIdx += 1
                } else {
                    break
                }
            }
            if rangeIdx < ranges.count {
                let r = ranges[rangeIdx]
                if absIdx >= r.location && absIdx < r.location + r.length {
                    projection[srcIdx] = -1
                    srcIdx += 1
                    continue
                }
            }
            let ch = source.character(at: absIdx)
            let outIdx = (out as NSString).length
            projection[srcIdx] = outIdx
            // append the unichar
            var unit = ch
            let part = NSString(characters: &unit, length: 1)
            out.append(part as String)
            srcIdx += 1
        }
        return StripResult(text: out, projection: projection, sourceStart: segStart)
    }
}

// MARK: - font trait helpers

private struct FontTraits: OptionSet {
    let rawValue: Int
    static let bold = FontTraits(rawValue: 1 << 0)
    static let italic = FontTraits(rawValue: 1 << 1)
}

private func themedFont(_ base: PlatformFont, scale: CGFloat = 1.0, traits: FontTraits = []) -> PlatformFont {
    let size = base.pointSize * scale
    #if canImport(AppKit) && os(macOS)
    var nsTraits: NSFontDescriptor.SymbolicTraits = []
    if traits.contains(.bold) { nsTraits.insert(.bold) }
    if traits.contains(.italic) { nsTraits.insert(.italic) }
    let descriptor = base.fontDescriptor.withSymbolicTraits(nsTraits)
    return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    #else
    var uiTraits: UIFontDescriptor.SymbolicTraits = []
    if traits.contains(.bold) { uiTraits.insert(.traitBold) }
    if traits.contains(.italic) { uiTraits.insert(.traitItalic) }
    if let d = base.fontDescriptor.withSymbolicTraits(uiTraits) {
        return UIFont(descriptor: d, size: size)
    }
    return UIFont.systemFont(ofSize: size)
    #endif
}

private func traitsOf(_ font: PlatformFont) -> FontTraits {
    var out: FontTraits = []
    #if canImport(AppKit) && os(macOS)
    let symbolic = font.fontDescriptor.symbolicTraits
    if symbolic.contains(.bold) { out.insert(.bold) }
    if symbolic.contains(.italic) { out.insert(.italic) }
    #else
    let symbolic = font.fontDescriptor.symbolicTraits
    if symbolic.contains(.traitBold) { out.insert(.bold) }
    if symbolic.contains(.traitItalic) { out.insert(.italic) }
    #endif
    return out
}
