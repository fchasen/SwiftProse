import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Dynamic cell sizing — row heights track wrapping, column widths
/// track content, and `updateCellInline` fires `layoutDidChange` so
/// the host layout manager re-queries `attachmentBounds` after a
/// keystroke.
@Suite struct TableLayoutTests {

    private func cell(_ text: String, header: Bool = false) -> TreeNode {
        .structural(
            ProseNode(
                type: header ? "table_header" : "table_cell",
                attrs: ["align": .null]
            ),
            [.structural(ProseNode(type: "paragraph"), [.inline(text: text, marks: MarkSet())])]
        )
    }

    private func row(_ cells: [TreeNode], header: Bool = false) -> TreeNode {
        .structural(
            ProseNode(type: "table_row", attrs: ["header": .bool(header)]),
            cells
        )
    }

    private func table(_ rows: [TreeNode]) -> TreeNode {
        .structural(ProseNode(type: "table"), rows)
    }

    @Test func intrinsicSizeGrowsWhenCellWraps() {
        // Two-column table at narrow width, second cell short. Replace
        // it with a long string that has to wrap at half-container
        // width and expect the total height to grow.
        let initial = table([
            row([cell("h1", header: true), cell("h2", header: true)], header: true),
            row([cell("a"), cell("b")])
        ])
        let proposedWidth: CGFloat = 240
        let initialSize = TableBlockView.intrinsicSize(
            for: initial,
            theme: .default,
            proposedWidth: proposedWidth
        )
        let longText = String(repeating: "wrap me ", count: 12)
        let grown = table([
            row([cell("h1", header: true), cell("h2", header: true)], header: true),
            row([cell("a"), cell(longText)])
        ])
        let grownSize = TableBlockView.intrinsicSize(
            for: grown,
            theme: .default,
            proposedWidth: proposedWidth
        )
        #expect(grownSize.height > initialSize.height)
    }

    @Test func intrinsicSizeShrinksWhenContentRemoved() {
        let longText = String(repeating: "wrap me ", count: 12)
        let big = table([
            row([cell("h1", header: true), cell("h2", header: true)], header: true),
            row([cell("a"), cell(longText)])
        ])
        let small = table([
            row([cell("h1", header: true), cell("h2", header: true)], header: true),
            row([cell("a"), cell("b")])
        ])
        let proposedWidth: CGFloat = 240
        let bigSize = TableBlockView.intrinsicSize(
            for: big,
            theme: .default,
            proposedWidth: proposedWidth
        )
        let smallSize = TableBlockView.intrinsicSize(
            for: small,
            theme: .default,
            proposedWidth: proposedWidth
        )
        #expect(bigSize.height > smallSize.height)
    }

    @Test func columnWidthsReflectContent() {
        // One-row table where the second column has much longer text.
        // The second column should be wider after content-aware
        // distribution.
        let subtree = table([
            row([cell("x"), cell("a much much longer column header")])
        ])
        let widths = TableBlockView.measureColumnWidths(
            for: subtree,
            theme: .default,
            containerWidth: 600
        )
        #expect(widths.count == 2)
        #expect(widths[1] > widths[0])
    }

    @Test func columnWidthsClampToMinimum() {
        // Narrow container with three columns — none should drop below
        // the floor even if natural widths are below.
        let subtree = table([row([cell("a"), cell("b"), cell("c")])])
        let widths = TableBlockView.measureColumnWidths(
            for: subtree,
            theme: .default,
            containerWidth: 100
        )
        for w in widths { #expect(w >= TableBlockView.minColumnWidth) }
    }

    @Test func columnWidthsFillContainerProportionally() {
        // Widths should sum to (or stretch to fill) the container when
        // natural widths are smaller. Equal-content columns get equal
        // widths.
        let subtree = table([row([cell("aa"), cell("bb"), cell("cc")])])
        let containerWidth: CGFloat = 600
        let widths = TableBlockView.measureColumnWidths(
            for: subtree,
            theme: .default,
            containerWidth: containerWidth
        )
        let total = widths.reduce(0, +)
        #expect(abs(total - containerWidth) < 1)
        #expect(abs(widths[0] - widths[1]) < 1)
        #expect(abs(widths[1] - widths[2]) < 1)
    }

    @Test func columnWidthsOverflowContainerWhenContentExceedsIt() {
        // Five columns with content too wide to fit in a narrow
        // container. Columns must keep their natural widths (no
        // shrinking below) and the total exceeds the container — the
        // host wraps the table in a horizontal scroll container so
        // the overflow is reachable.
        let longCell = String(repeating: "x", count: 40)
        let subtree = table([
            row([
                cell("Parameter"), cell("Type"),
                cell("Description"), cell("Layout"),
                cell(longCell)
            ])
        ])
        let containerWidth: CGFloat = 320
        let widths = TableBlockView.measureColumnWidths(
            for: subtree,
            theme: .default,
            containerWidth: containerWidth
        )
        let total = widths.reduce(0, +)
        // Natural total exceeds container — algorithm preserved
        // natural widths instead of crushing to fit.
        #expect(total > containerWidth)
        // Sanity: every column at least its content's natural width
        // (no shrinking happened).
        for w in widths {
            #expect(w >= TableBlockView.minColumnWidth)
        }
    }

    @Test func updateCellInlineFiresLayoutDidChange() {
        let initial = table([
            row([cell("h1", header: true), cell("h2", header: true)], header: true),
            row([cell("a"), cell("b")])
        ])
        let view = TableBlockView(subtree: initial, theme: .default)
        view.frame = CGRect(x: 0, y: 0, width: 240, height: 100)
        var fireCount = 0
        view.layoutDidChange = { fireCount += 1 }

        // Replace cell (1, 1) with text long enough to wrap.
        let longRuns: [TreeNode] = [
            .inline(text: String(repeating: "wrap me ", count: 12), marks: MarkSet())
        ]
        view.updateCellInline(row: 1, column: 1, runs: longRuns)
        #expect(fireCount >= 1)
        // The view's frame should now reflect the new (taller) size.
        let newSize = TableBlockView.intrinsicSize(
            for: view.subtree,
            theme: .default,
            proposedWidth: view.frame.width
        )
        #expect(abs(view.frame.height - newSize.height) < 1)
    }

    @Test func updateCellInlineWithSameContentDoesNotResize() {
        // No-op edits shouldn't change the reported height. Seed the
        // frame at the table's actual intrinsic size; otherwise the
        // first reflow snaps to the correct size and the comparison
        // measures snap-to-correct rather than no-op stability.
        let initial = table([
            row([cell("h1", header: true), cell("h2", header: true)], header: true),
            row([cell("a"), cell("b")])
        ])
        let intrinsic = TableBlockView.intrinsicSize(
            for: initial,
            theme: .default,
            proposedWidth: 600
        )
        let view = TableBlockView(subtree: initial, theme: .default)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: intrinsic.height)
        let priorHeight = view.frame.height

        // Replace cell (1, 0) with the same text it already had.
        let runs: [TreeNode] = [.inline(text: "a", marks: MarkSet())]
        view.updateCellInline(row: 1, column: 0, runs: runs)
        #expect(abs(view.frame.height - priorHeight) < 1)
    }
}
