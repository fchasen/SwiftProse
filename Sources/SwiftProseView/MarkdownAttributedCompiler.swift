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
    /// ProseMirror-aligned schema used by the stamping pass that adds
    /// `proseNodePath` and `proseMarks` to compiled storage. Defaults to
    /// `Schema.defaultMarkdown`; callers wanting a custom schema can
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
    /// `ProseDocument.from(storage:)`.
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
            appendPipeTable(segment, source: source, theme: theme, into: out)
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
                if k == .font, let stylingFont = v as? PlatformFont {
                    let baseRun = attributed.safeAttribute(.font, at: safe.location) as? PlatformFont
                    let merged = mergedStyleFont(stylingFont, base: baseRun)
                    attributed.addAttribute(.font, value: merged, range: safe)
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
        let baseStyle = paragraphStyleFor(tag: segment.tag,
                                           level: 0,
                                           blockquoteDepth: segment.blockquoteDepth,
                                           listLevel: segment.listLevel,
                                           theme: theme)
        let paragraphAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.monospaceFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: baseStyle
        ]
        var content = extractCodeBlockBody(from: raw, tag: segment.tag)
        if !content.hasSuffix("\n") { content.append("\n") }
        let attributed = NSMutableAttributedString(string: content, attributes: paragraphAttrs)
        applyCodeBlockHighlights(to: attributed, segment: segment, source: source, theme: theme)
        applyCodeBlockEdgeMargins(to: attributed, baseStyle: baseStyle)
        appendStyled(attributed, spec: BlockSpec(blockSegment: segment), into: out)
    }

    /// Stamp `paragraphSpacingBefore` on the first paragraph of a code block
    /// and `paragraphSpacing` on the last so the BG painter has room for an
    /// outer margin equal to the inner BG padding. Internal lines keep the
    /// base style so the per-line BG fragments stitch flush.
    private func applyCodeBlockEdgeMargins(
        to attributed: NSMutableAttributedString,
        baseStyle: NSParagraphStyle
    ) {
        let total = attributed.length
        guard total > 0 else { return }
        // 4pt of BG padding + 4pt of outer margin on each end. Keep in sync
        // with `CodeBlockLayoutFragment.verticalPadding`.
        let edgeSpacing: CGFloat = 8
        let ns = attributed.string as NSString
        let firstParaRange = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        let lastProbe = NSRange(location: max(0, total - 1), length: 0)
        let lastParaRange = ns.paragraphRange(for: lastProbe)

        if firstParaRange == lastParaRange {
            let style = (baseStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = edgeSpacing
            style.paragraphSpacing = edgeSpacing
            attributed.addAttribute(.paragraphStyle, value: style.copy(), range: firstParaRange)
            return
        }
        let firstStyle = (baseStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        firstStyle.paragraphSpacingBefore = edgeSpacing
        attributed.addAttribute(.paragraphStyle, value: firstStyle.copy(), range: firstParaRange)

        let lastStyle = (baseStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        lastStyle.paragraphSpacing = edgeSpacing
        attributed.addAttribute(.paragraphStyle, value: lastStyle.copy(), range: lastParaRange)
    }

    /// Extract the code body from a raw segment, stripping fence delimiters
    /// (fenced) or the leading 4-space indent (indented). Mirrors the source
    /// markup the serializer reconstructs from the leaf's `language` /
    /// `fenced` attrs, so storage holds only the document content.
    private func extractCodeBlockBody(from raw: String, tag: BlockTag) -> String {
        switch tag {
        case .fencedCode:
            let lines = raw.components(separatedBy: "\n")
            guard lines.count >= 2 else { return "" }
            var bodyLines = Array(lines.dropFirst())
            if bodyLines.last == "" { bodyLines.removeLast() }
            if let last = bodyLines.last, isFenceLine(last) {
                bodyLines.removeLast()
            }
            return bodyLines.joined(separator: "\n")
        case .indentedCode:
            let lines = raw.components(separatedBy: "\n")
            let stripped = lines.map { line -> String in
                var prefix = 0
                for ch in line {
                    guard ch == " ", prefix < 4 else { break }
                    prefix += 1
                }
                return String(line.dropFirst(prefix))
            }
            return stripped.joined(separator: "\n")
        default:
            return raw
        }
    }

    private func applyCodeBlockHighlights(
        to attributed: NSMutableAttributedString,
        segment: BlockSegment,
        source: String,
        theme: ProseTheme
    ) {
        guard let highlighter = codeBlockHighlighter else { return }
        let body = (attributed.string as NSString).substring(
            to: max(0, attributed.length - (attributed.string.hasSuffix("\n") ? 1 : 0))
        )
        let resolved: String?
        if let explicit = segment.language, !explicit.isEmpty {
            resolved = explicit
        } else {
            resolved = highlighter.detectLanguage(for: body)
        }
        let spans = highlighter.highlights(for: body, language: resolved)
        guard !spans.isEmpty else { return }
        let attributedLength = attributed.length
        for span in spans {
            guard let color = theme.codeColor(for: span.tag) else { continue }
            let start = span.range.location
            let end = start + span.range.length
            guard start >= 0, end <= attributedLength, start < end else { continue }
            attributed.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: start, length: end - start)
            )
        }
    }

    private func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    /// Re-run the registered `CodeBlockHighlighter` over the body of an
    /// existing code-block run in `storage` and stamp its colors. Storage
    /// already holds just the body — fences live only in the leaf's attrs
    /// — so the block range maps to the body 1:1.
    public func rehighlightCodeBlock(
        in storage: NSTextStorage,
        blockRange: NSRange,
        language: String?,
        isFenced: Bool,
        theme: ProseTheme
    ) {
        guard let highlighter = codeBlockHighlighter else { return }
        guard blockRange.location >= 0,
              blockRange.length > 0,
              blockRange.location + blockRange.length <= storage.length else { return }
        let raw = (storage.string as NSString).substring(with: blockRange)
        let body = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        let resolved: String?
        if let language, !language.isEmpty {
            resolved = language
        } else {
            resolved = highlighter.detectLanguage(for: body)
        }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: theme.foregroundColor, range: blockRange)
        let spans = highlighter.highlights(for: body, language: resolved)
        for span in spans {
            guard let color = theme.codeColor(for: span.tag) else { continue }
            let start = blockRange.location + span.range.location
            let end = start + span.range.length
            guard start >= blockRange.location,
                  end <= blockRange.location + blockRange.length,
                  start < end else { continue }
            storage.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: start, length: end - start)
            )
        }
        storage.endEditing()
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

    /// Emit a pipe-table segment as a single `ProseNodeAttachment` paragraph.
    /// Storage carries `￼\n` (the attachment's object-replacement char plus
    /// a paragraph-closing newline), stamped with `proseNodePath` ending at
    /// the `table` node — `table` is `isolating`, so the reverse-projection
    /// in `ProseDocument.from(storage:)` lifts `attachment.subtree`'s
    /// children (the rows) into the document tree at this position. The
    /// attachment's structural subtree is the canonical cell store; view
    /// providers render the grid; commands mutate `attachment.subtree`.
    ///
    /// Falls back to plaintext-paragraph emit when the segment isn't a
    /// well-formed pipe table (no alignment row).
    private func appendPipeTable(
        _ segment: BlockSegment,
        source: String,
        theme: ProseTheme,
        into out: NSMutableAttributedString
    ) {
        let nsSource = source as NSString
        let raw = nsSource.substring(with: segment.range)
        let depth = segment.blockquoteDepth

        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map { stripBlockquotePrefix($0, depth: depth) }

        guard lines.count >= 2,
              let alignments = parsePipeAlignmentRow(lines[1]) else {
            appendPipeTableAsPlainParagraphs(segment, source: source, theme: theme, into: out)
            return
        }

        let headerCells = parsePipeRow(lines[0])
        let bodyRows = lines.dropFirst(2).map { parsePipeRow($0) }
        let cols = max(headerCells.count, alignments.count, bodyRows.map(\.count).max() ?? 0)
        guard cols > 0 else {
            appendPipeTableAsPlainParagraphs(segment, source: source, theme: theme, into: out)
            return
        }

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor
        ]
        let subtree = buildTableSubtree(
            headerCells: headerCells,
            bodyRows: Array(bodyRows),
            alignments: alignments,
            cols: cols,
            theme: theme,
            baseAttrs: baseAttrs
        )

        appendTableAttachment(
            subtree: subtree,
            blockquoteDepth: depth,
            theme: theme,
            into: out
        )
    }

    /// Build the structural `TreeNode` representation of a pipe table.
    /// Each cell paragraph carries inline runs with proper `MarkSet`s
    /// (derived via `compileCellInline` + `NodePathSynthesizer`) so the
    /// tree round-trips marks without further work.
    private func buildTableSubtree(
        headerCells: [String],
        bodyRows: [[String]],
        alignments: [PipeTableAlignment],
        cols: Int,
        theme: ProseTheme,
        baseAttrs: [NSAttributedString.Key: Any]
    ) -> TreeNode {
        func cellTree(text: String, isHeader: Bool, col: Int) -> TreeNode {
            let alignment = col < alignments.count ? alignments[col] : .none
            let cellNode = makeTableCellNode(isHeader: isHeader, alignment: alignment)
            let inlineRuns = cellInlineRuns(text, theme: theme, baseAttrs: baseAttrs)
            let para = TreeNode.structural(ProseNode(type: "paragraph"), inlineRuns)
            return .structural(cellNode, [para])
        }

        var rows: [TreeNode] = []
        let headerRowNode = ProseNode(type: "table_row", attrs: ["header": .bool(true)])
        var headerKids: [TreeNode] = []
        for col in 0..<cols {
            let text = col < headerCells.count ? headerCells[col] : ""
            headerKids.append(cellTree(text: text, isHeader: true, col: col))
        }
        rows.append(.structural(headerRowNode, headerKids))

        for body in bodyRows {
            let rowNode = ProseNode(type: "table_row", attrs: ["header": .bool(false)])
            var kids: [TreeNode] = []
            for col in 0..<cols {
                let text = col < body.count ? body[col] : ""
                kids.append(cellTree(text: text, isHeader: false, col: col))
            }
            rows.append(.structural(rowNode, kids))
        }

        return .structural(ProseNode(type: "table"), rows)
    }

    /// Convert a cell's source text into a list of `.inline(text, marks)`
    /// `TreeNode`s by running the inline parser, mapping highlight spans
    /// to font/proseInline rendering attrs, then synthesizing `MarkSet`s
    /// via `NodePathSynthesizer`. Empty text → empty list.
    private func cellInlineRuns(
        _ text: String,
        theme: ProseTheme,
        baseAttrs: [NSAttributedString.Key: Any]
    ) -> [TreeNode] {
        guard !text.isEmpty else { return [] }
        let attributed = compileCellInline(text, theme: theme, baseAttrs: baseAttrs)
        let mutable = NSMutableAttributedString(attributedString: attributed)
        guard mutable.length > 0 else { return [] }
        let fullRange = NSRange(location: 0, length: mutable.length)
        NodePathSynthesizer(schema: schema).stampMarks(
            in: mutable,
            blockRange: fullRange,
            spec: .paragraph
        )
        var runs: [TreeNode] = []
        let ns = mutable.string as NSString
        mutable.enumerateAttribute(.proseMarks, in: fullRange) { value, runRange, _ in
            guard runRange.length > 0 else { return }
            let marks = (value as? MarkSetBox)?.marks ?? MarkSet()
            let runText = ns.substring(with: runRange)
            if !runText.isEmpty {
                runs.append(.inline(text: runText, marks: marks))
            }
        }
        return runs
    }

    /// Emit the actual attachment paragraph for a structural table
    /// subtree. Storage layout: one `\u{FFFC}` carrying the attachment +
    /// one `\n`, both stamped with `proseNodePath = [doc, blockquote*, table]`.
    private func appendTableAttachment(
        subtree: TreeNode,
        blockquoteDepth depth: Int,
        theme: ProseTheme,
        into out: NSMutableAttributedString
    ) {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor
        ]
        let attachment = ProseNodeAttachment(subtree: subtree)
        let attachmentRun = NSMutableAttributedString(attachment: attachment)
        attachmentRun.addAttributes(
            baseAttrs,
            range: NSRange(location: 0, length: attachmentRun.length)
        )
        attachmentRun.append(NSAttributedString(string: "\n", attributes: baseAttrs))

        let startIdx = out.length
        out.append(attachmentRun)
        let range = NSRange(location: startIdx, length: out.length - startIdx)

        let predecessor: NodePath? = startIdx > 0 ? out.nodePath(at: startIdx - 1) : nil
        let docNode = predecessor?.root ?? ProseNode(
            type: schema.topNodeName,
            attrs: schema.topNode.defaultAttrs()
        )
        var nodes: [ProseNode] = [docNode]
        let prevQuotes = predecessor?.nodes.filter { $0.type == "blockquote" } ?? []
        for i in 0..<depth {
            if i < prevQuotes.count {
                nodes.append(prevQuotes[i])
            } else {
                nodes.append(ProseNode(type: "blockquote"))
            }
        }
        let tableNode: ProseNode
        if case .structural(let t, _) = subtree {
            tableNode = t
        } else {
            tableNode = ProseNode(type: "table")
        }
        nodes.append(tableNode)
        out.setNodePath(NodePath(nodes), in: range)
        out.addAttribute(.proseMarks, value: MarkSetBox(MarkSet()), range: range)
    }

    /// Plaintext fallback — used when the segment doesn't parse as a
    /// well-formed pipe table. Emits each source line as a literal
    /// paragraph and groups them under a shared `table` ancestor so the
    /// serializer's `emitTable` fallback round-trips the source bytes.
    private func appendPipeTableAsPlainParagraphs(
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
        let startIdx = out.length
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            let lineText = String(line) + "\n"
            appendStyled(
                NSAttributedString(string: lineText, attributes: attrs),
                spec: BlockSpec(kind: .paragraph, blockquoteDepth: depth),
                into: out
            )
        }
        let tableNode = ProseNode(type: "table")
        let range = NSRange(location: startIdx, length: out.length - startIdx)
        out.enumerateNodePaths(in: range) { runRange, path in
            guard !path.nodes.isEmpty else { return }
            var nodes = path.nodes
            let leaf = nodes.removeLast()
            nodes.append(tableNode)
            nodes.append(leaf)
            out.setNodePath(NodePath(nodes), in: runRange)
        }
    }

    private func makeTableCellNode(
        isHeader: Bool,
        alignment: PipeTableAlignment
    ) -> ProseNode {
        let alignAttr: ProseAttrValue
        switch alignment {
        case .none: alignAttr = .null
        case .left: alignAttr = .string("left")
        case .right: alignAttr = .string("right")
        case .center: alignAttr = .string("center")
        }
        return ProseNode(
            type: isHeader ? "table_header" : "table_cell",
            attrs: [
                "align": alignAttr,
                "colspan": .int(1),
                "rowspan": .int(1),
                "colwidth": .null
            ]
        )
    }

    private func parsePipeRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func parsePipeAlignmentRow(_ line: String) -> [PipeTableAlignment]? {
        let cells = parsePipeRow(line)
        guard !cells.isEmpty else { return nil }
        var aligns: [PipeTableAlignment] = []
        for cell in cells {
            guard let a = PipeTableAlignment(alignmentRowCell: cell) else { return nil }
            aligns.append(a)
        }
        return aligns
    }

    /// Render a single pipe-table cell's text as inline-marked content.
    /// Runs the inline parser on `text` in isolation so marks inside
    /// cells (`**bold**`, `*em*`, `` `code` ``, `[link](url)`) survive.
    /// Emits a flat attributed string; per-cell `proseNodePath` is
    /// stamped by the caller after `appendStyled`.
    private func compileCellInline(
        _ text: String,
        theme: ProseTheme,
        baseAttrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard !text.isEmpty,
              let tree = inlineParser.parse(text),
              let root = tree.rootNode else {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }
        let mapping = inlineParser.mapping
        let highlights = highlighter.highlights(
            rootNode: root, in: tree, mapping: mapping, grammar: .inline
        )
        let regions = InlineClassifier.classify(rootNode: root, mapping: mapping)
        let nsText = text as NSString
        let segRange = NSRange(location: 0, length: nsText.length)
        let stripRanges = highlights
            .filter { $0.tag == .punctuationDelimiter }
            .map { $0.range }
        let strip = unionRanges(stripRanges)
        let stripped = stripCharacters(in: segRange, source: nsText, stripping: strip)

        var styleRuns: [(NSRange, [NSAttributedString.Key: Any])] = []
        for span in highlights where span.tag != .punctuationDelimiter {
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
                var linkAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .proseInline: InlineTag.link
                ]
                if let dest = linkDestination(for: span.range, in: regions) {
                    linkAttrs[.proseLink] = dest
                    if let url = URL(string: dest) {
                        linkAttrs[.link] = url
                    } else {
                        linkAttrs[.link] = dest
                    }
                }
                styleRuns.append((projected, linkAttrs))
            default:
                break
            }
        }

        let attributed = NSMutableAttributedString(string: stripped.text, attributes: baseAttrs)
        for (range, runAttrs) in styleRuns {
            let safe = range.clamped(to: attributed.length)
            guard safe.length > 0 else { continue }
            for (k, v) in runAttrs {
                if k == .font, let stylingFont = v as? PlatformFont {
                    let baseRun = attributed.safeAttribute(.font, at: safe.location) as? PlatformFont
                    let merged = mergedStyleFont(stylingFont, base: baseRun)
                    attributed.addAttribute(.font, value: merged, range: safe)
                } else {
                    attributed.addAttribute(k, value: v, range: safe)
                }
            }
        }
        return attributed
    }

    private func stripBlockquotePrefix(_ line: String, depth: Int) -> String {
        guard depth > 0 else { return line }
        var s = line
        for _ in 0..<depth {
            if s.hasPrefix("> ") {
                s.removeFirst(2)
            } else if s.hasPrefix(">") {
                s.removeFirst(1)
            } else {
                break
            }
        }
        return s
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
            // Internal code-block lines stay flush; the compiler stamps the
            // first and last paragraphs of the block with extra spacing in
            // `applyCodeBlockEdgeMargins` so the BG painter can carve out a
            // matching outer margin.
            style.paragraphSpacing = 0
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

    /// Combine an inline-style font (`v` from a `styleRuns` entry) with the
    /// run's existing base font. Monospace styling resizes to the base's
    /// pointSize and inherits its bold weight, so a code span inside a
    /// heading still reads as a heading-sized run. Bold/italic styling
    /// unions onto the base run's existing traits.
    private func mergedStyleFont(_ styling: PlatformFont, base: PlatformFont?) -> PlatformFont {
        guard let base else { return styling }
        if styling.isMonospace {
            let isBold = base.proseTraits.contains(.bold)
            let weight: PlatformFont.Weight = isBold ? .semibold : .regular
            #if canImport(AppKit) && os(macOS)
            return NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: weight)
            #else
            return UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: weight)
            #endif
        }
        let stylingTraits = styling.proseTraits
        if !stylingTraits.isEmpty {
            return base.withProseTraits(base.proseTraits.union(stylingTraits))
        }
        return styling
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

