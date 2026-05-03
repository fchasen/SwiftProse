import Testing
import Foundation
@testable import MarginaliaRendering

@Suite struct OrderedMarkerFormatterTests {

    @Test func decimal() {
        #expect(OrderedMarkerFormatter.format(index: 1, style: .decimal) == "1.")
        #expect(OrderedMarkerFormatter.format(index: 42, style: .decimal) == "42.")
    }

    @Test func lowerAlphaSimple() {
        #expect(OrderedMarkerFormatter.format(index: 1, style: .lowerAlpha) == "a.")
        #expect(OrderedMarkerFormatter.format(index: 2, style: .lowerAlpha) == "b.")
        #expect(OrderedMarkerFormatter.format(index: 26, style: .lowerAlpha) == "z.")
    }

    @Test func lowerAlphaOverflow() {
        #expect(OrderedMarkerFormatter.format(index: 27, style: .lowerAlpha) == "aa.")
        #expect(OrderedMarkerFormatter.format(index: 28, style: .lowerAlpha) == "ab.")
        #expect(OrderedMarkerFormatter.format(index: 52, style: .lowerAlpha) == "az.")
        #expect(OrderedMarkerFormatter.format(index: 53, style: .lowerAlpha) == "ba.")
    }

    @Test func lowerRoman() {
        #expect(OrderedMarkerFormatter.format(index: 1, style: .lowerRoman) == "i.")
        #expect(OrderedMarkerFormatter.format(index: 2, style: .lowerRoman) == "ii.")
        #expect(OrderedMarkerFormatter.format(index: 3, style: .lowerRoman) == "iii.")
        #expect(OrderedMarkerFormatter.format(index: 4, style: .lowerRoman) == "iv.")
        #expect(OrderedMarkerFormatter.format(index: 9, style: .lowerRoman) == "ix.")
        #expect(OrderedMarkerFormatter.format(index: 40, style: .lowerRoman) == "xl.")
        #expect(OrderedMarkerFormatter.format(index: 90, style: .lowerRoman) == "xc.")
    }

    @Test func levelCycle() {
        #expect(OrderedMarkerFormatter.style(forLevel: 0) == .decimal)
        #expect(OrderedMarkerFormatter.style(forLevel: 1) == .lowerAlpha)
        #expect(OrderedMarkerFormatter.style(forLevel: 2) == .lowerRoman)
        #expect(OrderedMarkerFormatter.style(forLevel: 3) == .decimal)
        #expect(OrderedMarkerFormatter.style(forLevel: 4) == .lowerAlpha)
        #expect(OrderedMarkerFormatter.style(forLevel: 5) == .lowerRoman)
    }
}
