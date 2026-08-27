import Testing
import Foundation
@testable import SwiftProseSyntax

@Suite struct MarkSetBoxTests {

    @Test func boxesHoldingEqualSetsAreEqual() {
        let strong = MarkSet([ProseMark(type: "strong")])
        #expect(MarkSetBox(strong).isEqual(MarkSetBox(strong)))
        #expect(MarkSetBox(strong).hash == MarkSetBox(strong).hash)
        #expect(!MarkSetBox(strong).isEqual(MarkSetBox(MarkSet())))
        #expect(!MarkSetBox(strong).isEqual(nil))
    }

    /// Two boxes with the same set on adjacent characters are one run —
    /// what every consumer of `enumerateAttribute(.proseMarks)` relies on.
    @Test func adjacentRunsWithEqualSetsCoalesce() {
        let storage = NSMutableAttributedString(string: "abc")
        for i in 0..<3 {
            storage.addAttribute(.proseMarks, value: MarkSetBox(MarkSet()), range: NSRange(location: i, length: 1))
        }
        var runs: [NSRange] = []
        storage.enumerateAttribute(.proseMarks, in: NSRange(location: 0, length: 3)) { _, range, _ in
            runs.append(range)
        }
        #expect(runs == [NSRange(location: 0, length: 3)])
    }
}
