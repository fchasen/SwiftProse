import Testing
import Foundation
import SwiftProseRendering
import SwiftProseSyntax

@Suite("Cell formatter")
struct CellAttributedFormatterTests {
    private func makeFormatter(bold: Bool = false) -> CellAttributedFormatter {
        let body = PlatformFont.systemFont(ofSize: 14)
        let mono = PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        #if canImport(AppKit) && os(macOS)
        let fg = PlatformColor.labelColor
        let link = PlatformColor.linkColor
        let bg = PlatformColor.tertiaryLabelColor
        #else
        let fg = PlatformColor.label
        let link = PlatformColor.link
        let bg = PlatformColor.tertiaryLabel
        #endif
        return CellAttributedFormatter(
            bodyFont: body,
            monospaceFont: mono,
            foregroundColor: fg,
            linkColor: link,
            codeBackground: bg,
            bold: bold
        )
    }

    @Test
    func plainTextProducesPlainAttributedString() {
        let f = makeFormatter()
        let result = f.format("git status")
        #expect(result.string == "git status")
    }

    @Test
    func boldStarsAreStrippedAndFontIsBolded() {
        let f = makeFormatter()
        let result = f.format("**git** status")
        #expect(result.string == "git status")
        let firstFont = result.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(firstFont?.proseTraits.contains(.bold) == true)
        // The non-bold tail should not carry the bold trait.
        let tailFont = result.attribute(.font, at: result.length - 1, effectiveRange: nil) as? PlatformFont
        #expect(tailFont?.proseTraits.contains(.bold) == false)
    }

    @Test
    func italicStarsAreStrippedAndFontIsItalicized() {
        let f = makeFormatter()
        let result = f.format("git *status*")
        #expect(result.string == "git status")
        let italicFont = result.attribute(.font, at: result.length - 1, effectiveRange: nil) as? PlatformFont
        #expect(italicFont?.proseTraits.contains(.italic) == true)
    }

    @Test
    func tripleStarsResolveToBoldItalic() {
        let f = makeFormatter()
        let result = f.format("***bold-italic***")
        #expect(result.string == "bold-italic")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.proseTraits.contains(.bold) == true)
        #expect(font?.proseTraits.contains(.italic) == true)
    }

    @Test
    func underscoreItalicMatchesAroundWordBoundaries() {
        let f = makeFormatter()
        let result = f.format("_emphasis_")
        #expect(result.string == "emphasis")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.proseTraits.contains(.italic) == true)
    }

    @Test
    func underscoreInsideWordIsNotEmphasis() {
        let f = makeFormatter()
        let result = f.format("snake_case_name")
        #expect(result.string == "snake_case_name")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.proseTraits.contains(.italic) == false)
    }

    @Test
    func codeSpanSwitchesToMonospaceFont() {
        let f = makeFormatter()
        let result = f.format("run `npm test` first")
        #expect(result.string == "run npm test first")
        let codeIdx = (result.string as NSString).range(of: "npm").location
        let font = result.attribute(.font, at: codeIdx, effectiveRange: nil) as? PlatformFont
        #expect(font?.isMonospace == true)
        let tag = result.attribute(.proseInline, at: codeIdx, effectiveRange: nil) as? InlineTag
        #expect(tag == .codeSpan)
    }

    @Test
    func emphasisInsideCodeSpanIsLeftLiteral() {
        let f = makeFormatter()
        let result = f.format("`*not italic*`")
        // Inside the code span, the asterisks remain literal.
        #expect(result.string == "*not italic*")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.isMonospace == true)
    }

    @Test
    func linkLabelGetsLinkAttributesAndStrippedSyntax() {
        let f = makeFormatter()
        let result = f.format("[click](https://example.com)")
        #expect(result.string == "click")
        let url = result.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(url == URL(string: "https://example.com"))
        let tag = result.attribute(.proseInline, at: 0, effectiveRange: nil) as? InlineTag
        #expect(tag == .link)
    }

    @Test
    func boldFlagAppliesBaseTraitWithoutMarkers() {
        let f = makeFormatter(bold: true)
        let result = f.format("Command")
        #expect(result.string == "Command")
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.proseTraits.contains(.bold) == true)
    }
}

@Suite("Pipe table metrics")
struct PipeTableMetricsTests {
    private func attr(_ s: String) -> NSAttributedString {
        NSAttributedString(
            string: s,
            attributes: [.font: PlatformFont.systemFont(ofSize: 14)]
        )
    }

    @Test
    func columnWidthsSumToContainerWidthWhenNaturalFits() {
        let widths = PipeTableMetrics.columnWidths(
            natural: [50, 200],
            containerWidth: 600,
            cellPaddingHorizontal: 12
        )
        let total = widths.reduce(0, +)
        #expect(abs(total - 600) < 1)
        // The wider natural column gets a larger final width.
        #expect(widths[1] > widths[0])
    }

    @Test
    func columnWidthsApplyMinClampWhenContainerTooNarrow() {
        let widths = PipeTableMetrics.columnWidths(
            natural: [400, 400, 400],
            containerWidth: 100,
            cellPaddingHorizontal: 12,
            minColumnWidth: 60
        )
        for w in widths {
            #expect(w >= 60)
        }
    }

    @Test
    func cumulativeXsHasNPlusOneEntries() {
        let xs = PipeTableMetrics.columnXs(widths: [100, 200, 50])
        #expect(xs == [0, 100, 300, 350])
    }

    @Test
    func requiredHeightAccountsForVerticalPadding() {
        let cell = attr("a")
        let h = PipeTableMetrics.requiredCellHeight(
            cells: [cell],
            columnWidths: [200],
            cellPaddingHorizontal: 12,
            cellPaddingVertical: 10
        )
        // One line of body text plus 20pt total vertical padding ≥ 30.
        #expect(h >= 30)
    }
}
