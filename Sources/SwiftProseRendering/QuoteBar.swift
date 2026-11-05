import SwiftProseSyntax
import CoreGraphics

public struct QuoteBar: Equatable {
    public var offset: CGFloat
    public var isFirstInRun: Bool
    public var isLastInRun: Bool

    package init(offset: CGFloat, isFirstInRun: Bool, isLastInRun: Bool) {
        self.offset = offset
        self.isFirstInRun = isFirstInRun
        self.isLastInRun = isLastInRun
    }
}
