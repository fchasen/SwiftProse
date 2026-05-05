import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct InlineCodePillWrapTests {

    /// A paragraph with multiple inline code spans that wraps onto more
    /// than one line. We verify the layout fragment has multiple line
    /// fragments and that each line's typographic bounds advance vertically
    /// — the precondition the pill painter relies on for per-line pills.
    @Test func wrappedParagraphHasStackedLineFragments() throws {
        let md = "`CellView` wraps a single platform text input (`NSTextView` on macOS, `UITextView` on iOS), configured with the same `ProseTheme`."
        let controller = try EditorController(
            initialMarkdown: md,
            containerSize: CGSize(width: 240, height: 1000)
        )
        let lm = controller.layoutManager
        lm.ensureLayout(for: lm.documentRange)
        var allLines: [(NSRange, CGRect)] = []
        lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { frag in
            for line in frag.textLineFragments {
                allLines.append((line.characterRange, line.typographicBounds))
            }
            return true
        }
        try #require(allLines.count >= 2, "Paragraph should wrap to multiple lines at width=240; got \(allLines.count)")
        for i in 1..<allLines.count {
            let prev = allLines[i - 1].1
            let cur = allLines[i].1
            #expect(cur.origin.y >= prev.origin.y + prev.height - 1,
                    "Line \(i) y=\(cur.origin.y) should be below line \(i-1) at y=\(prev.origin.y)+h=\(prev.height)")
        }
    }

    /// Each code span in a wrapped paragraph should be intersected by at
    /// least one line range — i.e. the pill painter walks past it on some
    /// line. Catches "code span on wrapped line gets dropped" regressions.
    @Test func wrappedLineCoversEveryCodeSpan() throws {
        let md = "alpha `beta` gamma `delta` epsilon `zeta` eta theta iota kappa `lambda` mu nu xi"
        let controller = try EditorController(
            initialMarkdown: md,
            containerSize: CGSize(width: 220, height: 1000)
        )
        let lm = controller.layoutManager
        lm.ensureLayout(for: lm.documentRange)
        let storage = controller.textStorage
        var lineRanges: [NSRange] = []
        lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { frag in
            if let cs = frag.textLayoutManager?.textContentManager as? NSTextContentStorage {
                let elementStart = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
                for line in frag.textLineFragments {
                    let r = NSRange(
                        location: elementStart + line.characterRange.location,
                        length: line.characterRange.length
                    )
                    lineRanges.append(r)
                }
            }
            return true
        }
        try #require(lineRanges.count >= 2)

        var spanCount = 0
        storage.enumerateAttribute(
            .proseInline,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let tag = value as? InlineTag, tag == .codeSpan else { return }
            spanCount += 1
            let intersected = lineRanges.contains { lr in
                NSIntersectionRange(lr, range).length > 0
            }
            #expect(intersected, "Code span at \(range) is not covered by any line fragment")
        }
        #expect(spanCount >= 4)
    }

    /// Inline code in a heading inherits the heading's bold weight + size,
    /// just delivered through the monospaced system font.
    @Test func headingCodeSpanFontIsHeadingSizedMono() throws {
        let theme = ProseTheme.default
        let controller = try EditorController(initialMarkdown: "# Title `code` end\n", theme: theme)
        let storage = controller.textStorage
        let codeRange = (storage.string as NSString).range(of: "code")
        try #require(codeRange.location != NSNotFound)
        let font = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? PlatformFont
        let mono = try #require(font)
        #expect(mono.isMonospace, "Heading code span should be monospaced; got \(mono.fontName)")
        let headingScale = theme.headingScale[1] ?? 1.0
        let expectedSize = theme.bodyFont.pointSize * headingScale
        #expect(abs(mono.pointSize - expectedSize) < 0.01,
                "Mono should match heading point size \(expectedSize); got \(mono.pointSize)")
        #expect(mono.proseTraits.contains(.bold), "Heading code span should be bold; got \(mono.proseTraits)")
    }

    /// Body-paragraph inline code stays at body size (mono regular).
    @Test func paragraphCodeSpanFontIsBodySizedMono() throws {
        let theme = ProseTheme.default
        let controller = try EditorController(initialMarkdown: "hello `world` foo\n", theme: theme)
        let storage = controller.textStorage
        let codeRange = (storage.string as NSString).range(of: "world")
        try #require(codeRange.location != NSNotFound)
        let font = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? PlatformFont
        let mono = try #require(font)
        #expect(mono.isMonospace)
        #expect(abs(mono.pointSize - theme.bodyFont.pointSize) < 0.01)
        #expect(!mono.proseTraits.contains(.bold))
    }

    /// Heading paragraphs should bypass `InlineCodePainter`'s pill paint
    /// even when the painter fragment class is selected for them — the
    /// painter early-returns based on `proseNodePath` containing a heading.
    @Test func headingPathIsRecognizedByPainterCheck() throws {
        let controller = try EditorController(initialMarkdown: "# Hello `code` world\n")
        let storage = controller.textStorage
        // Probe at the code-span location.
        let codeRange = (storage.string as NSString).range(of: "code")
        try #require(codeRange.location != NSNotFound)
        let path = storage.nodePath(at: codeRange.location)
        let containsHeading = path?.nodes.contains(where: { $0.type == "heading" }) ?? false
        #expect(containsHeading)
    }

    /// Sanity-check the painter math for a wrapped paragraph: each
    /// code-span run on each line should produce a pill rectangle whose y
    /// range matches the line it sits on, and whose x range is positive
    /// (start before end). Catches "pill on line 2 lands on line 1"
    /// regressions and bad locationForCharacter handling at the wrap point.
    @Test func wrappedPillRectsLandOnTheirOwnLine() throws {
        let md = "alpha `beta gamma delta` epsilon `zeta eta theta` iota kappa lambda"
        let controller = try EditorController(
            initialMarkdown: md,
            containerSize: CGSize(width: 200, height: 1000)
        )
        let lm = controller.layoutManager
        lm.ensureLayout(for: lm.documentRange)
        let storage = controller.textStorage

        struct PillRect {
            let line: Int
            let lineBounds: CGRect
            let pill: CGRect
            let runRange: NSRange
        }

        var pills: [PillRect] = []
        lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { frag in
            guard let cs = frag.textLayoutManager?.textContentManager as? NSTextContentStorage else { return true }
            let elementStart = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
            for (lineIdx, line) in frag.textLineFragments.enumerated() {
                let lineLocal = line.characterRange
                let storageStart = elementStart + lineLocal.location
                let storageEnd = min(storage.length, storageStart + lineLocal.length)
                var cursor = storageStart
                while cursor < storageEnd {
                    var runRange = NSRange(location: cursor, length: 0)
                    let value = storage.attribute(
                        .proseInline,
                        at: cursor,
                        longestEffectiveRange: &runRange,
                        in: NSRange(location: cursor, length: storageEnd - cursor)
                    )
                    let runEnd = runRange.location + runRange.length
                    if let tag = value as? InlineTag, tag == .codeSpan, runRange.length > 0 {
                        let lineRunStart = max(runRange.location, storageStart) - elementStart
                        let lineRunEnd = min(runEnd, storageEnd) - elementStart
                        let runInLine = NSRange(location: lineRunStart, length: lineRunEnd - lineRunStart)
                        let localStart = runInLine.location - line.characterRange.location
                        let localEnd = localStart + runInLine.length
                        if localStart >= 0,
                           localEnd <= line.attributedString.length,
                           localStart < localEnd {
                            let p0 = line.locationForCharacter(at: localStart)
                            let p1 = line.locationForCharacter(at: localEnd)
                            let bounds = line.typographicBounds
                            let xMin = min(p0.x, p1.x) - 4 // horizontal padding
                            let xMax = max(p0.x, p1.x) + 4
                            let pill = CGRect(
                                x: bounds.origin.x + xMin,
                                y: bounds.origin.y,
                                width: max(0, xMax - xMin),
                                height: bounds.height
                            )
                            pills.append(PillRect(line: lineIdx, lineBounds: bounds, pill: pill, runRange: runRange))
                        }
                    }
                    cursor = max(runEnd, cursor + 1)
                }
            }
            return true
        }

        try #require(pills.count >= 2, "Expected at least two pills (multiple code spans across wrap); got \(pills.count)")

        for p in pills {
            #expect(p.pill.width > 0, "Pill on line \(p.line) (range \(p.runRange)) has zero width")
            #expect(p.pill.height > 0, "Pill on line \(p.line) has zero height")
            // Pill y must land within the corresponding line's vertical range.
            #expect(p.pill.minY >= p.lineBounds.minY - 0.5,
                    "Pill on line \(p.line) starts above its line: pill.y=\(p.pill.minY), line.y=\(p.lineBounds.minY)")
            #expect(p.pill.maxY <= p.lineBounds.maxY + 0.5,
                    "Pill on line \(p.line) extends below its line: pill.maxY=\(p.pill.maxY), line.maxY=\(p.lineBounds.maxY)")
        }

        // Verify pills on different lines don't share a vertical range.
        let pillsByLine = Dictionary(grouping: pills, by: { $0.line })
        if pillsByLine.keys.count > 1 {
            let sortedLines = pillsByLine.keys.sorted()
            for i in 1..<sortedLines.count {
                let prev = pillsByLine[sortedLines[i - 1]]!.first!
                let cur = pillsByLine[sortedLines[i]]!.first!
                #expect(cur.pill.minY >= prev.pill.maxY - 1,
                        "Line \(cur.line) pill at y=\(cur.pill.minY) overlaps with line \(prev.line) pill ending at y=\(prev.pill.maxY)")
            }
        }
    }
}
