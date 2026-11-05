import SwiftProseSyntax
import SwiftProseRendering
import Foundation
import CoreGraphics
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum CodeBandPath {
    static let cornerRadius: CGFloat = 6
    static let verticalPadding: CGFloat = 4

    static func groupRanges(in storage: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        var current: (group: GroupToken, start: Int, end: Int)?
        storage.enumerateAttribute(
            .markdownBlock,
            in: NSRange(location: 0, length: storage.length)
        ) { value, subRange, _ in
            let group = (value as? MarkdownBlock)?.codeGroup
            if let open = current, open.group == group, open.end == subRange.location {
                current?.end = NSMaxRange(subRange)
                return
            }
            if let open = current {
                ranges.append(NSRange(location: open.start, length: open.end - open.start))
                current = nil
            }
            if let group {
                current = (group, subRange.location, NSMaxRange(subRange))
            }
        }
        if let open = current {
            ranges.append(NSRange(location: open.start, length: open.end - open.start))
        }
        return ranges
    }

    static func leadingOffset(forGroupStartingAt location: Int, in storage: NSAttributedString) -> CGFloat {
        guard let block = storage.markdownBlock(at: location) else { return 0 }
        return max(0, Restyler.indent(for: block) - (block.isCode ? Restyler.codeInset : 0))
    }

    static func make(
        storage: NSAttributedString,
        layoutManager: NSTextLayoutManager,
        inset: CGPoint,
        containerWidth: CGFloat
    ) -> CGPath? {
        let path = CGMutablePath()
        for range in groupRanges(in: storage) {
            let leading = leadingOffset(forGroupStartingAt: range.location, in: storage)
            addBand(
                to: path,
                range: range,
                layoutManager: layoutManager,
                inset: CGPoint(x: inset.x + leading, y: inset.y),
                containerWidth: max(0, containerWidth - leading)
            )
        }
        return path.isEmpty ? nil : path
    }

    private static func addBand(
        to path: CGMutablePath,
        range: NSRange,
        layoutManager: NSTextLayoutManager,
        inset: CGPoint,
        containerWidth: CGFloat
    ) {
        guard let cs = layoutManager.textContentManager as? NSTextContentStorage,
              let docStart = cs.location(cs.documentRange.location, offsetBy: range.location) else { return }
        let docEnd = cs.location(cs.documentRange.location, offsetBy: NSMaxRange(range))
        var minTextY: CGFloat = .greatestFiniteMagnitude
        var maxTextY: CGFloat = -.greatestFiniteMagnitude
        layoutManager.enumerateTextLayoutFragments(from: docStart, options: [.ensuresLayout]) { fragment in
            if let docEnd,
               let elementStart = fragment.textElement?.elementRange?.location,
               cs.offset(from: elementStart, to: docEnd) <= 0 {
                return false
            }
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments where line.typographicBounds.height > 0 {
                minTextY = min(minTextY, frame.minY + line.typographicBounds.minY)
                maxTextY = max(maxTextY, frame.minY + line.typographicBounds.maxY)
            }
            return true
        }
        guard maxTextY > minTextY else { return }
        let bandY = max(0, inset.y + minTextY - verticalPadding)
        let bandBottom = inset.y + maxTextY + verticalPadding
        let bandRect = CGRect(x: inset.x, y: bandY, width: containerWidth, height: bandBottom - bandY)
        path.addRoundedRect(in: bandRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
    }
}
