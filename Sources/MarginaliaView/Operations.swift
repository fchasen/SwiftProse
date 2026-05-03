import Foundation
import MarginaliaSyntax
import MarginaliaRendering
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
        let safe = clampedRange(range, in: storage.length)
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
        theme: MarginaliaTheme
    ) -> NSRange {
        let safe = clampedRange(range, in: storage.length)
        var attrs = inheritedAttributes(in: storage, at: safe.location)
        attrs[.link] = url
        attrs[.marginaliaLink] = url
        attrs[.foregroundColor] = theme.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        attrs[.marginaliaInline] = InlineTag.link
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme, dialect, mode)) { current in
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme, dialect, mode)) { current in
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme, dialect, mode)) { current in
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme, dialect, mode)) { current in
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
        theme: MarginaliaTheme
    ) -> NSRange? {
        let safe = clampedRange(range, in: storage.length)
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme, dialect, mode)) { current in
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
        theme: MarginaliaTheme
    ) -> NSRange? {
        let safe = clampedRange(range, in: storage.length)
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme, dialect, mode)) { current in
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        if let result = adjustListLevelIfApplicable(
            in: storage, range: range, delta: 1,
            compiler: compiler, theme: theme
        ) { return result }
        return applySpec(in: storage, range: range,
                         env: env(compiler, serializer, theme, dialect, mode)) { current in
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        if let result = adjustListLevelIfApplicable(
            in: storage, range: range, delta: -1,
            compiler: compiler, theme: theme
        ) { return result }
        return applySpec(in: storage, range: range,
                         env: env(compiler, serializer, theme, dialect, mode)) { current in
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
        theme: MarginaliaTheme
    ) -> NSRange? {
        guard storage.length > 0 else { return nil }
        let safe = clampedRange(range, in: storage.length)
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
        let orderedIndex: Int? = {
            if case .orderedListItem(let i) = spec.kind { return i } else { return nil }
        }()
        let isChecked: Bool? = {
            if case .taskListItem(let c) = spec.kind { return c } else { return nil }
        }()

        let newParagraphStyle = compiler.paragraphStyle(forListLevel: newLevel, theme: theme)
        let newSpec: BlockSpec
        switch kind {
        case .bullet: newSpec = BlockSpec(kind: .unorderedListItem, listLevel: newLevel)
        case .ordered: newSpec = BlockSpec(kind: .orderedListItem(index: orderedIndex ?? 1), listLevel: newLevel)
        case .task: newSpec = BlockSpec(kind: .taskListItem(checked: isChecked ?? false), listLevel: newLevel)
        }
        let newSpecBox = BlockSpecBox(newSpec)

        var markerRange = NSRange(location: lineRange.location, length: 0)
        if (storage.safeAttribute(.marginaliaListMarker, at: lineRange.location) as? Bool) == true {
            _ = storage.safeAttribute(.marginaliaListMarker, at: lineRange.location, longestEffectiveRange: &markerRange, in: lineRange)
        }

        var markerAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: newParagraphStyle,
            .marginaliaListMarker: true,
            .marginaliaBlockSpec: newSpecBox
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
        let delta_len = newMarker.length - markerRange.length
        let updatedLineLen = lineRange.length + delta_len
        let updatedLineRange = NSRange(location: lineRange.location, length: updatedLineLen)
        storage.addAttribute(.paragraphStyle, value: newParagraphStyle, range: updatedLineRange)
        storage.addAttribute(.marginaliaBlockSpec, value: newSpecBox, range: updatedLineRange)
        storage.endEditing()

        let cursor = max(updatedLineRange.location, updatedLineRange.location + updatedLineRange.length - 1)
        return NSRange(location: cursor, length: 0)
    }

    private static func demoteListItemToPlain(
        in storage: NSTextStorage,
        lineRange: NSRange,
        theme: MarginaliaTheme
    ) -> NSRange {
        guard lineRange.length > 0,
              lineRange.location + lineRange.length <= storage.length,
              lineRange.location < storage.length else {
            return NSRange(location: lineRange.location, length: 0)
        }
        var markerRange = NSRange(location: lineRange.location, length: 0)
        _ = storage.safeAttribute(.marginaliaListMarker, at: lineRange.location, longestEffectiveRange: &markerRange, in: lineRange)
        let plainAttrs: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont,
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: NSParagraphStyle(),
            .marginaliaBlockSpec: BlockSpecBox(.paragraph)
        ]
        storage.beginEditing()
        storage.replaceCharacters(in: markerRange, with: "")
        let bodyLen = lineRange.length - markerRange.length
        let bodyRange = NSRange(location: lineRange.location, length: bodyLen)
        if bodyRange.length > 0 {
            storage.setAttributes(plainAttrs, range: bodyRange)
            storage.removeAttribute(.marginaliaListMarker, range: bodyRange)
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
        dialect: Dialect,
        mode: Mode,
        theme: MarginaliaTheme
    ) -> NSRange {
        applySpec(in: storage, range: range,
                  env: env(compiler, serializer, theme, dialect, mode)) { _ in
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
        let safe = clampedRange(range, in: storage.length)
        let lineRanges = paragraphRanges(in: storage, covering: safe)
        guard !lineRanges.isEmpty else {
            // Empty storage: apply to a zero-length range at 0.
            let step = Step.setSpec(lineRange: NSRange(location: 0, length: 0), transform(.paragraph))
            let applied = step.apply(to: storage, env: env)
            let cursor = max(applied.mappedRange.location,
                             applied.mappedRange.location + applied.mappedRange.length - 1)
            return NSRange(location: cursor, length: 0)
        }
        // Iterate from last to first so prior step's range remains valid for
        // the next iteration without re-computing offsets.
        var lastMappedRange = NSRange(location: lineRanges.last!.location, length: 0)
        for lineRange in lineRanges.reversed() {
            let probe = max(0, min(lineRange.location, max(0, storage.length - 1)))
            let currentSpec = storage.blockSpec(at: probe) ?? .paragraph
            let newSpec = transform(currentSpec)
            let step = Step.setSpec(lineRange: lineRange, newSpec)
            let applied = step.apply(to: storage, env: env)
            // Cursor lands at end of the FIRST applied line (which, since
            // we iterate in reverse, is the last iteration of the loop).
            lastMappedRange = applied.mappedRange
        }
        let cursor = max(lastMappedRange.location,
                         lastMappedRange.location + lastMappedRange.length - 1)
        return NSRange(location: cursor, length: 0)
    }

    /// Enumerate each paragraph (line) range that intersects `range`.
    private static func paragraphRanges(
        in storage: NSTextStorage,
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
        _ theme: MarginaliaTheme,
        _ dialect: Dialect,
        _ mode: Mode
    ) -> StepEnvironment {
        StepEnvironment(compiler: compiler, serializer: serializer, theme: theme, dialect: dialect, mode: mode)
    }

    // MARK: - inline format toggles

    @discardableResult
    public static func toggleBold(
        in storage: NSTextStorage,
        range: NSRange,
        theme: MarginaliaTheme
    ) -> NSRange {
        toggleFontTrait(in: storage, range: range, trait: .bold, theme: theme, placeholder: "bold")
    }

    @discardableResult
    public static func toggleItalic(
        in storage: NSTextStorage,
        range: NSRange,
        theme: MarginaliaTheme
    ) -> NSRange {
        toggleFontTrait(in: storage, range: range, trait: .italic, theme: theme, placeholder: "italic")
    }

    @discardableResult
    public static func toggleStrikethrough(
        in storage: NSTextStorage,
        range: NSRange,
        theme: MarginaliaTheme
    ) -> NSRange {
        if range.length == 0 {
            return insertStyledPlaceholder(
                in: storage,
                at: range.location,
                placeholder: "strike",
                theme: theme
            ) { attrs in
                var a = attrs
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                return a
            }
        }
        let safe = clampedRange(range, in: storage.length)
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
        theme: MarginaliaTheme
    ) -> NSRange {
        if range.length == 0 {
            return insertStyledPlaceholder(
                in: storage,
                at: range.location,
                placeholder: "code",
                theme: theme
            ) { attrs in
                var a = attrs
                a[.font] = theme.monospaceFont
                a[.marginaliaInline] = InlineTag.codeSpan
                a[.backgroundColor] = subtleCodeBackground(theme: theme)
                return a
            }
        }
        let safe = clampedRange(range, in: storage.length)
        let allOn = isUniformAttribute(in: storage, range: safe, key: .marginaliaInline) { value in
            (value as? InlineTag) == .codeSpan
        }
        storage.beginEditing()
        if allOn {
            storage.removeAttribute(.marginaliaInline, range: safe)
            storage.removeAttribute(.backgroundColor, range: safe)
            storage.addAttribute(.font, value: theme.bodyFont, range: safe)
        } else {
            storage.addAttribute(.marginaliaInline, value: InlineTag.codeSpan, range: safe)
            storage.addAttribute(.font, value: theme.monospaceFont, range: safe)
            storage.addAttribute(.backgroundColor, value: subtleCodeBackground(theme: theme), range: safe)
        }
        storage.endEditing()
        return safe
    }

    // MARK: - private toggle helpers

    private enum FontTrait { case bold, italic }

    private static func toggleFontTrait(
        in storage: NSTextStorage,
        range: NSRange,
        trait: FontTrait,
        theme: MarginaliaTheme,
        placeholder: String
    ) -> NSRange {
        if range.length == 0 {
            return insertStyledPlaceholder(
                in: storage,
                at: range.location,
                placeholder: placeholder,
                theme: theme
            ) { attrs in
                var a = attrs
                let baseFont = (a[.font] as? PlatformFont) ?? theme.bodyFont
                a[.font] = applyTrait(trait, on: baseFont, enable: true)
                return a
            }
        }
        let safe = clampedRange(range, in: storage.length)
        let allOn = isUniformFontTrait(in: storage, range: safe, trait: trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: safe) { value, subRange, _ in
            let base = (value as? PlatformFont) ?? theme.bodyFont
            let updated = applyTrait(trait, on: base, enable: !allOn)
            storage.addAttribute(.font, value: updated, range: subRange)
        }
        storage.endEditing()
        return safe
    }

    private static func insertStyledPlaceholder(
        in storage: NSTextStorage,
        at location: Int,
        placeholder: String,
        theme: MarginaliaTheme,
        styling: (inout [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]
    ) -> NSRange {
        let safe = max(0, min(location, storage.length))
        var attrs = inheritedAttributes(in: storage, at: safe)
        attrs = styling(&attrs)
        let inserted = NSAttributedString(string: placeholder, attributes: attrs)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: safe, length: 0), with: inserted)
        storage.endEditing()
        return NSRange(location: safe, length: (placeholder as NSString).length)
    }

    private static func isUniformFontTrait(
        in storage: NSTextStorage,
        range: NSRange,
        trait: FontTrait
    ) -> Bool {
        var allOn = true
        var sawAny = false
        storage.enumerateAttribute(.font, in: range) { value, _, stop in
            sawAny = true
            let font = value as? PlatformFont
            if font == nil || !hasTrait(trait, on: font!) {
                allOn = false
                stop.pointee = true
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

    private static func subtleCodeBackground(theme: MarginaliaTheme) -> PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.12)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.12)
        #endif
    }

    // MARK: - helpers

    private static func clampedRange(_ range: NSRange, in length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        let remaining = max(0, length - location)
        return NSRange(location: location, length: max(0, min(range.length, remaining)))
    }

    private static func hasTrait(_ trait: FontTrait, on font: PlatformFont) -> Bool {
        #if canImport(AppKit) && os(macOS)
        let symbolic = font.fontDescriptor.symbolicTraits
        switch trait {
        case .bold: return symbolic.contains(.bold)
        case .italic: return symbolic.contains(.italic)
        }
        #else
        let symbolic = font.fontDescriptor.symbolicTraits
        switch trait {
        case .bold: return symbolic.contains(.traitBold)
        case .italic: return symbolic.contains(.traitItalic)
        }
        #endif
    }

    private static func applyTrait(_ trait: FontTrait, on font: PlatformFont, enable: Bool) -> PlatformFont {
        #if canImport(AppKit) && os(macOS)
        var symbolic = font.fontDescriptor.symbolicTraits
        let toggle: NSFontDescriptor.SymbolicTraits = (trait == .bold) ? .bold : .italic
        if enable { symbolic.insert(toggle) } else { symbolic.remove(toggle) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        var symbolic = font.fontDescriptor.symbolicTraits
        let toggle: UIFontDescriptor.SymbolicTraits = (trait == .bold) ? .traitBold : .traitItalic
        if enable { symbolic.insert(toggle) } else { symbolic.remove(toggle) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
        #endif
    }

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
            .marginaliaBlockSpec
        ] {
            if let v = raw[key] { carry[key] = v }
        }
        return carry
    }
}
