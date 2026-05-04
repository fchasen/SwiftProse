import Testing
import Foundation
@testable import SwiftProseSyntax

@Suite struct PipeTableModelTests {

    @Test func parsesThreeColumnTableWithMixedAlignments() {
        let source = """
        | Name | Age | City |
        | :--- | --: | :-:  |
        | Ann  | 30  | NYC  |
        | Bob  | 25  | LA   |
        """
        let model = PipeTableModel.parse(source: source + "\n")
        #expect(model != nil)
        #expect(model?.columnCount == 3)
        #expect(model?.headerCells == ["Name", "Age", "City"])
        #expect(model?.alignments == [.left, .right, .center])
        #expect(model?.bodyRows.count == 2)
        #expect(model?.bodyRows.first == ["Ann", "30", "NYC"])
        #expect(model?.bodyRows.last == ["Bob", "25", "LA"])
    }

    @Test func handlesEscapedPipes() {
        let source = """
        | Symbol | Meaning |
        | --- | --- |
        | a \\| b | or |
        """
        let model = PipeTableModel.parse(source: source + "\n")
        #expect(model?.bodyRows.first == ["a | b", "or"])
    }

    @Test func parsesTableWithoutOuterPipes() {
        let source = """
        Header A | Header B
        --- | ---
        cell 1 | cell 2
        """
        let model = PipeTableModel.parse(source: source + "\n")
        #expect(model?.headerCells == ["Header A", "Header B"])
        #expect(model?.bodyRows.first == ["cell 1", "cell 2"])
    }

    @Test func rejectsSourceWithoutAlignmentRow() {
        let source = """
        | Header A | Header B |
        | cell 1   | cell 2   |
        """
        #expect(PipeTableModel.parse(source: source + "\n") == nil)
    }

    @Test func renderSourceRoundTripsParsedTable() {
        let original = """
        | Name | Age |
        | :--- | --: |
        | Ann  | 30  |
        """
        let parsed = PipeTableModel.parse(source: original + "\n")
        guard let parsed else { Issue.record("expected parse"); return }
        let rendered = parsed.renderSource()
        // The reparsed render must produce an equivalent model.
        let reparsed = PipeTableModel.parse(source: rendered)
        #expect(reparsed?.headerCells == parsed.headerCells)
        #expect(reparsed?.alignments == parsed.alignments)
        #expect(reparsed?.bodyRows == parsed.bodyRows)
    }

    @Test func insertingRowExtendsTable() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
        let model = PipeTableModel.parse(source: source)!
        let mutated = model.insertingRow(after: 0)
        #expect(mutated.bodyRows.count == 2)
        #expect(mutated.bodyRows.last == ["", ""])
    }

    @Test func deletingColumnReshapesAlignments() {
        let source = "| a | b | c |\n| :--- | --- | --: |\n| 1 | 2 | 3 |\n"
        let model = PipeTableModel.parse(source: source)!
        let mutated = model.deletingColumn(at: 1)
        #expect(mutated.columnCount == 2)
        #expect(mutated.headerCells == ["a", "c"])
        #expect(mutated.alignments == [.left, .right])
        #expect(mutated.bodyRows.first == ["1", "3"])
    }

    @Test func settingAlignmentRewritesAlignmentRow() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
        let model = PipeTableModel.parse(source: source)!
        let mutated = model.settingAlignment(.center, forColumn: 1)
        let rendered = mutated.renderSource()
        let reparsed = PipeTableModel.parse(source: rendered)
        #expect(reparsed?.alignments == [.none, .center])
    }

    @Test func settingCellTextEscapesPipes() {
        let source = "| a | b |\n| --- | --- |\n| x | y |\n"
        let model = PipeTableModel.parse(source: source)!
        let mutated = model.settingCellText("a | b", row: 0, column: 1)
        // The body's column 1 text should now contain the escaped form.
        #expect(mutated.bodyRows[0][1] == "a \\| b")
        // Rendered + reparsed: the cell text must round-trip to "a | b".
        let reparsed = PipeTableModel.parse(source: mutated.renderSource())
        #expect(reparsed?.bodyRows[0][1] == "a | b")
    }

    @Test func stubProducesValidTable() {
        let stub = PipeTableModel.stub(columnCount: 3, bodyRowCount: 2)
        let rendered = stub.renderSource()
        let reparsed = PipeTableModel.parse(source: rendered)
        #expect(reparsed?.columnCount == 3)
        #expect(reparsed?.bodyRows.count == 2)
        #expect(reparsed?.alignments == [.none, .none, .none])
    }
}
