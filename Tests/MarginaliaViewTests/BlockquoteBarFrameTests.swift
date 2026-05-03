import Testing
import Foundation
import MarginaliaSyntax
import MarginaliaRendering
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite struct BlockquoteBarFrameTests {

    @Test func blockquoteFragmentIsOffsetByParagraphIndent() throws {
        let controller = try EditorController(initialMarkdown: "> hello\n")
        let lm = controller.layoutManager
        lm.ensureLayout(for: lm.documentRange)

        var first: NSTextLayoutFragment?
        lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { frag in
            first = frag
            return false
        }
        let frame = try #require(first?.layoutFragmentFrame)
        // TextKit 2 positions the fragment at the paragraph's leading edge,
        // so origin.x is non-zero whenever firstLineHeadIndent or
        // lineFragmentPadding is set. The blockquote bar painter relies on
        // this to compensate, drawing at barInset - origin.x.
        #expect(frame.origin.x > 0)
    }
}
