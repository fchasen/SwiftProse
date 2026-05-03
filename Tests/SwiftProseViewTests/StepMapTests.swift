import Testing
import Foundation
@testable import SwiftProseView

@Suite struct StepMapTests {

    @Test func emptyMapIsIdentity() {
        let m = StepMap.empty
        #expect(m.map(0) == 0)
        #expect(m.map(10) == 10)
        #expect(m.mapRange(NSRange(location: 5, length: 3)) == NSRange(location: 5, length: 3))
    }

    @Test func insertionShiftsPositionsAfterInsertPoint() {
        let m = StepMap(oldRange: NSRange(location: 5, length: 0), newLength: 3)
        #expect(m.map(0) == 0)
        #expect(m.map(5) == 5)
        #expect(m.map(6) == 9)
        #expect(m.map(10) == 13)
    }

    @Test func deletionShiftsPositionsBackward() {
        let m = StepMap(oldRange: NSRange(location: 5, length: 3), newLength: 0)
        #expect(m.map(0) == 0)
        #expect(m.map(5) == 5)
        #expect(m.map(8) == 5)
        #expect(m.map(10) == 7)
    }

    @Test func replacementShiftsCorrectly() {
        let m = StepMap(oldRange: NSRange(location: 5, length: 4), newLength: 7)
        #expect(m.map(0) == 0)
        #expect(m.map(5) == 5)
        #expect(m.map(9) == 12)
        #expect(m.map(10) == 13)
    }

    @Test func biasInsideChange() {
        let m = StepMap(oldRange: NSRange(location: 5, length: 4), newLength: 2)
        #expect(m.map(7, bias: .before) == 5)
        #expect(m.map(7, bias: .after) == 7)
    }

    @Test func rangeMappingExpandsAndShrinks() {
        let inserted = StepMap(oldRange: NSRange(location: 5, length: 0), newLength: 3)
        #expect(inserted.mapRange(NSRange(location: 4, length: 4)) == NSRange(location: 4, length: 7))

        let deleted = StepMap(oldRange: NSRange(location: 5, length: 3), newLength: 0)
        #expect(deleted.mapRange(NSRange(location: 4, length: 5)) == NSRange(location: 4, length: 2))
    }

    @Test func invertedReversesChange() {
        let m = StepMap(oldRange: NSRange(location: 5, length: 0), newLength: 3)
        let inv = m.inverted
        let composite = Mapping(maps: [m, inv])
        #expect(composite.map(10) == 10)
    }

    @Test func mappingChainsCompose() {
        let a = StepMap(oldRange: NSRange(location: 1, length: 0), newLength: 2)
        let b = StepMap(oldRange: NSRange(location: 5, length: 0), newLength: 3)
        let chain = Mapping(maps: [a, b])
        #expect(chain.map(0) == 0)
        #expect(chain.map(3) == 5)
        #expect(chain.map(4) == 9)
    }

    @Test func multiParagraphForwardOrderScenario() {
        var mapping = Mapping.empty
        mapping.append(StepMap(oldRange: NSRange(location: 0, length: 5), newLength: 7))
        mapping.append(StepMap(oldRange: NSRange(location: 10, length: 5), newLength: 7))
        let originalLine3Start = NSRange(location: 20, length: 5)
        let mapped = mapping.mapRange(originalLine3Start)
        #expect(mapped.location == 24)
        #expect(mapped.length == 5)
    }
}
