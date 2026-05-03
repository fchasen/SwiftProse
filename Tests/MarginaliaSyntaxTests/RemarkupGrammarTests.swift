import Testing
import Foundation
@testable import MarginaliaSyntax

@Suite(.serialized) struct RemarkupGrammarTests {

    @Test func remarkupItalic() {
        let spans = RemarkupGrammar.highlights(in: "this is //italic// text")
        let italic = spans.first { $0.tag == .textEmphasis }
        #expect(italic != nil)
        #expect(italic?.range.location == 8)
        #expect(italic?.range.length == 10)  // "//italic//"
    }

    @Test func revisionAutolink() {
        let spans = RemarkupGrammar.highlights(in: "see D12345 for details")
        let link = spans.first { $0.tag == .textURI }
        #expect(link != nil)
        #expect(link?.range.location == 4)
        #expect(link?.range.length == 6)
    }

    @Test func taskAutolink() {
        let spans = RemarkupGrammar.highlights(in: "fixes T999")
        let link = spans.first { $0.tag == .textURI }
        #expect(link != nil)
        #expect(link?.range.location == 6)
        #expect(link?.range.length == 4)
    }

    @Test func fileEmbed() {
        let spans = RemarkupGrammar.highlights(in: "image: {F1234}")
        let embed = spans.first { $0.tag == .textURI }
        #expect(embed != nil)
    }

    @Test func pasteEmbed() {
        let spans = RemarkupGrammar.highlights(in: "paste: {P567}")
        let embed = spans.first { $0.tag == .textURI }
        #expect(embed != nil)
    }

    @Test func userMention() {
        let spans = RemarkupGrammar.highlights(in: "cc @alice and @bob.smith")
        let mentions = spans.filter { $0.tag == .textReference }
        #expect(mentions.count == 2)
    }

    @Test func noteCallout() {
        let spans = RemarkupGrammar.highlights(in: "NOTE: pay attention")
        let callout = spans.first { $0.tag == .textTitle }
        #expect(callout != nil)
        #expect(callout?.range.length == 5)  // "NOTE:"
    }

    @Test func warningCalloutMidLineNotMatched() {
        // Callouts must be at start of line
        let spans = RemarkupGrammar.highlights(in: "this WARNING: should not match")
        let title = spans.first { $0.tag == .textTitle }
        #expect(title == nil)
    }

    @Test func remarkupHeading() {
        let spans = RemarkupGrammar.highlights(in: "== title ==")
        let heading = spans.first { $0.tag == .textTitle }
        #expect(heading != nil)
    }

    @Test func italicDoesNotEatAcrossNewline() {
        // // marker at start of line, // never closes — shouldn't span a newline
        let spans = RemarkupGrammar.highlights(in: "//start\nmiddle//")
        let italic = spans.first { $0.tag == .textEmphasis }
        #expect(italic == nil)
    }

    @Test func revisionAutolinkNotMatchedInWord() {
        // D12 inside identifier shouldn't match
        let spans = RemarkupGrammar.highlights(in: "fooD12bar")
        let link = spans.first { $0.tag == .textURI }
        #expect(link == nil)
    }

    @Test func spansAreSorted() {
        let spans = RemarkupGrammar.highlights(in: "@user fixes D1 and T2")
        let locations = spans.map { $0.range.location }
        #expect(locations == locations.sorted())
    }
}
