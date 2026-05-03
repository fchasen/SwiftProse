import Testing
import Foundation
@testable import SwiftProseSyntax

@Suite struct ProseMirrorJSONTests {

    @Test func textNodeRoundTrips() throws {
        let node = PMNode(type: "text", text: "hello")
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(PMNode.self, from: data)
        #expect(decoded.type == "text")
        #expect(decoded.text == "hello")
        #expect(decoded.attrs == nil)
        #expect(decoded.content == nil)
    }

    @Test func paragraphWithMarkRoundTrips() throws {
        let inner = PMNode(type: "text", text: "world", marks: [PMMark(type: "strong")])
        let para = PMNode(type: "paragraph", content: [inner])
        let data = try JSONEncoder().encode(para)
        let decoded = try JSONDecoder().decode(PMNode.self, from: data)
        #expect(decoded.content?.first?.marks?.first?.type == "strong")
    }

    @Test func headingWithIntAttrRoundTrips() throws {
        let h = PMNode(type: "heading", attrs: ["level": .int(2)], content: [PMNode(type: "text", text: "x")])
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(PMNode.self, from: data)
        #expect(decoded.attrs?["level"]?.intValue == 2)
    }

    @Test func valueDecodesAllScalarTypes() throws {
        let blob = "[1, 2.5, \"x\", true, null]"
        let arr = try JSONDecoder().decode([PMValue].self, from: Data(blob.utf8))
        #expect(arr[0] == .int(1))
        #expect(arr[1] == .double(2.5))
        #expect(arr[2] == .string("x"))
        #expect(arr[3] == .bool(true))
        #expect(arr[4] == .null)
    }

    @Test func nullRoundTripsAsNull() throws {
        let m = PMMark(type: "image", attrs: ["title": .null])
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(PMMark.self, from: data)
        #expect(decoded.attrs?["title"] == .null)
    }

    @Test func linkAttrPreservesHref() throws {
        let mark = PMMark(type: "link", attrs: ["href": .string("https://example.com")])
        let data = try JSONEncoder().encode(mark)
        let decoded = try JSONDecoder().decode(PMMark.self, from: data)
        #expect(decoded.attrs?["href"]?.stringValue == "https://example.com")
    }
}
