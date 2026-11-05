import SwiftProseSyntax
import SwiftProseRendering
import SwiftProseView
import CoreGraphics

public enum CompletionPopupPlacement {
    public static func origin(
        anchorRect: CGRect,
        menuSize: CGSize,
        containerBounds: CGRect,
        gap: CGFloat = 4,
        edgeInset: CGFloat = 24
    ) -> CGPoint {
        let horizontalInset = min(edgeInset, max(0, (containerBounds.width - menuSize.width) / 2))
        let verticalInset = min(edgeInset, max(0, containerBounds.height / 4))
        let effectiveBounds = containerBounds.insetBy(dx: horizontalInset, dy: verticalInset)
        let maxX = max(effectiveBounds.minX, effectiveBounds.maxX - menuSize.width)
        let x = min(max(anchorRect.minX, effectiveBounds.minX), maxX)
        let belowY = anchorRect.maxY + gap
        let aboveY = anchorRect.minY - menuSize.height - gap
        let availableBelow = effectiveBounds.maxY - belowY
        let availableAbove = anchorRect.minY - effectiveBounds.minY - gap
        let y: CGFloat
        if availableBelow >= menuSize.height {
            y = belowY
        } else if availableAbove >= menuSize.height {
            y = aboveY
        } else if availableBelow >= availableAbove {
            y = belowY
        } else {
            y = aboveY
        }
        return CGPoint(x: x, y: y)
    }
}
