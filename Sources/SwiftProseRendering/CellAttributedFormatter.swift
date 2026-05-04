import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftProseSyntax

/// Lightweight inline-markdown formatter for a single pipe-table cell. Takes
/// a plain cell string and returns an `NSAttributedString` with bold, italic,
/// code spans, and links resolved. Cells are short and well-bounded (no
/// newlines), so a regex pass is sufficient — full tree-sitter inline
/// parsing per cell would be wasteful.
///
/// Precedence matters: code spans are extracted first because their content
/// is literal and must not be mistaken for emphasis markers. Links come
/// next so their label text can still pick up bold/italic. `**` and `__`
/// run before `*` and `_` so `***x***` resolves to bold-italic without the
/// double-star regex stealing the inner italic markers.
public struct CellAttributedFormatter {
    public var bodyFont: PlatformFont
    public var monospaceFont: PlatformFont
    public var foregroundColor: PlatformColor
    public var linkColor: PlatformColor
    public var codeBackground: PlatformColor
    public var bold: Bool

    public init(
        bodyFont: PlatformFont,
        monospaceFont: PlatformFont,
        foregroundColor: PlatformColor,
        linkColor: PlatformColor,
        codeBackground: PlatformColor,
        bold: Bool = false
    ) {
        self.bodyFont = bodyFont
        self.monospaceFont = monospaceFont
        self.foregroundColor = foregroundColor
        self.linkColor = linkColor
        self.codeBackground = codeBackground
        self.bold = bold
    }

    public func format(_ source: String) -> NSAttributedString {
        let baseFont = bold ? bodyFont.withProseTraits(.bold) : bodyFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: foregroundColor
        ]
        let mutable = NSMutableAttributedString(string: source, attributes: attrs)
        applyCodeSpans(mutable)
        applyLinks(mutable)
        applyEmphasis(mutable, marker: "**", trait: .bold)
        applyEmphasis(mutable, marker: "__", trait: .bold)
        applyEmphasis(mutable, marker: "*", trait: .italic)
        applyEmphasis(mutable, marker: "_", trait: .italic)
        return mutable
    }

    private func applyCodeSpans(_ s: NSMutableAttributedString) {
        let pattern = "`([^`\\n]+?)`"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        var searchStart = 0
        while searchStart < s.length {
            let searchRange = NSRange(location: searchStart, length: s.length - searchStart)
            guard let m = regex.firstMatch(in: s.string, range: searchRange) else { break }
            let full = m.range
            let inner = m.range(at: 1)
            guard inner.length > 0 else {
                searchStart = full.location + full.length
                continue
            }
            let text = (s.string as NSString).substring(with: inner)
            let replacement = NSAttributedString(
                string: text,
                attributes: [
                    .font: monospaceFont,
                    .foregroundColor: foregroundColor,
                    .backgroundColor: codeBackground,
                    .proseInline: InlineTag.codeSpan
                ]
            )
            s.replaceCharacters(in: full, with: replacement)
            searchStart = full.location + replacement.length
        }
    }

    private func applyLinks(_ s: NSMutableAttributedString) {
        let pattern = #"\[([^\]\n]+)\]\(([^)\n\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        var searchStart = 0
        while searchStart < s.length {
            let searchRange = NSRange(location: searchStart, length: s.length - searchStart)
            guard let m = regex.firstMatch(in: s.string, range: searchRange) else { break }
            let full = m.range
            let labelRange = m.range(at: 1)
            let urlRange = m.range(at: 2)
            if hasCodeSpan(in: full, of: s) {
                searchStart = full.location + full.length
                continue
            }
            let url = (s.string as NSString).substring(with: urlRange)
            // Preserve any styling already applied to the label text (bold,
            // italic) by extracting the inner attributed substring and
            // overlaying link attributes.
            let inner = s.attributedSubstring(from: labelRange)
            let mut = NSMutableAttributedString(attributedString: inner)
            let labelAll = NSRange(location: 0, length: mut.length)
            mut.addAttribute(.foregroundColor, value: linkColor, range: labelAll)
            mut.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: labelAll)
            mut.addAttribute(.proseInline, value: InlineTag.link, range: labelAll)
            if let parsed = URL(string: url) {
                mut.addAttribute(.link, value: parsed, range: labelAll)
            }
            s.replaceCharacters(in: full, with: mut)
            searchStart = full.location + mut.length
        }
    }

    private func applyEmphasis(_ s: NSMutableAttributedString, marker: String, trait: FontTraits) {
        let escaped = NSRegularExpression.escapedPattern(for: marker)
        // [^markerChar\n]+? — content is non-empty, no newline, no further
        // marker chars (so `**a*b**` doesn't half-match).
        let body = (marker == "**" || marker == "*") ? "[^*\\n]+?" : "[^_\\n]+?"
        let pattern = "\(escaped)(\(body))\(escaped)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        var searchStart = 0
        while searchStart < s.length {
            let searchRange = NSRange(location: searchStart, length: s.length - searchStart)
            guard let m = regex.firstMatch(in: s.string, range: searchRange) else { break }
            let full = m.range
            let inner = m.range(at: 1)
            if hasCodeSpan(in: full, of: s) {
                searchStart = full.location + full.length
                continue
            }
            // Single-marker variants: refuse if marker char abuts a word
            // character on the outer side (so `var_x` and `x_y` pass through
            // verbatim).
            if marker == "*" || marker == "_" {
                if hasAdjacentWordCharacter(at: full, in: s.string) {
                    searchStart = full.location + 1
                    continue
                }
            }
            let innerAttr = s.attributedSubstring(from: inner)
            let mut = NSMutableAttributedString(attributedString: innerAttr)
            let mutAll = NSRange(location: 0, length: mut.length)
            mut.enumerateAttribute(.font, in: mutAll) { value, range, _ in
                let f = (value as? PlatformFont) ?? bodyFont
                let g = f.togglingProseTrait(trait, enable: true)
                mut.addAttribute(.font, value: g, range: range)
            }
            s.replaceCharacters(in: full, with: mut)
            searchStart = full.location + mut.length
        }
    }

    private func hasCodeSpan(in range: NSRange, of s: NSAttributedString) -> Bool {
        var found = false
        let safe = NSRange(
            location: max(0, range.location),
            length: min(s.length - max(0, range.location), max(0, range.length))
        )
        guard safe.length > 0 else { return false }
        s.enumerateAttribute(.proseInline, in: safe) { value, _, stop in
            if let tag = value as? InlineTag, tag == .codeSpan {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Refuse single-marker emphasis when either outer side abuts a word
    /// character — prevents `var_name` from being mistaken for italic and
    /// `m*n*o` (`m` as multiplier) from collapsing.
    private func hasAdjacentWordCharacter(at range: NSRange, in source: String) -> Bool {
        let ns = source as NSString
        if range.location > 0 {
            let prev = ns.character(at: range.location - 1)
            if isWordCharacter(prev) { return true }
        }
        let endIdx = range.location + range.length
        if endIdx < ns.length {
            let next = ns.character(at: endIdx)
            if isWordCharacter(next) { return true }
        }
        return false
    }

    private func isWordCharacter(_ ch: unichar) -> Bool {
        if ch >= 0x30 && ch <= 0x39 { return true } // 0-9
        if ch >= 0x41 && ch <= 0x5A { return true } // A-Z
        if ch >= 0x61 && ch <= 0x7A { return true } // a-z
        if ch == 0x5F { return true } // _
        return false
    }
}

/// Stateless metrics helpers for pipe-table layout. Used both by the
/// `PipeTableLayoutFragment` at draw time and by the row-height stamper that
/// stretches paragraph styles to fit wrapped cell content.
public enum PipeTableMetrics {
    /// Maximum wrapped text height across `cells`, given each cell's column
    /// width and the cell's padding. Returns 0 for empty input.
    public static func requiredCellHeight(
        cells: [NSAttributedString],
        columnWidths: [CGFloat],
        cellPaddingHorizontal: CGFloat,
        cellPaddingVertical: CGFloat
    ) -> CGFloat {
        var maxH: CGFloat = 0
        for (i, cell) in cells.enumerated() {
            guard i < columnWidths.count else { break }
            let availW = max(1, columnWidths[i] - 2 * cellPaddingHorizontal)
            let h = cell.boundingRect(
                with: CGSize(width: availW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            ).height
            maxH = max(maxH, h)
        }
        return ceil(maxH + 2 * cellPaddingVertical)
    }

    /// Natural single-line widths for each column — the widest cell (header
    /// or any body cell) at full-width measurement. Drives proportional
    /// column sizing so a "Command" column can be narrower than a
    /// "Description" column without manual width hints.
    public static func naturalColumnWidths(
        headerCells: [NSAttributedString],
        bodyRows: [[NSAttributedString]],
        columnCount: Int
    ) -> [CGFloat] {
        var widths = [CGFloat](repeating: 0, count: max(0, columnCount))
        for i in 0..<widths.count {
            if i < headerCells.count {
                widths[i] = max(widths[i], naturalWidth(headerCells[i]))
            }
            for row in bodyRows {
                if i < row.count {
                    widths[i] = max(widths[i], naturalWidth(row[i]))
                }
            }
        }
        return widths
    }

    /// Natural single-line drawn width of an attributed string.
    public static func naturalWidth(_ s: NSAttributedString) -> CGFloat {
        guard s.length > 0 else { return 0 }
        let huge: CGFloat = CGFloat.greatestFiniteMagnitude
        let bounds = s.boundingRect(
            with: CGSize(width: huge, height: huge),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        return ceil(bounds.width)
    }

    /// Compute final per-column widths fitting `containerWidth`. Strategy:
    /// start from `naturalColumnWidths + 2*paddingH`. If they fit, distribute
    /// the slack proportionally so wide columns expand more than narrow ones.
    /// If they don't fit, scale down while clamping each column at
    /// `minColumnWidth` so very long natural content doesn't crush a narrow
    /// column to zero.
    public static func columnWidths(
        natural: [CGFloat],
        containerWidth: CGFloat,
        cellPaddingHorizontal: CGFloat,
        minColumnWidth: CGFloat = 60
    ) -> [CGFloat] {
        let cols = natural.count
        guard cols > 0 else { return [] }
        let inner = max(CGFloat(cols) * minColumnWidth, containerWidth)
        let pad = 2 * cellPaddingHorizontal
        let withPadding = natural.map { $0 + pad }
        let totalNeeded = withPadding.reduce(0, +)
        if totalNeeded <= inner {
            // Distribute the slack proportionally to natural width so wide
            // columns expand more than narrow ones. Falls back to even split
            // when every column has zero natural width.
            let slack = inner - totalNeeded
            let totalNatural = natural.reduce(0, +)
            if totalNatural <= 0 {
                return Array(repeating: inner / CGFloat(cols), count: cols)
            }
            return zip(natural, withPadding).map { (n, w) in
                w + slack * (n / totalNatural)
            }
        }
        // Doesn't fit naturally — proportional shrink with min clamp. The
        // clamp can push us back over `inner`; that's fine, the table just
        // overflows the container horizontally.
        let scale = inner / totalNeeded
        return withPadding.map { max(minColumnWidth, $0 * scale) }
    }

    /// Cumulative x-positions for a list of column widths, including the
    /// outer left edge (always 0) and right edge (sum). Result has length
    /// `widths.count + 1` so consumers can index `[i, i+1]` to get the i-th
    /// column's bounds.
    public static func columnXs(widths: [CGFloat]) -> [CGFloat] {
        var xs: [CGFloat] = [0]
        xs.reserveCapacity(widths.count + 1)
        var cumulative: CGFloat = 0
        for w in widths {
            cumulative += w
            xs.append(cumulative)
        }
        return xs
    }
}
