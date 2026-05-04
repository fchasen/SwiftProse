import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite struct PipeTableCodecTests {

    @Test func decodeTableJSONProducesPipeTableStorage() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"table","content":[
            {"type":"table_row","content":[
              {"type":"table_header","attrs":{"colspan":1,"rowspan":1,"align":"left"},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"Name"}]}
              ]},
              {"type":"table_header","attrs":{"colspan":1,"rowspan":1,"align":"right"},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"Age"}]}
              ]}
            ]},
            {"type":"table_row","content":[
              {"type":"table_cell","attrs":{"colspan":1,"rowspan":1},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"Ann"}]}
              ]},
              {"type":"table_cell","attrs":{"colspan":1,"rowspan":1},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"30"}]}
              ]}
            ]}
          ]}
        ]}
        """
        let attributed = try ProseMirrorCodec().decode(json)
        // Storage should contain a contiguous .pipeTable run.
        #expect(attributed.string.contains("Name"))
        #expect(attributed.string.contains("Ann"))
        if case .pipeTable = attributed.blockSpec(at: 0)?.kind {
            // ok
        } else {
            Issue.record("expected pipeTable spec at offset 0")
        }
        // Re-parse the stored source — it must be a valid GFM table.
        let model = PipeTableModel.parse(at: 0, in: attributed)
        #expect(model?.headerCells == ["Name", "Age"])
        #expect(model?.alignments == [.left, .right])
        #expect(model?.bodyRows.first == ["Ann", "30"])
    }

    @Test func encodePipeTableStorageProducesTableTree() throws {
        let source = """
        | Name | Age |
        | :--- | --: |
        | Ann  | 30  |
        """ + "\n"
        let compiler = try MarkdownAttributedCompiler()
        let attributed = compiler.compile(source, theme: .default)
        let pm = ProseMirrorCodec().encode(attributed)
        #expect(pm.type == "doc")
        #expect(pm.content?.first?.type == "table")
        let rows = pm.content?.first?.content ?? []
        #expect(rows.count == 2)
        #expect(rows.first?.type == "table_row")
        // First row's cells should be headers with the parsed alignments.
        let headerCells = rows.first?.content ?? []
        #expect(headerCells.count == 2)
        #expect(headerCells.first?.type == "table_header")
        #expect(headerCells.first?.attrs?["align"]?.stringValue == "left")
        #expect(headerCells.last?.attrs?["align"]?.stringValue == "right")
    }

    @Test func roundTripPreservesStructuralTree() throws {
        let json = """
        {"type":"doc","content":[
          {"type":"table","content":[
            {"type":"table_row","content":[
              {"type":"table_header","attrs":{"colspan":1,"rowspan":1,"align":"center"},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"H1"}]}
              ]},
              {"type":"table_header","attrs":{"colspan":1,"rowspan":1},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"H2"}]}
              ]}
            ]},
            {"type":"table_row","content":[
              {"type":"table_cell","attrs":{"colspan":1,"rowspan":1},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"a"}]}
              ]},
              {"type":"table_cell","attrs":{"colspan":1,"rowspan":1},"content":[
                {"type":"paragraph","content":[{"type":"text","text":"b"}]}
              ]}
            ]}
          ]}
        ]}
        """
        let codec = ProseMirrorCodec()
        let attributed = try codec.decode(json)
        let reEncoded = codec.encode(attributed)
        let table = reEncoded.content?.first
        #expect(table?.type == "table")
        let rows = table?.content ?? []
        #expect(rows.count == 2)
        // Header cells preserved
        #expect(rows.first?.content?.first?.attrs?["align"]?.stringValue == "center")
        // Body cell text preserved
        #expect(rows.last?.content?.first?.content?.first?.content?.first?.text == "a")
    }
}
