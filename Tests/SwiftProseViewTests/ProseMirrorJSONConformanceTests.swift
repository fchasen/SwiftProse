import Testing
import Foundation
@testable import SwiftProseView
@testable import SwiftProseSyntax

@Suite("PM JSON conformance")
struct ProseMirrorJSONConformanceTests {

    private let codec = ProseMirrorCodec()

    private func roundTrip(_ json: String) throws -> String {
        let attributed = try codec.decode(json)
        let pmNode = codec.encode(attributed)
        let data = try JSONEncoder().encode(pmNode)
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test
    func paragraphRoundTrips() throws {
        let json = #"""
        {"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"hello"}]}]}
        """#
        let out = try roundTrip(json)
        let decoded = try JSONDecoder().decode(PMNode.self, from: Data(out.utf8))
        #expect(decoded.type == "doc")
        #expect(decoded.content?.first?.type == "paragraph")
        #expect(decoded.content?.first?.content?.first?.text == "hello")
    }

    @Test
    func headingPreservesLevel() throws {
        let json = #"""
        {"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"hi"}]}]}
        """#
        let out = try roundTrip(json)
        let decoded = try JSONDecoder().decode(PMNode.self, from: Data(out.utf8))
        #expect(decoded.content?.first?.type == "heading")
        #expect(decoded.content?.first?.attrs?["level"]?.intValue == 2)
    }

    @Test
    func orderedListEmitsOrderAttr() throws {
        let json = #"""
        {"type":"doc","content":[{"type":"ordered_list","attrs":{"order":3},"content":[
            {"type":"list_item","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]}]}
        ]}]}
        """#
        let out = try roundTrip(json)
        let decoded = try JSONDecoder().decode(PMNode.self, from: Data(out.utf8))
        let list = decoded.content?.first
        #expect(list?.type == "ordered_list")
        #expect(list?.attrs?["order"]?.intValue == 3)
    }

    @Test
    func orderedListAtDefaultOrderOmitsAttr() throws {
        let json = #"""
        {"type":"doc","content":[{"type":"ordered_list","content":[
            {"type":"list_item","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]}]}
        ]}]}
        """#
        let out = try roundTrip(json)
        let decoded = try JSONDecoder().decode(PMNode.self, from: Data(out.utf8))
        let list = decoded.content?.first
        #expect(list?.type == "ordered_list")
        // default order=1 omitted on emit
        #expect(list?.attrs == nil || list?.attrs?["order"] == nil)
    }

    @Test
    func codeBlockUsesParamsKey() throws {
        let json = #"""
        {"type":"doc","content":[{"type":"code_block","attrs":{"params":"swift"},"content":[{"type":"text","text":"let x = 1"}]}]}
        """#
        let out = try roundTrip(json)
        let decoded = try JSONDecoder().decode(PMNode.self, from: Data(out.utf8))
        let cb = decoded.content?.first
        #expect(cb?.type == "code_block")
        #expect(cb?.attrs?["params"]?.stringValue == "swift")
    }

    @Test
    func codeBlockWithoutLangOmitsAttrs() throws {
        let json = #"""
        {"type":"doc","content":[{"type":"code_block","content":[{"type":"text","text":"x"}]}]}
        """#
        let out = try roundTrip(json)
        let decoded = try JSONDecoder().decode(PMNode.self, from: Data(out.utf8))
        let cb = decoded.content?.first
        #expect(cb?.type == "code_block")
        #expect(cb?.attrs == nil)
    }

    @Test
    func imageWithSrcOnlyOmitsAltAndTitle() throws {
        let json = #"""
        {"type":"doc","content":[{"type":"paragraph","content":[
            {"type":"image","attrs":{"src":"https://x/y.png"}}
        ]}]}
        """#
        let out = try roundTrip(json)
        let decoded = try JSONDecoder().decode(PMNode.self, from: Data(out.utf8))
        let img = decoded.content?.first?.content?.first
        #expect(img?.type == "image")
        #expect(img?.attrs?["src"]?.stringValue == "https://x/y.png")
        // alt and title default to "" — omitted on emit
        #expect(img?.attrs?["alt"] == nil)
        #expect(img?.attrs?["title"] == nil)
    }

    @Test
    func linkMarkRoundTrips() throws {
        let json = #"""
        {"type":"doc","content":[{"type":"paragraph","content":[
            {"type":"text","text":"see ","marks":[]},
            {"type":"text","text":"docs","marks":[{"type":"link","attrs":{"href":"https://x"}}]}
        ]}]}
        """#
        let out = try roundTrip(json)
        let decoded = try JSONDecoder().decode(PMNode.self, from: Data(out.utf8))
        let link = decoded.content?.first?.content?.last?.marks?.first
        #expect(link?.type == "link")
        #expect(link?.attrs?["href"]?.stringValue == "https://x")
    }
}
