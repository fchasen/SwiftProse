import SwiftProseSyntax
import SwiftProseRendering
import Foundation
import CoreGraphics
import CoreText
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum ListNumbering {
    static func ordinals(in storage: NSAttributedString) -> [Int: Int] {
        struct Run {
            var containers: ArraySlice<MarkdownBlock.Container>
            var marker: UInt8?
            var start: Int?
            var count = 0
        }
        var result: [Int: Int] = [:]
        var runs: [Run?] = []
        let ns = storage.string as NSString
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let lists = MarkdownTextList.effectiveTextLists(in: storage, at: paragraph.location)
            let block = storage.markdownBlock(at: paragraph.location)
            if runs.count > lists.count { runs.removeSubrange(lists.count...) }
            for depth in lists.indices {
                guard lists[depth].hasOrderedMarker else {
                    if depth < runs.count { runs[depth] = nil } else { runs.append(nil) }
                    continue
                }
                let containers = containerPrefix(of: block, throughListDepth: depth + 1)
                let marker = MarkdownTextList.sourceMarker(of: lists[depth])
                if depth < runs.count {
                    if let run = runs[depth], run.containers == containers, !MarkdownTextList.areDistinct(run.marker, marker) {
                        if run.marker == nil { runs[depth]?.marker = marker }
                    } else {
                        runs[depth] = Run(containers: containers, marker: marker)
                    }
                } else {
                    runs.append(Run(containers: containers, marker: marker))
                }
            }
            guard let list = lists.last, list.hasOrderedMarker, block?.isContinuation != true,
                  var run = runs[lists.count - 1] else { continue }
            result[paragraph.location] = (run.start ?? list.startingItemNumber) + run.count
            if run.start == nil { run.start = list.startingItemNumber }
            run.count += 1
            runs[lists.count - 1] = run
        }
        return result
    }

    static func containerPrefix(of block: MarkdownBlock?, throughListDepth depth: Int) -> ArraySlice<MarkdownBlock.Container> {
        guard let containers = block?.containers else { return [] }
        var remaining = depth
        for (index, container) in containers.enumerated() where container == .listItem {
            remaining -= 1
            if remaining == 0 { return containers[...index] }
        }
        return containers[...]
    }

    static func markerKind(at paragraphStart: Int, in storage: NSAttributedString, ordinal: (Int) -> Int?) -> ListMarker.Kind? {
        guard paragraphStart >= 0, paragraphStart < storage.length,
              let block = storage.markdownBlock(at: paragraphStart),
              !block.isContinuation else { return nil }
        let lists = MarkdownTextList.effectiveTextLists(in: storage, at: paragraphStart)
        guard let list = lists.last else { return nil }
        if let task = block.task { return .task(task) }
        if list.hasOrderedMarker, let number = ordinal(paragraphStart) {
            return .ordinal(number)
        }
        return .bullet(bulletGlyph(for: list, depth: lists.count))
    }

    static func bulletGlyph(for list: NSTextList, depth: Int) -> String {
        let marker = list.marker(forItemNumber: 1)
        if !marker.isEmpty, marker.count <= 2 { return marker }
        let glyphs = ["•", "◦", "▪"]
        return glyphs[(max(1, depth) - 1) % glyphs.count]
    }

    static func listContentIndent(for block: MarkdownBlock) -> CGFloat {
        guard let last = block.containers.lastIndex(where: { if case .listItem = $0 { return true } else { return false } }) else {
            return 0
        }
        return block.containers[...last].reduce(CGFloat(0)) { total, container in
            switch container {
            case .quote: return total + Restyler.quoteIndent
            case .listItem: return total + Restyler.listIndent
            }
        }
    }

    static func leadingOffsets(ofQuotesIn block: MarkdownBlock) -> [CGFloat] {
        var offsets: [CGFloat] = []
        var total: CGFloat = 0
        for container in block.containers {
            switch container {
            case .quote:
                offsets.append(total)
                total += Restyler.quoteIndent
            case .listItem:
                total += Restyler.listIndent
            }
        }
        return offsets
    }
}

final class DecorationCache {
    private(set) var generation = 0
    private var ordinals: [Int: Int]?

    func invalidate() {
        generation &+= 1
        ordinals = nil
    }

    func ordinal(at paragraphStart: Int, in storage: NSAttributedString) -> Int? {
        if ordinals == nil { ordinals = ListNumbering.ordinals(in: storage) }
        return ordinals?[paragraphStart]
    }
}

enum ListMarkerRenderer {
    static let gap: CGFloat = 6
    static let bulletCenterInset: CGFloat = 16
    static let taskBoxScale: CGFloat = 0.95

    static func draw(_ marker: ListMarker, anchorX: CGFloat, baseline: CGFloat, isRightToLeft: Bool, in context: CGContext) {
        switch marker.kind {
        case .bullet, .ordinal:
            guard let text = marker.text else { return }
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): marker.font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): marker.color.cgColor
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x: CGFloat
            if case .bullet = marker.kind {
                x = anchorX + (isRightToLeft ? bulletCenterInset : -bulletCenterInset) - width / 2
            } else {
                x = isRightToLeft ? anchorX + gap : anchorX - gap - width
            }
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        case .task(let state):
            let rect = taskBoxRect(font: marker.font, anchorX: anchorX, baseline: baseline, isRightToLeft: isRightToLeft)
            context.saveGState()
            #if canImport(AppKit) && os(macOS)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            CheckboxAttachment.draw(checked: state.isChecked, in: rect)
            NSGraphicsContext.restoreGraphicsState()
            #else
            UIGraphicsPushContext(context)
            CheckboxAttachment.draw(checked: state.isChecked, in: rect)
            UIGraphicsPopContext()
            #endif
            context.restoreGState()
        }
    }

    static func taskBoxRect(font: PlatformFont, anchorX: CGFloat, baseline: CGFloat, isRightToLeft: Bool) -> CGRect {
        let side = max(10, (font.ascender - font.descender) * taskBoxScale)
        let centerY = baseline - font.capHeight / 2
        let x = isRightToLeft ? anchorX + gap : anchorX - gap - side
        return CGRect(x: x, y: centerY - side / 2, width: side, height: side)
    }
}

enum MarkdownTaskGutter {
    static let width: CGFloat = 28

    static func hitRect(caret: CGRect, isRightToLeft: Bool) -> CGRect {
        CGRect(
            x: isRightToLeft ? caret.maxX : caret.minX - width,
            y: caret.minY,
            width: width,
            height: max(caret.height, 1)
        )
    }
}

extension NSAttributedString {
    func isRightToLeftParagraph(at index: Int) -> Bool {
        guard index >= 0, index < length,
              let style = attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle else { return false }
        return style.baseWritingDirection == .rightToLeft
    }
}
