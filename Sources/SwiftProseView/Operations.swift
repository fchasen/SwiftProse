import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum Operations {

    /// Replace `range` with plain `text`, inheriting paragraph attributes
    /// from the character at `range.location` so the inserted text continues
    /// the surrounding block (paragraph, list item, blockquote, etc.).
    @discardableResult
    public static func insertText(
        in storage: NSTextStorage,
        replacing range: NSRange,
        with text: String
    ) -> NSRange {
        let safe = range.clamped(to: storage.length)
        let attrs = inheritedAttributes(in: storage, at: safe.location)
        let attributed = NSAttributedString(string: text, attributes: attrs)
        storage.beginEditing()
        storage.replaceCharacters(in: safe, with: attributed)
        storage.endEditing()
        return NSRange(location: safe.location + (text as NSString).length, length: 0)
    }

    /// Replace `range` with a link rendered as `label` text carrying a `.link`
    /// attribute. The serializer emits `[label](url)` from this. Inherits
    /// surrounding paragraph attributes.
    @discardableResult
    public static func insertLink(
        in storage: NSTextStorage,
        replacing range: NSRange,
        label: String,
        url: String,
        theme: ProseTheme
    ) -> NSRange {
        let safe = range.clamped(to: storage.length)
        var attrs = inheritedAttributes(in: storage, at: safe.location)
        attrs[.link] = url
        attrs[.proseLink] = url
        attrs[.foregroundColor] = theme.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        attrs[.proseInline] = InlineTag.link
        let attributed = NSMutableAttributedString(string: label, attributes: attrs)
        storage.beginEditing()
        storage.replaceCharacters(in: safe, with: attributed)
        storage.endEditing()
        let cursor = safe.location + (label as NSString).length
        return NSRange(location: cursor, length: 0)
    }

    // MARK: - block-level operations
    //
    // These transform the markdown form of the affected paragraph(s),
    // recompile through the supplied compiler, and replace the storage
    // range. Going through markdown keeps the styling logic in one place
    // (the compiler) instead of duplicating font/paragraph-style updates
    // here. The cost is a small re-parse per action — fine because the
    // compiler operates on at most a few paragraphs of source.

    @discardableResult
    public static func setHeading(
        in storage: NSTextStorage,
        range: NSRange,
        level: Int,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme)) { current in
            if level == 0 {
                return BlockSpec(kind: .paragraph,
                                 blockquoteDepth: current.blockquoteDepth,
                                 listLevel: current.listLevel)
            }
            return BlockSpec(kind: .heading(level: level),
                             blockquoteDepth: current.blockquoteDepth)
        }
    }

    @discardableResult
    public static func toggleUnorderedList(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme)) { current in
            if case .unorderedListItem = current.kind {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .unorderedListItem,
                             blockquoteDepth: current.blockquoteDepth,
                             listLevel: current.listLevel)
        }
    }

    @discardableResult
    public static func toggleOrderedList(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme)) { current in
            if case .orderedListItem = current.kind {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .orderedListItem(index: 1),
                             blockquoteDepth: current.blockquoteDepth,
                             listLevel: current.listLevel)
        }
    }

    @discardableResult
    public static func toggleTaskList(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme)) { current in
            if case .taskListItem = current.kind {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .taskListItem(checked: false),
                             blockquoteDepth: current.blockquoteDepth,
                             listLevel: current.listLevel)
        }
    }

    /// When toggling a list on an empty paragraph (or empty editor), tree-sitter
    /// won't recognize "- \n" / "1. \n" / "- [ ] \n" as a list item — the grammar
    /// requires non-empty content. Bypass the markdown round-trip and construct
    /// the marker run directly.
    private static func injectEmptyListIfNeeded(
        in storage: NSTextStorage,
        range: NSRange,
        kind: ListItemKind,
        compiler: MarkdownAttributedCompiler,
        theme: ProseTheme
    ) -> NSRange? {
        let safe = range.clamped(to: storage.length)
        let ns = storage.string as NSString
        let lineRange = storage.length == 0
            ? NSRange(location: 0, length: 0)
            : ns.paragraphRange(for: safe)
        let lineText = lineRange.length > 0 ? ns.substring(with: lineRange) : ""
        let trimmed = lineText
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else { return nil }
        let listItem = compiler.makeListItem(
            kind: kind,
            level: 0,
            orderedIndex: kind == .ordered ? 1 : nil,
            isChecked: kind == .task ? false : nil,
            theme: theme
        )
        storage.beginEditing()
        storage.replaceCharacters(in: lineRange, with: listItem)
        storage.endEditing()
        let cursor = lineRange.location + listItem.length - 1
        return NSRange(location: max(lineRange.location, cursor), length: 0)
    }

    @discardableResult
    public static func toggleBlockquote(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme)) { current in
            if current.blockquoteDepth > 0 {
                return BlockSpec(kind: current.kind,
                                 blockquoteDepth: current.blockquoteDepth - 1,
                                 listLevel: current.listLevel)
            }
            return BlockSpec(kind: current.kind,
                             blockquoteDepth: current.blockquoteDepth + 1,
                             listLevel: current.listLevel)
        }
    }

    private static func injectEmptyBlockquoteIfNeeded(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        theme: ProseTheme
    ) -> NSRange? {
        let safe = range.clamped(to: storage.length)
        let ns = storage.string as NSString
        let lineRange = storage.length == 0
            ? NSRange(location: 0, length: 0)
            : ns.paragraphRange(for: safe)
        let lineText = lineRange.length > 0 ? ns.substring(with: lineRange) : ""
        let trimmed = lineText
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else { return nil }
        let line = compiler.makeBlockquoteLine(theme: theme)
        storage.beginEditing()
        storage.replaceCharacters(in: lineRange, with: line)
        storage.endEditing()
        let cursor = lineRange.location + line.length - 1
        return NSRange(location: max(lineRange.location, cursor), length: 0)
    }

    @discardableResult
    public static func insertCodeBlock(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme)) { current in
            if case .fencedCode = current.kind {
                return BlockSpec(kind: .paragraph, blockquoteDepth: current.blockquoteDepth)
            }
            return BlockSpec(kind: .fencedCode(language: nil),
                             blockquoteDepth: current.blockquoteDepth)
        }
    }

    @discardableResult
    public static func indent(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        if let result = adjustListLevelIfApplicable(
            in: storage, range: range, delta: 1,
            compiler: compiler, theme: theme
        ) { return result }
        return applySpec(in: storage, range: range,
                         env: env(compiler, serializer, theme)) { current in
            BlockSpec(kind: current.kind,
                      blockquoteDepth: current.blockquoteDepth,
                      listLevel: current.listLevel + 1)
        }
    }

    @discardableResult
    public static func outdent(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        if let result = adjustListLevelIfApplicable(
            in: storage, range: range, delta: -1,
            compiler: compiler, theme: theme
        ) { return result }
        return applySpec(in: storage, range: range,
                         env: env(compiler, serializer, theme)) { current in
            BlockSpec(kind: current.kind,
                      blockquoteDepth: current.blockquoteDepth,
                      listLevel: max(0, current.listLevel - 1))
        }
    }

    /// If the cursor sits in a list-item paragraph, adjust the line's nesting
    /// level by `delta`. Returns the new cursor range, or nil if not on a
    /// list-item line. Outdent below level 0 demotes to a plain paragraph.
    /// This bypasses the markdown round-trip because tree-sitter loses parent
    /// context when a single list line is recompiled in isolation.
    private static func adjustListLevelIfApplicable(
        in storage: NSTextStorage,
        range: NSRange,
        delta: Int,
        compiler: MarkdownAttributedCompiler,
        theme: ProseTheme
    ) -> NSRange? {
        guard storage.length > 0 else { return nil }
        let safe = range.clamped(to: storage.length)
        let probe = max(0, min(safe.location, storage.length - 1))
        guard let spec = storage.blockSpec(at: probe), spec.isListItem else {
            return nil
        }
        let ns = storage.string as NSString
        let lineRange = ns.paragraphRange(for: NSRange(location: probe, length: 0))
        guard lineRange.length > 0 else { return nil }

        let newLevel = max(0, spec.listLevel + delta)
        if newLevel == spec.listLevel {
            return NSRange(location: probe, length: 0)
        }

        let kind: ListItemKind
        switch spec.kind {
        case .unorderedListItem: kind = .bullet
        case .orderedListItem: kind = .ordered
        case .taskListItem: kind = .task
        default: return nil
        }
        var orderedIndex: Int?
        if case let .orderedListItem(i) = spec.kind { orderedIndex = i }
        var isChecked: Bool?
        if case let .taskListItem(c) = spec.kind { isChecked = c }

        let newParagraphStyle = compiler.paragraphStyle(forListLevel: newLevel, theme: theme)
        let newSpec: BlockSpec
        switch kind {
        case .bullet: newSpec = BlockSpec(kind: .unorderedListItem, listLevel: newLevel)
        case .ordered: newSpec = BlockSpec(kind: .orderedListItem(index: orderedIndex ?? 1), listLevel: newLevel)
        case .task: newSpec = BlockSpec(kind: .taskListItem(checked: isChecked ?? false), listLevel: newLevel)
        }
        let newSpecBox = BlockSpecBox(newSpec)

        var markerRange = NSRange(location: lineRange.location, length: 0)
        if (storage.safeAttribute(.proseListMarker, at: lineRange.location) as? Bool) == true {
            _ = storage.safeAttribute(.proseListMarker, at: lineRange.location, longestEffectiveRange: &markerRange, in: lineRange)
        }

        var markerAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: newParagraphStyle,
            .proseListMarker: true,
            .proseBlockSpec: newSpecBox
        ]
        let markerString: String
        switch kind {
        case .bullet:
            markerAttrs[.attachment] = BulletGlyphAttachment(level: newLevel, color: theme.foregroundColor)
            markerString = "\u{FFFC} "
        case .ordered:
            let style = OrderedMarkerFormatter.style(forLevel: newLevel)
            markerString = OrderedMarkerFormatter.format(index: orderedIndex ?? 1, style: style) + " "
        case .task:
            let attachment = CheckboxAttachment()
            attachment.isChecked = isChecked ?? false
            markerAttrs[.attachment] = attachment
            markerString = "\u{FFFC} "
        }
        let newMarker = NSAttributedString(string: markerString, attributes: markerAttrs)

        storage.beginEditing()
        storage.replaceCharacters(in: markerRange, with: newMarker)
        let lengthDelta = newMarker.length - markerRange.length
        let updatedLineRange = NSRange(location: lineRange.location, length: lineRange.length + lengthDelta)
        storage.addAttribute(.paragraphStyle, value: newParagraphStyle, range: updatedLineRange)
        storage.addAttribute(.proseBlockSpec, value: newSpecBox, range: updatedLineRange)
        storage.endEditing()

        let cursor = max(updatedLineRange.location, updatedLineRange.location + updatedLineRange.length - 1)
        return NSRange(location: cursor, length: 0)
    }

    private static func demoteListItemToPlain(
        in storage: NSTextStorage,
        lineRange: NSRange,
        theme: ProseTheme
    ) -> NSRange {
        guard lineRange.length > 0,
              lineRange.location + lineRange.length <= storage.length,
              lineRange.location < storage.length else {
            return NSRange(location: lineRange.location, length: 0)
        }
        var markerRange = NSRange(location: lineRange.location, length: 0)
        _ = storage.safeAttribute(.proseListMarker, at: lineRange.location, longestEffectiveRange: &markerRange, in: lineRange)
        let plainAttrs = theme.plainParagraphAttributes()
        storage.beginEditing()
        storage.replaceCharacters(in: markerRange, with: "")
        let bodyLen = lineRange.length - markerRange.length
        let bodyRange = NSRange(location: lineRange.location, length: bodyLen)
        if bodyRange.length > 0 {
            storage.setAttributes(plainAttrs, range: bodyRange)
            storage.removeAttribute(.proseListMarker, range: bodyRange)
        }
        storage.endEditing()
        return NSRange(location: lineRange.location, length: 0)
    }

    @discardableResult
    public static func insertHorizontalRule(
        in storage: NSTextStorage,
        range: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme)) { _ in
            BlockSpec(kind: .horizontalRule)
        }
    }

    /// Apply a `BlockSpec` mutation per paragraph covered by `range`.
    /// Reads the current spec for each paragraph, runs `transform` to
    /// compute the new spec, then dispatches to `Step.setSpec` to render
    /// each line. Returns the cursor at the end of the last touched line.
    private static func applySpec(
        in storage: NSTextStorage,
        range: NSRange,
        env: StepEnvironment,
        transform: (BlockSpec) -> BlockSpec
    ) -> NSRange {
        let safe = range.clamped(to: storage.length)
        let lineRanges = paragraphRanges(in: storage, covering: safe)
        guard !lineRanges.isEmpty else {
            let step = Step.setSpec(lineRange: NSRange(location: 0, length: 0), transform(.paragraph))
            let applied = step.apply(to: storage, env: env)
            return cursorAt(applied.mappedRange)
        }
        var steps: [Step] = []
        for lineRange in lineRanges {
            let probe = max(0, min(lineRange.location, max(0, storage.length - 1)))
            let currentSpec = storage.blockSpec(at: probe) ?? .paragraph
            steps.append(.setSpec(lineRange: lineRange, transform(currentSpec)))
        }
        let applied = Transaction(steps: steps).apply(to: storage, env: env)
        return cursorAt(applied.mappedRange)
    }

    private static func cursorAt(_ range: NSRange) -> NSRange {
        let cursor = max(range.location, range.location + range.length - 1)
        return NSRange(location: cursor, length: 0)
    }

    static func paragraphRanges(
        in storage: NSAttributedString,
        covering range: NSRange
    ) -> [NSRange] {
        guard storage.length > 0 else { return [] }
        let ns = storage.string as NSString
        var ranges: [NSRange] = []
        var cursor = range.location
        let end = max(range.location, range.location + range.length)
        while cursor <= end && cursor < ns.length {
            let line = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(line)
            let next = line.location + line.length
            if next == cursor { break }
            cursor = next
            if cursor >= end && range.length > 0 { break }
        }
        if range.length == 0 && ranges.isEmpty {
            ranges.append(ns.paragraphRange(for: NSRange(location: max(0, min(range.location, ns.length - 1)), length: 0)))
        }
        return ranges
    }

    private static func env(
        _ compiler: MarkdownAttributedCompiler,
        _ serializer: AttributedMarkdownSerializer,
        _ theme: ProseTheme
    ) -> StepEnvironment {
        StepEnvironment(compiler: compiler, serializer: serializer, theme: theme)
    }

    // MARK: - inline format toggles

    @discardableResult
    public static func toggleBold(
        in storage: NSTextStorage,
        range: NSRange,
        theme: ProseTheme
    ) -> NSRange {
        toggleFontTrait(in: storage, range: range, trait: .bold, theme: theme)
    }

    @discardableResult
    public static func toggleItalic(
        in storage: NSTextStorage,
        range: NSRange,
        theme: ProseTheme
    ) -> NSRange {
        toggleFontTrait(in: storage, range: range, trait: .italic, theme: theme)
    }

    @discardableResult
    public static func toggleStrikethrough(
        in storage: NSTextStorage,
        range: NSRange,
        theme: ProseTheme
    ) -> NSRange {
        if range.length == 0 {
            return range.clamped(to: storage.length)
        }
        let safe = range.clamped(to: storage.length)
        let allOn = isUniformAttribute(in: storage, range: safe, key: .strikethroughStyle) { value in
            (value as? Int).map { $0 != 0 } ?? false
        }
        storage.beginEditing()
        if allOn {
            storage.removeAttribute(.strikethroughStyle, range: safe)
        } else {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: safe)
        }
        storage.endEditing()
        return safe
    }

    @discardableResult
    public static func toggleCodeSpan(
        in storage: NSTextStorage,
        range: NSRange,
        theme: ProseTheme
    ) -> NSRange {
        if range.length == 0 {
            return range.clamped(to: storage.length)
        }
        let safe = range.clamped(to: storage.length)
        let allOn = isUniformAttribute(in: storage, range: safe, key: .proseInline) { value in
            (value as? InlineTag) == .codeSpan
        }
        storage.beginEditing()
        if allOn {
            storage.removeAttribute(.proseInline, range: safe)
            storage.removeAttribute(.backgroundColor, range: safe)
            storage.addAttribute(.font, value: theme.bodyFont, range: safe)
        } else {
            storage.addAttribute(.proseInline, value: InlineTag.codeSpan, range: safe)
            storage.addAttribute(.font, value: theme.monospaceFont, range: safe)
            storage.addAttribute(.backgroundColor, value: subtleCodeBackground(theme: theme), range: safe)
        }
        storage.endEditing()
        return safe
    }

    // MARK: - private toggle helpers

    private static func toggleFontTrait(
        in storage: NSTextStorage,
        range: NSRange,
        trait: FontTraits,
        theme: ProseTheme
    ) -> NSRange {
        if range.length == 0 {
            return range.clamped(to: storage.length)
        }
        let safe = range.clamped(to: storage.length)
        let allOn = isUniformFontTrait(in: storage, range: safe, trait: trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: safe) { value, subRange, _ in
            let base = (value as? PlatformFont) ?? theme.bodyFont
            let updated = base.togglingProseTrait(trait, enable: !allOn)
            storage.addAttribute(.font, value: updated, range: subRange)
        }
        storage.endEditing()
        return safe
    }

    private static func isUniformFontTrait(
        in storage: NSTextStorage,
        range: NSRange,
        trait: FontTraits
    ) -> Bool {
        var allOn = true
        var sawAny = false
        storage.enumerateAttribute(.font, in: range) { value, _, stop in
            sawAny = true
            guard let font = value as? PlatformFont, font.proseTraits.contains(trait) else {
                allOn = false
                stop.pointee = true
                return
            }
        }
        return sawAny && allOn
    }

    private static func isUniformAttribute(
        in storage: NSTextStorage,
        range: NSRange,
        key: NSAttributedString.Key,
        predicate: (Any?) -> Bool
    ) -> Bool {
        var allOn = true
        var sawAny = false
        storage.enumerateAttribute(key, in: range) { value, _, stop in
            sawAny = true
            if !predicate(value) {
                allOn = false
                stop.pointee = true
            }
        }
        return sawAny && allOn
    }

    private static func subtleCodeBackground(theme: ProseTheme) -> PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.12)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.12)
        #endif
    }

    // MARK: - helpers

    /// Read the attributes at `location` to seed inserted text. If the
    /// storage is empty or location is at the very end, fall back to a
    /// minimal paragraph style.
    private static func inheritedAttributes(
        in storage: NSTextStorage,
        at location: Int
    ) -> [NSAttributedString.Key: Any] {
        let safe = max(0, min(location, storage.length))
        if storage.length == 0 {
            return [:]
        }
        let probe = (safe >= storage.length) ? storage.length - 1 : safe
        let raw = storage.attributes(at: probe, effectiveRange: nil)
        // Strip inline-only adornments — link/code-span etc. should not
        // leak into newly-typed plain text.
        var carry: [NSAttributedString.Key: Any] = [:]
        for key in [
            NSAttributedString.Key.font,
            .foregroundColor,
            .paragraphStyle,
            .proseBlockSpec
        ] {
            if let v = raw[key] { carry[key] = v }
        }
        return carry
    }
}
