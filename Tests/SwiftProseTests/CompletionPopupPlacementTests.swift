import Testing
import Foundation
import CoreGraphics
import SwiftProse

@Suite struct CompletionPopupPlacementTests {

    @Test func placesBelowWhenThereIsRoom() {
        let anchor = CGRect(x: 40, y: 40, width: 2, height: 20)
        let origin = CompletionPopupPlacement.origin(
            anchorRect: anchor,
            menuSize: CGSize(width: 180, height: 120),
            containerBounds: CGRect(x: 0, y: 0, width: 320, height: 400)
        )

        #expect(origin.y >= anchor.maxY)
    }

    @Test func placesAboveWhenViewportBottomIsClose() {
        let anchor = CGRect(x: 40, y: 40, width: 2, height: 20)
        let menuSize = CGSize(width: 180, height: 120)
        let origin = CompletionPopupPlacement.origin(
            anchorRect: anchor,
            menuSize: menuSize,
            containerBounds: CGRect(x: 0, y: -260, width: 320, height: 340)
        )

        #expect(origin.y + menuSize.height <= anchor.minY)
    }

    @Test func clampsHorizontallyWithinContainer() {
        // Caret far to the right; popup wider than remaining room — origin
        // should be pulled back so the popup fits inside the bounds.
        let anchor = CGRect(x: 290, y: 40, width: 2, height: 20)
        let menuSize = CGSize(width: 180, height: 80)
        let containerBounds = CGRect(x: 0, y: 0, width: 320, height: 400)
        let origin = CompletionPopupPlacement.origin(
            anchorRect: anchor,
            menuSize: menuSize,
            containerBounds: containerBounds
        )

        #expect(origin.x + menuSize.width <= containerBounds.maxX)
    }
}
