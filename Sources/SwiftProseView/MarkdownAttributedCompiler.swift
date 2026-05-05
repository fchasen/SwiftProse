import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class MarkdownAttributedCompiler {

    private let blockParser: MarkdownParser
    private let inlineParser: MarkdownParser
    private let highlighter: HighlightApplier
    /// ProseMirror-aligned schema used by the Phase-2 stamping pass that
    /// adds `proseNodePath` and `proseMarks` to compiled storage. Defaults
    /// to `Schema.defaultMarkdown`; callers wanting a custom schema can
    /// supply one at init.
    public let schema: Schema
    public var codeBlockHighlighter: CodeBlockHighlighter?

    public init(
        codeBlockHighlighter: CodeBlockHighlighter? = nil,
        schema: Schema = .defaultMarkdown
    ) throws {
        self.blockParser = try MarkdownParser(grammar: .block)
        self.inlineParser = try MarkdownParser(grammar: .inline)
        self.highlighter = try HighlightApplier()
        self.codeBlockHighlighter = codeBlockHighlighter
        self.schema = schema
    }

    public func compile(
        _ markdown: String,
        theme: ProseTheme
    ) -> NSAttributedString {
        let rich = compileRich(markdown, theme: theme)
        // The emit loop has already stamped `proseNodePath` per segment via
        // `setBlockSpec` (which derives a path from each spec, sharing list
        // ancestors with the predecessor line). One more pass derives
        // `proseMarks` from the rendering attributes per block.
        let mutable = NSMutableAttributedString(attributedString: rich)
        NodePathSynthesizer(schema: schema).stampMarks(
            in: mutable,
            range: NSRange(location: 0, length: mutable.length)
        )
        return mutable
    }

    /// Compile a markdown source into a `ProseDocument` tree by going
    /// through the storage pipeline (so the tree shares the same parser,
    /// highlighter, and stamp logic) and reverse-projecting via
    /// `ProseDocument.from(storage:)`. Phase 4 will add a more direct
    /// tree-builder path that skips storage as an intermediate; until then
    /// this round-trips through `NSAttributedString`.
    public func compileToTree(
        _ markdown: String,
        theme: ProseTheme
    ) -> ProseDocument {
        let storage = compile(markdown, theme: theme)
        return ProseDocument.from(storage: storage, schema: schema)
    }

    private func compileRich(
        _ markdown: String,
        theme: ProseTheme
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
        let inlineRegions: [InlineRegion]
        if let inlineRoot = inlineTree?.rootNode, let it = inlineTree {
            inlineHighlights = highlighter.highlights(
                rootNode: inlineRoot, in: it, mapping: inlineMapping, grammar: .inline
            )
            inlineRegions = InlineClassifier.classify(rootNode: inlineRoot, mapping: inlineMapping)
        } else {
            inlineHighlights = []
            inlineRegions = []
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
                inlineRegions: inlineRegions,
                theme: theme,
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

    // MARK: - segment emission

    private func appendSegment(
        _ segment: BlockSegment,
        source: String,
        blockHighlights: [HighlightSpan],
        inlineHighlights: [HighlightSpan],
        inlineRegions: [InlineRegion],
        theme: ProseTheme,
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
                inlineRegions: inlineRegions,
                blockHighlights: blockHighlights,
                theme: theme,
                into: out
            )
        case .fencedCode, .indentedCode:
            appendCodeBlock(segment, source: source, theme: theme, into: out)
        case .horizontalRule:
            appendHorizontalRule(segment, source: source, theme: theme, into: out)
        case .pipeTable:
            appendPipeTableAsParagraphs(segment, source: source, theme: theme, into: out)
        case .htmlBlock, .linkReferenceDefinition:
            // Emit verbatim with block tag so the serializer can round-trip.
            appendOpaqueBlock(segment, source: source, theme: theme, into: out)
        }
    }

    private func appendInlineBlock(
        _ segment: BlockSegment,
        source: String,
        inlineHighlights: [HighlightSpan],
        inlineRegions: [InlineRegion],
        blockHighlights: [HighlightSpan],
        theme: ProseTheme,
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
        // For each image inside this segment strip every byte that isn't
        // part of the alt-text range. The bundled highlight queries cover
        // most of the image's punctuation but not (e.g.) the space between
        // `link_destination` and `link_title`; explicit strip keeps the
        // rendered storage to just the alt and lets the leaf stamp later
        // round-trip the image cleanly.
        for region in inlineRegions {
            guard case .image(_, _, let altRange, _) = region.kind,
                  rangesIntersect(region.range, segRange) else { continue }
            let imgStart = region.range.location
            let imgEnd = region.range.location + region.range.length
            let altStart = altRange.location
            let altEnd = altRange.location + altRange.length
            if altStart > imgStart {
                stripRanges.append(NSRange(location: imgStart, length: altStart - imgStart))
            }
            if imgEnd > altEnd {
                stripRanges.append(NSRange(location: altEnd, length: imgEnd - altEnd))
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
                styleRuns.append((projected, [.font: theme.bodyFont.withProseTraits(.bold)]))
            case .textEmphasis:
                styleRuns.append((projected, [.font: theme.bodyFont.withProseTraits(.italic)]))
            case .textLiteral:
                styleRuns.append((projected, [
                    .font: theme.monospaceFont,
                    .proseInline: InlineTag.codeSpan
                ]))
            case .textStrike:
                styleRuns.append((projected, [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ]))
            case .textURI, .textReference:
                var attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .proseInline: InlineTag.link
                ]
                if let dest = linkDestination(for: span.range, in: inlineRegions) {
                    attrs[.proseLink] = dest
                    if let url = URL(string: dest) {
                        attrs[.link] = url
                    } else {
                        attrs[.link] = dest
                    }
                }
                styleRuns.append((projected, attrs))
            default:
                break
            }
        }

        let baseFont: PlatformFont
        switch segment.tag {
        case .heading:
            let scale = theme.headingScale[segment.level] ?? 1.0
            baseFont = theme.bodyFont.withProseTraits(.bold, scale: scale)
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
            let safe = range.clamped(to: attributed.length)
            guard safe.length > 0 else { continue }
            for (k, v) in attrs {
                if k == .font {
                    if let baseRun = attributed.safeAttribute(.font, at: safe.location) as? PlatformFont,
                       let trait = (v as? PlatformFont)?.proseTraits {
                        // Combine traits with what the run already carries
                        // — `withProseTraits` replaces, so a second pass
                        // (italic on top of bold) would otherwise drop the
                        // first trait. Union preserves both.
                        let merged = baseRun.withProseTraits(baseRun.proseTraits.union(trait))
                        attributed.addAttribute(.font, value: merged, range: safe)
                    } else {
                        attributed.addAttribute(.font, value: v, range: safe)
                    }
                } else {
                    attributed.addAttribute(k, value: v, range: safe)
                }
            }
        }

        var markerLen = 0
        switch segment.tag {
        case .taskListItem:
            let attachment = CheckboxAttachment()
            attachment.isChecked = segment.isChecked ?? false
            var attachmentAttrs = paragraphAttrs
            attachmentAttrs[.attachment] = attachment
            attachmentAttrs[.proseListMarker] = true
            let marker = NSAttributedString(string: "\u{FFFC} ", attributes: attachmentAttrs)
            attributed.insert(marker, at: 0)
            markerLen = marker.length
        case .unorderedListItem:
            let attachment = BulletGlyphAttachment(level: segment.listLevel, color: theme.foregroundColor)
            var markerAttrs = paragraphAttrs
            markerAttrs[.attachment] = attachment
            markerAttrs[.foregroundColor] = theme.foregroundColor
            markerAttrs[.proseListMarker] = true
            let marker = NSAttributedString(string: "\u{FFFC} ", attributes: markerAttrs)
            attributed.insert(marker, at: 0)
            markerLen = marker.length
        case .orderedListItem:
            let style = OrderedMarkerFormatter.style(forLevel: segment.listLevel)
            let formatted = OrderedMarkerFormatter.format(index: segment.orderedIndex ?? 1, style: style)
            var markerAttrs = paragraphAttrs
            markerAttrs[.foregroundColor] = theme.markupColor
            markerAttrs[.proseListMarker] = true
            let marker = NSAttributedString(string: "\(formatted) ", attributes: markerAttrs)
            attributed.insert(marker, at: 0)
            markerLen = marker.length
        default:
            break
        }

        let blockBaseLength = out.length
        appendStyled(attributed, spec: BlockSpec(blockSegment: segment), into: out)
        stampImageLeaves(
            in: out,
            blockBase: blockBaseLength,
            markerLen: markerLen,
            stripped: stripped,
            inlineRegions: inlineRegions,
            segRange: segRange
        )
    }

    /// For every image region intersecting this segment, replace the
    /// `proseNodePath` over its alt-text storage range with an extended
    /// path that appends an `image` leaf carrying the image's
    /// `src`/`alt`/`title` attrs. The base path is read back from the
    /// surrounding paragraph so the extended path keeps the paragraph's
    /// node id — letting the tree builder reattach the leaf to the same
    /// paragraph as the surrounding text.
    private func stampImageLeaves(
        in out: NSMutableAttributedString,
        blockBase: Int,
        markerLen: Int,
        stripped: StripResult,
        inlineRegions: [InlineRegion],
        segRange: NSRange
    ) {
        // Walk image regions in reverse source order — when an empty-alt
        // image needs a U+FFFC placeholder inserted, processing later
        // images first keeps earlier images' projected positions valid.
        let images = inlineRegions
            .filter { region in
                if case .image = region.kind, rangesIntersect(region.range, segRange) {
                    return true
                }
                return false
            }
            .sorted { $0.range.location > $1.range.location }
        for region in images {
            guard case .image(let dest, let alt, let altRange, let title) = region.kind else { continue }
            var attrs: [String: ProseAttrValue] = ["src": .string(dest)]
            attrs["alt"] = alt.isEmpty ? .null : .string(alt)
            attrs["title"] = title.map(ProseAttrValue.string) ?? .null
            let imageNode = ProseNode(type: "image", attrs: attrs)
            if let projected = stripped.project(sourceRange: altRange), projected.length > 0 {
                let abs = NSRange(
                    location: blockBase + markerLen + projected.location,
                    length: projected.length
                )
                guard abs.location >= 0,
                      abs.location + abs.length <= out.length else { continue }
                guard let basePath = out.nodePath(at: abs.location) else { continue }
                let extended = basePath.appending(imageNode)
                out.setNodePath(extended, in: abs)
            } else {
                // Empty alt — insert a U+FFFC placeholder so the image leaf
                // has a single-character anchor on storage, then stamp the
                // extended path on it.
                let strippedInsert = firstPreservedStrippedIndex(
                    afterSourceLocation: region.range.location,
                    in: stripped
                )
                let absLoc = blockBase + markerLen + strippedInsert
                guard absLoc >= 0, absLoc <= out.length else { continue }
                let probe = max(0, min(absLoc, out.length - 1))
                guard out.length > 0,
                      let basePath = out.nodePath(at: probe) else { continue }
                let baseAttrs = out.attributes(at: probe, effectiveRange: nil)
                let extended = basePath.appending(imageNode)
                let placeholder = NSAttributedString(
                    string: "\u{FFFC}",
                    attributes: baseAttrs
                )
                out.insert(placeholder, at: absLoc)
                out.setNodePath(extended, in: NSRange(location: absLoc, length: 1))
            }
        }
    }

    /// Walk the strip projection forward from `sourceLocation` and return
    /// the first preserved (non-stripped) stripped-content index. When the
    /// image's source range is entirely stripped, this gives us the offset
    /// of the next visible character — the right place to insert a U+FFFC
    /// placeholder.
    private func firstPreservedStrippedIndex(
        afterSourceLocation sourceLocation: Int,
        in stripped: StripResult
    ) -> Int {
        let scanStart = max(0, sourceLocation - stripped.sourceStart)
        guard scanStart < stripped.projection.count else {
            return (stripped.text as NSString).length
        }
        for i in scanStart..<stripped.projection.count {
            let mapped = stripped.projection[i]
            if mapped >= 0 { return mapped }
        }
        return (stripped.text as NSString).length
    }

    private func appendCodeBlock(
        _ segment: BlockSegment,
        source: String,
        theme: ProseTheme,
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
        let attributed = NSMutableAttributedString(string: content, attributes: paragraphAttrs)
        applyCodeBlockHighlights(to: attributed, segment: segment, source: source, theme: theme)
        markCodeBlockMarkup(in: attributed, tag: segment.tag)
        appendStyled(attributed, spec: BlockSpec(blockSegment: segment), into: out)
    }

    /// Mark fence/indent characters with `proseListMarker` so the tree
    /// projection excludes them from the leaf's inline content.
    private func markCodeBlockMarkup(
        in attributed: NSMutableAttributedString,
        tag: BlockTag
    ) {
        let ns = attributed.string as NSString
        switch tag {
        case .fencedCode:
            let firstNL = ns.range(of: "\n")
            if firstNL.location != NSNotFound {
                attributed.addAttribute(
                    .proseListMarker,
                    value: true,
                    range: NSRange(location: 0, length: firstNL.location + 1)
                )
            }
            var end = ns.length
            while end > 0, ns.character(at: end - 1) == 0x0A { end -= 1 }
            var lineStart = end
            while lineStart > 0, ns.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
            if lineStart < end {
                let lastLine = ns.substring(with: NSRange(location: lineStart, length: end - lineStart))
                if isFenceLine(lastLine) {
                    attributed.addAttribute(
                        .proseListMarker,
                        value: true,
                        range: NSRange(location: lineStart, length: ns.length - lineStart)
                    )
                }
            }
        case .indentedCode:
            var i = 0
            while i < ns.length {
                var j = i
                while j < ns.length, j - i < 4, ns.character(at: j) == 0x20 {
                    j += 1
                }
                if j > i {
                    attributed.addAttribute(
                        .proseListMarker,
                        value: true,
                        range: NSRange(location: i, length: j - i)
                    )
                }
                while j < ns.length, ns.character(at: j) != 0x0A { j += 1 }
                if j < ns.length { j += 1 }
                i = j
            }
        default:
            break
        }
    }

    /// Run the registered `CodeBlockHighlighter` over the body lines of this
    /// code block (skipping fence + info-string lines for fenced blocks, the
    /// indent prefix for indented blocks) and color tokens via
    /// `theme.codeColor(for:)`. Spans landing on fences are dropped.
    private func applyCodeBlockHighlights(
        to attributed: NSMutableAttributedString,
        segment: BlockSegment,
        source: String,
        theme: ProseTheme
    ) {
        guard let highlighter = codeBlockHighlighter else { return }
        guard let body = codeBlockBody(segment: segment, source: source) else { return }
        let resolved: String?
        if let explicit = segment.language, !explicit.isEmpty {
            resolved = explicit
        } else {
            resolved = highlighter.detectLanguage(for: body.text)
        }
        let spans = highlighter.highlights(for: body.text, language: resolved)
        guard !spans.isEmpty else { return }
        let attributedLength = attributed.length
        for span in spans {
            guard let color = theme.codeColor(for: span.tag) else { continue }
            let start = body.offsetInSegment + span.range.location
            let end = start + span.range.length
            guard start >= 0, end <= attributedLength, start < end else { continue }
            attributed.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: start, length: end - start)
            )
        }
    }

    /// Returns the body text of a code-block segment plus the offset (in
    /// segment-local coordinates) at which that body starts. The first / last
    /// lines of a fenced block are the fence delimiters; an indented block is
    /// all body but each line is prefixed with the indent.
    private func codeBlockBody(
        segment: BlockSegment,
        source: String
    ) -> (text: String, offsetInSegment: Int)? {
        let nsSource = source as NSString
        let raw = nsSource.substring(with: segment.range)
        switch segment.tag {
        case .fencedCode:
            // Drop the first line (opening fence + info string) and the last
            // line if it's a closing fence. Tree-sitter sometimes emits
            // unterminated fences (range ends with body); handle both.
            let lines = raw.components(separatedBy: "\n")
            guard lines.count >= 2 else { return nil }
            let firstLineUTF16 = (lines[0] as NSString).length + 1 // +1 for the \n
            var bodyLines = Array(lines.dropFirst())
            // Strip trailing empty entry from a trailing \n.
            if bodyLines.last == "" { bodyLines.removeLast() }
            // If the last line looks like a closing fence (only ` or ~), drop it.
            if let last = bodyLines.last, isFenceLine(last) {
                bodyLines.removeLast()
            }
            let body = bodyLines.joined(separator: "\n")
            return (body, firstLineUTF16)
        case .indentedCode:
            return (raw, 0)
        default:
            return nil
        }
    }

    private func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    /// Re-run the registered `CodeBlockHighlighter` over the body of an
    /// existing code-block run in `storage` and stamp its colors. Used by
    /// `EditorController` after every typed keystroke that lands inside a
    /// fenced or indented code block — the original `compile()` pass colored
    /// the block when it was first laid down (often empty), but typing alone
    /// never re-runs the highlighter. Without this, freshly-typed code in an
    /// otherwise-classified block stays uncolored until the next full
    /// recompile.
    public func rehighlightCodeBlock(
        in storage: NSTextStorage,
        blockRange: NSRange,
        language: String?,
        isFenced: Bool,
        theme: ProseTheme
    ) {
        guard let highlighter = codeBlockHighlighter else { return }
        guard let body = codeBlockBody(in: storage, blockRange: blockRange, isFenced: isFenced) else { return }
        let resolved: String?
        if let language, !language.isEmpty {
            resolved = language
        } else {
            resolved = highlighter.detectLanguage(for: body.text)
        }
        let bodyStart = blockRange.location + body.offsetInBlock
        let bodyLength = (body.text as NSString).length
        guard bodyStart >= 0,
              bodyStart + bodyLength <= storage.length,
              bodyLength > 0 else { return }
        let bodyRange = NSRange(location: bodyStart, length: bodyLength)
        storage.beginEditing()
        // Reset prior colors before re-stamping so deleted/changed tokens
        // don't leave stale highlight residue.
        storage.addAttribute(.foregroundColor, value: theme.foregroundColor, range: bodyRange)
        let spans = highlighter.highlights(for: body.text, language: resolved)
        for span in spans {
            guard let color = theme.codeColor(for: span.tag) else { continue }
            let start = bodyStart + span.range.location
            let end = start + span.range.length
            guard start >= bodyStart, end <= bodyStart + bodyLength, start < end else { continue }
            storage.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: start, length: end - start)
            )
        }
        storage.endEditing()
    }

    /// Body extraction parallel to `codeBlockBody(segment:source:)` but
    /// against an in-flight `NSAttributedString` rather than a parsed source
    /// string. Same fence-stripping rules so the highlighter sees only code.
    private func codeBlockBody(
        in storage: NSAttributedString,
        blockRange: NSRange,
        isFenced: Bool
    ) -> (text: String, offsetInBlock: Int)? {
        let ns = storage.string as NSString
        guard blockRange.location >= 0,
              blockRange.location + blockRange.length <= ns.length,
              blockRange.length > 0 else { return nil }
        let raw = ns.substring(with: blockRange)
        if isFenced {
            let lines = raw.components(separatedBy: "\n")
            guard lines.count >= 2 else { return nil }
            let firstLineUTF16 = (lines[0] as NSString).length + 1
            var bodyLines = Array(lines.dropFirst())
            if bodyLines.last == "" { bodyLines.removeLast() }
            if let last = bodyLines.last, isFenceLine(last) {
                bodyLines.removeLast()
            }
            let body = bodyLines.joined(separator: "\n")
            return (body, firstLineUTF16)
        }
        return (raw, 0)
    }

    private func appendHorizontalRule(
        _ segment: BlockSegment,
        source: String,
        theme: ProseTheme,
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
        theme: ProseTheme,
        into out: NSMutableAttributedString
    ) {
        let nsSource = source as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor
        ]
        var content = nsSource.substring(with: segment.range)
        if !content.hasSuffix("\n") { content.append("\n") }
        let startIdx = out.length
        appendStyled(
            NSAttributedString(string: content, attributes: attrs),
            spec: BlockSpec(blockSegment: segment),
            into: out
        )
        if segment.tag == .linkReferenceDefinition,
           let parsed = parseLinkReference(content) {
            stampLinkReferenceAttrs(
                in: out,
                range: NSRange(location: startIdx, length: out.length - startIdx),
                label: parsed.label,
                href: parsed.href,
                title: parsed.title
            )
        }
    }

    private func parseLinkReference(_ source: String) -> (label: String, href: String, title: String?)? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^\[([^\]]+)\]:\s+(\S+)(?:\s+"([^"]+)")?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let label = ns.substring(with: match.range(at: 1))
        let href = ns.substring(with: match.range(at: 2))
        let titleRange = match.range(at: 3)
        let title: String? = titleRange.location == NSNotFound ? nil : ns.substring(with: titleRange)
        return (label, href, title)
    }

    private func stampLinkReferenceAttrs(
        in out: NSMutableAttributedString,
        range: NSRange,
        label: String,
        href: String,
        title: String?
    ) {
        out.enumerateNodePaths(in: range) { runRange, path in
            guard let leaf = path.leaf, leaf.type == "link_reference" else { return }
            var newAttrs = leaf.attrs
            newAttrs["label"] = .string(label)
            newAttrs["href"] = .string(href)
            newAttrs["title"] = title.map(ProseAttrValue.string) ?? .null
            let newLeaf = ProseNode(id: leaf.id, type: leaf.type, attrs: newAttrs)
            let newPath = NodePath(path.nodes.dropLast() + [newLeaf])
            out.setNodePath(newPath, in: runRange)
        }
    }

    /// Emit a pipe-table segment as plain per-line paragraphs. Pipe
    /// characters survive as literal text — there's no rendered cell
    /// chrome and no inline parsing inside cells. Tables become readable
    /// monospace source lines that round-trip losslessly through the
    /// markdown serializer; structural editing waits for the tree-native
    /// rebuild (Phase 6).
    private func appendPipeTableAsParagraphs(
        _ segment: BlockSegment,
        source: String,
        theme: ProseTheme,
        into out: NSMutableAttributedString
    ) {
        let nsSource = source as NSString
        var content = nsSource.substring(with: segment.range)
        if !content.hasSuffix("\n") { content.append("\n") }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.monospaceFont,
            .foregroundColor: theme.foregroundColor
        ]
        let depth = segment.blockquoteDepth
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            let lineText = String(line) + "\n"
            appendStyled(
                NSAttributedString(string: lineText, attributes: attrs),
                spec: BlockSpec(kind: .paragraph, blockquoteDepth: depth),
                into: out
            )
        }
    }

    private func appendVerbatim(
        in range: NSRange,
        source: String,
        theme: ProseTheme,
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
        theme: ProseTheme
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
        markerAttrs[.proseListMarker] = true
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

    public func paragraphStyle(forListLevel level: Int, theme: ProseTheme) -> NSParagraphStyle {
        paragraphStyleFor(tag: .unorderedListItem, level: 0, blockquoteDepth: 0, listLevel: level, theme: theme)
    }

    public func makeBlockquoteLine(
        depth: Int = 1,
        content: String = "",
        theme: ProseTheme
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
        theme: ProseTheme
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

    private func baseAttributes(theme: ProseTheme) -> [NSAttributedString.Key: Any] {
        [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor
        ]
    }

    private func rangesIntersect(_ a: NSRange, _ b: NSRange) -> Bool {
        let aEnd = a.location + a.length
        let bEnd = b.location + b.length
        return a.location < bEnd && b.location < aEnd
    }

    private func linkDestination(for spanRange: NSRange, in regions: [InlineRegion]) -> String? {
        for region in regions {
            guard case .inlineLink(let dest, _) = region.kind else { continue }
            let regionEnd = region.range.location + region.range.length
            let spanEnd = spanRange.location + spanRange.length
            if spanRange.location >= region.range.location && spanEnd <= regionEnd {
                return dest.isEmpty ? nil : dest
            }
        }
        return nil
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
        let safe = range.clamped(to: source.length)
        var keptUnits: [unichar] = []
        keptUnits.reserveCapacity(safe.length)
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
            projection[srcIdx] = keptUnits.count
            keptUnits.append(source.character(at: absIdx))
            srcIdx += 1
        }
        let out = String(decoding: keptUnits, as: UTF16.self)
        return StripResult(text: out, projection: projection, sourceStart: segStart)
    }
}

