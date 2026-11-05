import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum TableActionCases {
    struct Case: CustomTestStringConvertible, Sendable {
        let action: EditorAction
        let caret: (row: Int, column: Int)
        let expected: String
        var testDescription: String { action.stableID }
    }

    static let source = "| a | b |\n| --- | --- |\n| **1** | 2 |"

    static let all: [Case] = [
        Case(action: .insertTableRowAbove, caret: (1, 0), expected: "| a | b |\n| --- | --- |\n| | |\n| **1** | 2 |"),
        Case(action: .insertTableRowAbove, caret: (0, 1), expected: "| | |\n| --- | --- |\n| a | b |\n| **1** | 2 |"),
        Case(action: .insertTableRowBelow, caret: (0, 0), expected: "| a | b |\n| --- | --- |\n| | |\n| **1** | 2 |"),
        Case(action: .insertTableColumnBefore, caret: (1, 1), expected: "| a | | b |\n| --- | --- | --- |\n| **1** | | 2 |"),
        Case(action: .insertTableColumnAfter, caret: (0, 1), expected: "| a | b | |\n| --- | --- | --- |\n| **1** | 2 | |"),
        Case(action: .deleteTableRow, caret: (0, 0), expected: "| **1** | 2 |\n| --- | --- |"),
        Case(action: .deleteTableRow, caret: (1, 0), expected: "| a | b |\n| --- | --- |"),
        Case(action: .deleteTableColumn, caret: (1, 0), expected: "| b |\n| --- |\n| 2 |"),
        Case(action: .setTableColumnAlignment(.right), caret: (1, 1), expected: "| a | b |\n| --- | ---: |\n| **1** | 2 |"),
        Case(action: .setTableColumnAlignment(.center), caret: (0, 0), expected: "| a | b |\n| :---: | --- |\n| **1** | 2 |"),
        Case(action: .deleteTable, caret: (1, 1), expected: "")
    ]
}

@Suite("Table controller", .serialized)
@MainActor
struct TableControllerTests {
    @Test(arguments: [
        "|a|b|\n|-|:-:|\n|1|2|",
        "Intro\n\n| Name   | Value |\n| :----- | ----: |\n| x      |     1 |\n\nTail",
        "> a | b\n> --|--\n> 1 | 2"
    ])
    func untouchedTablesKeepTheirBytes(markdown: String) {
        let controller = EditorController(markdown: markdown)
        #expect(controller.markdown() == markdown)
        let end = controller.textStorage.length
        controller.setSelection(NSRange(location: end, length: 0))
        controller.insertMarkdown("x")
        #expect(controller.markdown() != markdown)
        controller.undoManager.undo()
        #expect(controller.markdown() == markdown)
    }

    @Test func insertTableCreatesHeaderAndBodyRows() {
        let controller = EditorController(markdown: "")
        #expect(controller.canPerform(.insertTable(rows: 1, columns: 2)))
        #expect(!controller.canPerform(.insertTableRowBelow))
        controller.perform(.insertTable(rows: 1, columns: 2))
        #expect(controller.markdown() == "| | |\n| --- | --- |\n| | |")
        #expect(controller.currentSelection == NSRange(location: 0, length: 0))
        #expect(controller.canPerform(.insertTableRowBelow))
        #expect(controller.isActive(.setTableColumnAlignment(.none)))
        controller.undoManager.undo()
        #expect(controller.markdown() == "")
    }

    @Test func insertTableAfterTextKeepsTheParagraph() {
        let controller = EditorController(markdown: "Intro\n\nTail")
        controller.setSelection(NSRange(location: 2, length: 0))
        controller.perform(.insertTable(rows: 0, columns: 1))
        #expect(controller.markdown() == "Intro\n\n| |\n| --- |\n\nTail")
        #expect(controller.currentSelection.location == 6)
    }

    @Test(arguments: TableActionCases.all)
    func structuralActionsAreSingleUndoSteps(_ testCase: TableActionCases.Case) {
        let controller = EditorController(markdown: TableActionCases.source)
        let caret = TableFixture.cellStart(controller.textStorage, row: testCase.caret.row, column: testCase.caret.column)
        controller.setSelection(NSRange(location: caret, length: 0))
        #expect(controller.canPerform(testCase.action))
        controller.perform(testCase.action)
        #expect(controller.markdown() == testCase.expected)
        #expect(controller.undoManager.canUndo)
        controller.undoManager.undo()
        #expect(controller.markdown() == TableActionCases.source)
        controller.undoManager.redo()
        #expect(controller.markdown() == testCase.expected)
    }

    @Test func alignmentStateFollowsTheCaretColumn() {
        let controller = EditorController(markdown: "| a | b |\n| :--- | ---: |")
        controller.setSelection(NSRange(location: 0, length: 0))
        #expect(controller.isActive(.setTableColumnAlignment(.left)))
        #expect(!controller.isActive(.setTableColumnAlignment(.right)))
        controller.setSelection(NSRange(location: 3, length: 0))
        #expect(controller.isActive(.setTableColumnAlignment(.right)))
        #expect(controller.activeActionIDs().contains(EditorAction.setTableColumnAlignment(.right).stableID))
    }

    @Test func blockActionsAreDisabledInsideCells() {
        let controller = EditorController(markdown: "| a |\n| --- |")
        controller.setSelection(NSRange(location: 1, length: 0))
        #expect(!controller.canPerform(.heading(level: 1)))
        #expect(!controller.canPerform(.unorderedList))
        #expect(!controller.canPerform(.horizontalRule))
        #expect(controller.canPerform(.bold))
        #expect(controller.canPerform(.editTableStructure))
    }

    @Test func editTableStructureHandsTheModelToTheHost() throws {
        let controller = EditorController(markdown: TableActionCases.source)
        var received: TableStructureModel?
        controller.onEditTableStructure = { received = $0 }
        controller.setSelection(NSRange(location: 0, length: 0))
        controller.perform(.editTableStructure)
        let model = try #require(received)
        #expect(model.previews == [["a", "b"], ["1", "2"]])
        #expect(model.rowCount == 2)
        #expect(model.columnCount == 2)
    }

    @Test func applyingTheStructureKeepsCellContent() throws {
        let controller = EditorController(markdown: TableActionCases.source)
        controller.setSelection(NSRange(location: 0, length: 0))
        var model = try #require(controller.tableStructure() as TableStructureModel?)
        model.moveColumn(from: 1, to: 0)
        model.moveRow(from: 1, to: 0)
        model.insertRow(at: 2)
        model.setAlignment(.center, forColumn: 1)
        model.insertColumn(at: 2, alignment: .right)
        #expect(controller.applyTableStructure(model))
        #expect(controller.markdown() == "| 2 | **1** | |\n| --- | :---: | ---: |\n| b | a | |\n| | | |")
        controller.undoManager.undo()
        #expect(controller.markdown() == TableActionCases.source)
    }
}

@Suite("Table structure model", .serialized)
struct TableStructureModelTests {
    @Test func operationsKeepAtLeastOneRowAndColumn() {
        var model = TableStructureModel(previews: [["a"]], alignments: [.left])
        model.deleteRow(at: 0)
        model.deleteColumn(at: 0)
        #expect(model.rowCount == 1)
        #expect(model.columnCount == 1)
        model.setRowCount(0)
        model.setColumnCount(-3)
        #expect(model.rowCount == 1)
        #expect(model.columnCount == 1)
    }

    @Test func previewsFollowMovedRowsAndColumns() {
        var model = TableStructureModel(previews: [["a", "b"], ["1", "2"], ["x", "y"]], alignments: [.none, .right])
        model.moveRow(from: 2, to: 0)
        model.moveColumn(from: 0, to: 1)
        #expect(model.preview(row: 0, column: 0) == "y")
        #expect(model.preview(row: 0, column: 1) == "x")
        #expect(model.alignments == [.right, .none])
        model.moveRows(fromOffsets: IndexSet([0]), toOffset: 3)
        #expect(model.preview(row: 2, column: 1) == "x")
        model.insertColumn(at: 1, alignment: .center)
        #expect(model.preview(row: 0, column: 1) == "")
        #expect(model.sourceCell(row: 0, column: 1) == nil)
        model.setRowCount(5)
        model.setColumnCount(2)
        #expect(model.rowCount == 5)
        #expect(model.alignments == [.right, .center])
    }

    @Test func emptyTableModelHasAHeader() {
        let model = TableStructureModel(columns: 3, bodyRows: 2)
        #expect(model.rowCount == 3)
        #expect(model.columnCount == 3)
        #expect(model.preview(row: 1, column: 1) == "")
    }
}

#if canImport(AppKit) && os(macOS)
@Suite("Table editing (macOS, .serialized)")
@MainActor
struct TableEditingTests {
    static let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"

    @Test func typingInACellUpdatesTheMarkdown() {
        let harness = EditorHarness(markdown: Self.source)
        harness.select(TableFixture.cellStart(harness.storage, row: 1, column: 1) + 1)
        harness.typeEach("x|")
        #expect(harness.markdown == "| a | b |\n| --- | --- |\n| 1 | 2x\\| |")
        #expect(TableFixture.rows(harness.storage) == ["a\tb", "1\t2x|"])
    }

    @Test func blockInputRulesStayOffInsideCells() {
        let harness = EditorHarness(markdown: "| a |\n| --- |\n| |")
        harness.select(TableFixture.cellStart(harness.storage, row: 1, column: 0))
        harness.typeEach("# - x")
        #expect(harness.markdown == "| a |\n| --- |\n| # - x |")
        #expect(harness.paragraphBlocks.allSatisfy { $0?.isTableRow == true })
    }

    @Test func backspaceAndForwardDeleteStepOverSeparators() {
        let harness = EditorHarness(markdown: Self.source)
        let b = TableFixture.cellStart(harness.storage, row: 0, column: 1)
        harness.select(b)
        harness.deleteBackward()
        #expect(harness.markdown == Self.source)
        #expect(harness.selection == NSRange(location: b - 1, length: 0))
        harness.step { harness.textView.doCommand(by: #selector(NSResponder.deleteForward(_:))) }
        #expect(harness.markdown == Self.source)
        #expect(harness.selection == NSRange(location: b, length: 0))
        let one = TableFixture.cellStart(harness.storage, row: 1, column: 0)
        harness.select(one)
        harness.deleteBackward()
        #expect(harness.markdown == Self.source)
        #expect(harness.selection.location == one - 1)
    }

    @Test func deletingASelectionAcrossCellsKeepsSeparators() {
        let harness = EditorHarness(markdown: Self.source)
        harness.select(NSRange(location: 0, length: TableFixture.cellStart(harness.storage, row: 1, column: 1)))
        harness.deleteBackward()
        #expect(TableFixture.rows(harness.storage) == ["\t", "\t2"])
        #expect(harness.markdown == "| | |\n| --- | --- |\n| | 2 |")
        harness.undo()
        #expect(harness.markdown == Self.source)
    }

    @Test func typingOverCellsPutsTextInTheFirstCell() {
        let harness = EditorHarness(markdown: Self.source)
        harness.select(NSRange(location: 0, length: 3))
        harness.type("z")
        #expect(TableFixture.rows(harness.storage) == ["z\t", "1\t2"])
        #expect(harness.selection == NSRange(location: 1, length: 0))
    }

    @Test func cutAcrossCellsKeepsSeparators() {
        let harness = EditorHarness(markdown: Self.source)
        let range = NSRange(location: 0, length: harness.storage.length)
        #expect(harness.controller.deleteForCut(NSRange(location: 1, length: 4)))
        #expect(TableFixture.rows(harness.storage) == ["a\t", "\t2"])
        harness.undo()
        #expect(harness.controller.shouldChangeText(in: NSRange(location: 1, length: 4), replacement: "") == false)
        #expect(TableFixture.rows(harness.storage) == ["a\t", "\t2"])
        harness.undo()
        #expect(harness.controller.deleteForCut(range))
        #expect(harness.string.isEmpty)
    }

    @Test func tabAndShiftTabSelectCells() {
        let harness = EditorHarness(markdown: "| ab | cd |\n| --- | --- |\n| ef | gh |")
        harness.select(1)
        harness.insertTab()
        #expect(harness.selection == TableFixture.cellRange(harness.storage, row: 0, column: 1))
        harness.insertTab()
        #expect(harness.selection == TableFixture.cellRange(harness.storage, row: 1, column: 0))
        harness.insertBacktab()
        #expect(harness.selection == TableFixture.cellRange(harness.storage, row: 0, column: 1))
        harness.select(TableFixture.cellStart(harness.storage, row: 1, column: 1))
        harness.insertTab()
        #expect(TableFixture.rows(harness.storage) == ["ab\tcd", "ef\tgh", "\t"])
        #expect(harness.selection == NSRange(location: TableFixture.cellStart(harness.storage, row: 2, column: 0), length: 0))
        harness.type("x")
        #expect(harness.markdown == "| ab | cd |\n| --- | --- |\n| ef | gh |\n| x | |")
    }

    @Test func returnMovesDownAndAppendsThenExits() {
        let harness = EditorHarness(markdown: Self.source)
        harness.select(TableFixture.cellStart(harness.storage, row: 0, column: 1))
        harness.insertNewline()
        #expect(harness.selection.location == NSMaxRange(TableFixture.cellRange(harness.storage, row: 1, column: 1)))
        harness.insertNewline()
        #expect(TableFixture.rows(harness.storage) == ["a\tb", "1\t2", "\t"])
        #expect(harness.selection.location == TableFixture.cellStart(harness.storage, row: 2, column: 1))
        harness.insertNewline()
        #expect(TableFixture.rows(harness.storage) == ["a\tb", "1\t2"])
        harness.type("after")
        #expect(harness.markdown == Self.source + "\n\nafter")
    }

    @Test func pastedNewlinesInsideACellBecomeSpaces() {
        let harness = EditorHarness(markdown: Self.source)
        let caret = TableFixture.cellStart(harness.storage, row: 1, column: 0) + 1
        harness.controller.paste(PastePayload(plainText: "x\ny"), replacing: NSRange(location: caret, length: 0))
        #expect(harness.markdown == "| a | b |\n| --- | --- |\n| 1x y | 2 |")
        harness.controller.paste(PastePayload(plainText: "p\tq", forcePlain: true), replacing: NSRange(location: 0, length: 0))
        #expect(TableFixture.rows(harness.storage).first == "p qa\tb")
    }

    @Test func pastingATableAtAParagraphBoundaryMakesATable() {
        let harness = EditorHarness(markdown: "Intro\n\nTail")
        harness.controller.paste(
            PastePayload(plainText: "| x | y |\n|---|---|\n| 1 | 2 |"),
            replacing: NSRange(location: 6, length: 0)
        )
        #expect(harness.markdown == "Intro\n\n| x | y |\n| --- | --- |\n| 1 | 2 |\n\nTail")
        #expect(TableFixture.rows(harness.storage) == ["x\ty", "1\t2"])
    }

    @Test func pastingATableIntoACellFlattensIt() {
        let harness = EditorHarness(markdown: "| a |\n| --- |")
        harness.controller.paste(PastePayload(markdown: "| x | y |\n|---|---|"), replacing: NSRange(location: 1, length: 0))
        #expect(TableFixture.rows(harness.storage) == ["ax y"])
    }

    @Test func separatorsLostToWritingToolsAreRestored() {
        let harness = EditorHarness(markdown: Self.source)
        harness.controller.writingToolsWillBegin()
        harness.storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "z")
        harness.controller.writingToolsDidEnd()
        harness.settle()
        #expect(TableFixture.rows(harness.storage) == ["z\t", "1\t2"])
        #expect(harness.storage.attribute(.markdownTableSeparator, at: 1, effectiveRange: nil) != nil)
    }

    @Test func typingBelowAnInsertedTableMakesAParagraph() {
        let harness = EditorHarness(markdown: "")
        harness.controller.perform(.insertTable(rows: 1, columns: 2))
        harness.select(harness.storage.length)
        harness.typeEach("x")
        #expect(harness.markdown == "| | |\n| --- | --- |\n| | |\n\nx")
    }

    @Test func deletingAWholeTableRemovesIt() {
        let harness = EditorHarness(markdown: "Intro\n\n" + Self.source + "\n\nTail")
        let start = TableFixture.cellStart(harness.storage, row: 0, column: 0)
        let end = NSMaxRange(TableFixture.cellRange(harness.storage, row: 1, column: 1))
        harness.select(NSRange(location: start, length: end - start))
        harness.deleteBackward()
        #expect(harness.markdown == "Intro\n\nTail")
        harness.undo()
        #expect(harness.markdown == "Intro\n\n" + Self.source + "\n\nTail")
    }

    @Test func selectionFromAParagraphIntoATableKeepsTheTable() {
        let harness = EditorHarness(markdown: "Intro\n\n" + Self.source)
        harness.select(NSRange(location: 2, length: 6))
        harness.deleteBackward()
        #expect(harness.paragraphTexts == ["In", "\tb", "1\t2"])
        #expect(harness.markdown == "In\n\n| | b |\n| --- | --- |\n| 1 | 2 |")
    }

    @Test func deletingAroundATableMovesTheCaret() {
        let harness = EditorHarness(markdown: "Intro\n\n" + Self.source + "\n\nTail")
        harness.select(5)
        harness.step { harness.textView.doCommand(by: #selector(NSResponder.deleteForward(_:))) }
        #expect(harness.selection.location == 6)
        harness.select(harness.storage.length - 4)
        harness.deleteBackward()
        #expect(harness.selection.location == NSMaxRange(TableFixture.cellRange(harness.storage, row: 1, column: 1)))
        #expect(harness.markdown == "Intro\n\n" + Self.source + "\n\nTail")
        harness.select(6)
        harness.deleteBackward()
        #expect(harness.selection.location == 5)
        #expect(harness.markdown == "Intro\n\n" + Self.source + "\n\nTail")
    }

    @Test func lineBreaksTypedIntoACellAreDropped() {
        let harness = EditorHarness(markdown: Self.source)
        harness.select(1)
        harness.insertLineBreak()
        harness.type("x\u{2028}y")
        #expect(TableFixture.rows(harness.storage).first == "ax y\tb")
    }

    @Test func wideningACellRelaysEveryRow() throws {
        let harness = EditorHarness(markdown: Self.source)
        harness.spin()
        harness.select(TableFixture.cellStart(harness.storage, row: 1, column: 0) + 1)
        harness.typeEach(" much longer cell text")
        harness.spin()
        let header = try #require(harness.controller.rect(forCharacterAt: TableFixture.cellStart(harness.storage, row: 0, column: 1)))
        let body = try #require(harness.controller.rect(forCharacterAt: TableFixture.cellStart(harness.storage, row: 1, column: 1)))
        #expect(abs(header.minX - body.minX) < 1)
        #expect(header.minX > 150)
    }

    @Test func rowsShareTabStopsAndDrawContiguousBorders() throws {
        let harness = EditorHarness(markdown: "| a | wide header text |\n| :---: | ---: |\n| longer body cell | 1 |\n| x | 22 |")
        harness.spin()
        let storage = harness.storage
        let rows = storage.markdownParagraphRanges().filter { $0.length > 0 }
        let styles = rows.compactMap { storage.attribute(.paragraphStyle, at: $0.location, effectiveRange: nil) as? NSParagraphStyle }
        #expect(styles.count == 3)
        #expect(Set(styles.map { $0.tabStops.map(\.location) }).count == 1)
        #expect(styles[0].tabStops.first?.alignment == .right)
        let layout = harness.controller.textLayoutManager
        let content = harness.controller.textContentStorage
        layout.ensureLayout(for: content.documentRange)
        var fragments: [TableRowLayoutFragment] = []
        for row in rows {
            let location = try #require(content.location(content.documentRange.location, offsetBy: row.location))
            fragments.append(try #require(layout.textLayoutFragment(for: location) as? TableRowLayoutFragment))
        }
        let rects = try fragments.map { fragment -> CGRect in
            let geometry = try #require(fragment.geometry)
            let rect = try #require(fragment.rowRect(geometry))
            return rect.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        }
        for (upper, lower) in zip(rects, rects.dropFirst()) {
            #expect(abs(upper.maxY - lower.minY) < 0.5)
            #expect(abs(upper.minX - lower.minX) < 0.5)
            #expect(abs(upper.width - lower.width) < 0.5)
        }
        let geometry = try #require(fragments[0].geometry)
        #expect(geometry.columnEdges.count == 3)
        let rightEdge = geometry.columnEdges[2] - TableMetrics.cellPadding.width
        for row in 0..<3 {
            let cell = TableFixture.cellRange(storage, row: row, column: 1)
            let end = try #require(harness.controller.rect(forCharacterAt: NSMaxRange(cell)))
            let origin = harness.textView.textContainerOrigin.x + harness.controller.textContainer.lineFragmentPadding
            #expect(abs(end.minX - origin - rightEdge) < 2)
        }
    }
}
#endif

#if canImport(UIKit) && os(iOS)
@MainActor
@Suite("Table editing (iOS host, .serialized)")
struct IOSTableEditingTests {
    static let source = "| a | b |\n| --- | --- |\n| 1 | 2 |"

    @Test func typingInACellUpdatesTheMarkdown() {
        let host = IOSHostHarness(markdown: Self.source)
        host.select(TableFixture.cellStart(host.storage, row: 1, column: 1) + 1)
        host.type("x|")
        host.spin()
        #expect(host.markdown == "| a | b |\n| --- | --- |\n| 1 | 2x\\| |")
        #expect(host.box.text == host.markdown)
    }

    @Test func tabSelectsTheNextCellAndAppendsARow() {
        let host = IOSHostHarness(markdown: Self.source)
        host.select(0)
        host.textView.handleTabCommand(nil)
        #expect(host.textView.selectedRange == TableFixture.cellRange(host.storage, row: 0, column: 1))
        host.textView.handleShiftTab(nil)
        #expect(host.textView.selectedRange == TableFixture.cellRange(host.storage, row: 0, column: 0))
        host.select(TableFixture.cellStart(host.storage, row: 1, column: 1) + 1)
        host.key("\t")
        #expect(TableFixture.rows(host.storage) == ["a\tb", "1\t2", "\t"])
        host.type("z")
        host.spin()
        #expect(host.markdown == "| a | b |\n| --- | --- |\n| 1 | 2 |\n| z | |")
    }

    @Test func backspaceAtACellStartKeepsTheSeparator() {
        let host = IOSHostHarness(markdown: Self.source)
        let b = TableFixture.cellStart(host.storage, row: 0, column: 1)
        host.select(b)
        host.backspace()
        #expect(host.markdown == Self.source)
        #expect(host.textView.selectedRange == NSRange(location: b - 1, length: 0))
        host.select(b - 1)
        let forward = NSRange(location: b - 1, length: 1)
        #expect(host.coordinator.textView(host.textView, shouldChangeTextIn: forward, replacementText: "") == false)
        #expect(host.markdown == Self.source)
        #expect(host.textView.selectedRange == NSRange(location: b, length: 0))
    }

    @Test func returnMovesToTheNextRow() {
        let host = IOSHostHarness(markdown: Self.source)
        host.select(1)
        host.key("\n")
        #expect(host.textView.selectedRange.location == NSMaxRange(TableFixture.cellRange(host.storage, row: 1, column: 0)))
        #expect(host.markdown == Self.source)
    }
}
#endif
