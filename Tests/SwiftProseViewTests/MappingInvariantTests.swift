import Testing
import Foundation
@testable import SwiftProseView

@Suite("Mapping invariants")
struct MappingInvariantTests {

    @Test
    func invertOfSingleInsertCancelsPosition() {
        let map = StepMap(oldRange: NSRange(location: 5, length: 0), newLength: 3)
        let mapping = Mapping(maps: [map])
        let inverse = mapping.invert()
        // Mapping a position 10 forward then through the inverse should
        // return to 10 (with default `.after` bias).
        let forward = mapping.map(10)
        let backward = inverse.map(forward)
        #expect(backward == 10)
    }

    @Test
    func invertOfDeleteCancelsForPositionsOutsideTheCut() {
        let map = StepMap(oldRange: NSRange(location: 5, length: 4), newLength: 0)
        let mapping = Mapping(maps: [map])
        let inverse = mapping.invert()
        // Position 12 is past the deletion — should land at 12 - 4 = 8,
        // and the inverse should bring it back to 12.
        let forward = mapping.map(12)
        #expect(forward == 8)
        let back = inverse.map(forward)
        #expect(back == 12)
    }

    @Test
    func mapResultMarksDeletedAcross() {
        let map = StepMap(oldRange: NSRange(location: 5, length: 4), newLength: 0)
        // Position strictly inside the deletion.
        let result = map.mapResult(7, bias: .after)
        #expect(result.deleted)
        #expect(result.deletedAcross)
    }

    @Test
    func mirrorPairsCancel() {
        var mapping = Mapping()
        let forward = StepMap(oldRange: NSRange(location: 3, length: 0), newLength: 2)
        mapping.appendMap(forward, mirrors: nil)
        let backward = forward.inverted
        // Append the inverse and tell the mapping that it mirrors entry 0.
        mapping.appendMap(backward, mirrors: 0)
        // Mirror tracking — entry 0 should know its partner is at index 1.
        #expect(mapping.getMirror(0) == 1)
        #expect(mapping.getMirror(1) == 0)
        // Forward then backward through the chain produces a no-op for any
        // position the forward map didn't displace.
        let pos = 10
        let mapped = mapping.map(pos)
        #expect(mapped == pos)
    }

    @Test
    func biasBeforeAndAfterOnInsertSplit() {
        let map = StepMap(oldRange: NSRange(location: 5, length: 0), newLength: 3)
        // Inserting at 5 with no length change at the boundary —
        // bias .before and .after both push positions strictly past 5
        // by the delta, since pos > 5 is the trigger.
        #expect(map.map(5, bias: .before) == 5)
        #expect(map.map(5, bias: .after) == 5)
        #expect(map.map(6, bias: .before) == 9)
        #expect(map.map(6, bias: .after) == 9)
    }
}
