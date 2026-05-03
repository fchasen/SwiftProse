import Testing
import Foundation
@testable import MarginaliaSyntax

@Suite struct BlockSpecTests {

    @Test func paragraphIsDefault() {
        let spec = BlockSpec.paragraph
        #expect(spec.kind == .paragraph)
        #expect(spec.blockquoteDepth == 0)
        #expect(spec.listLevel == 0)
    }

    @Test func equatableComparesAllFields() {
        #expect(BlockSpec(kind: .paragraph) == BlockSpec(kind: .paragraph))
        #expect(BlockSpec(kind: .paragraph, blockquoteDepth: 1) != BlockSpec(kind: .paragraph))
        #expect(BlockSpec(kind: .heading(level: 1)) != BlockSpec(kind: .heading(level: 2)))
        #expect(BlockSpec(kind: .orderedListItem(index: 1)) != BlockSpec(kind: .orderedListItem(index: 2)))
        #expect(BlockSpec(kind: .taskListItem(checked: false)) != BlockSpec(kind: .taskListItem(checked: true)))
        #expect(BlockSpec(kind: .fencedCode(language: "swift")) != BlockSpec(kind: .fencedCode(language: nil)))
    }

    @Test func storageRoundTrip() {
        let target = NSMutableAttributedString(string: "hello\n")
        let spec = BlockSpec(kind: .heading(level: 2), blockquoteDepth: 0, listLevel: 0)
        target.setBlockSpec(spec, in: NSRange(location: 0, length: target.length))
        #expect(target.blockSpec(at: 0) == spec)
        #expect(target.blockSpec(at: target.length - 1) == spec)
    }

    @Test func enumerateProducesContiguousRuns() {
        let target = NSMutableAttributedString(string: "abcdef")
        target.setBlockSpec(.paragraph, in: NSRange(location: 0, length: 3))
        target.setBlockSpec(BlockSpec(kind: .heading(level: 1)), in: NSRange(location: 3, length: 3))
        var collected: [(NSRange, BlockSpec)] = []
        target.enumerateBlockSpecs { collected.append(($0, $1)) }
        #expect(collected.count == 2)
        #expect(collected[0].0 == NSRange(location: 0, length: 3))
        #expect(collected[1].0 == NSRange(location: 3, length: 3))
        #expect(collected[1].1.kind == .heading(level: 1))
    }

    @Test func storageRunsAreReferenceBounded() {
        let target = NSMutableAttributedString(string: "ab")
        target.setBlockSpec(BlockSpec(kind: .heading(level: 2)),
                            in: NSRange(location: 0, length: 1))
        target.setBlockSpec(BlockSpec(kind: .heading(level: 2)),
                            in: NSRange(location: 1, length: 1))
        var ranges = 0
        target.enumerateBlockSpecs { _, _ in ranges += 1 }
        #expect(ranges == 2, "distinct boxes stay as distinct runs even when spec values match")
    }

    @Test func sameBoxFusesRuns() {
        let target = NSMutableAttributedString(string: "ab")
        let box = BlockSpecBox(BlockSpec(kind: .heading(level: 2)))
        target.addAttribute(.marginaliaBlockSpec, value: box, range: NSRange(location: 0, length: 2))
        var ranges = 0
        target.enumerateBlockSpecs { _, _ in ranges += 1 }
        #expect(ranges == 1, "a single box applied uniformly produces one run")
    }
}
