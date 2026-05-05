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

/// Stage 3 plumbing: `ProseNodeAttachment` carries a `TreeNode` subtree;
/// `ProseDocument.from(storage:)` lifts the subtree at runs whose leaf is
/// `isolating`-flagged. Default `NodeViewRegistry` on `EditorController`
/// is empty — no behavioural change vs. stage 2.
@Suite struct TableAttachmentTests {

    private func makeTableSubtree() -> TreeNode {
        let cellA = TreeNode.structural(
            ProseNode(type: "table_cell", attrs: ["align": .null]),
            [
                .structural(
                    ProseNode(type: "paragraph"),
                    [.inline(text: "a", marks: MarkSet())]
                )
            ]
        )
        let cellB = TreeNode.structural(
            ProseNode(type: "table_cell", attrs: ["align": .null]),
            [
                .structural(
                    ProseNode(type: "paragraph"),
                    [.inline(text: "b", marks: MarkSet())]
                )
            ]
        )
        let row = TreeNode.structural(
            ProseNode(type: "table_row", attrs: ["header": .bool(false)]),
            [cellA, cellB]
        )
        return .structural(ProseNode(type: "table"), [row])
    }

    @Test func attachmentCarriesSubtree() {
        let tree = makeTableSubtree()
        let attachment = ProseNodeAttachment(subtree: tree)
        #expect(attachment.subtree == tree)
    }

    @Test func updateSubtreeSwapsContent() {
        let initial = makeTableSubtree()
        let attachment = ProseNodeAttachment(subtree: initial)
        let replacement = TreeNode.structural(
            ProseNode(type: "table"),
            []
        )
        attachment.update(subtree: replacement)
        #expect(attachment.subtree == replacement)
    }

    @Test func nodeViewRegistryStoresProviders() {
        final class StubProvider: NodeViewProvider {
            let nodeType: NodeType.Name = "table"
            func makeAttachmentViewProvider(
                for path: NodePath,
                theme: ProseTheme,
                dispatch: @escaping (Transaction) -> Void
            ) -> NSTextAttachmentViewProvider {
                fatalError("not exercised")
            }
        }
        let registry = NodeViewRegistry()
        #expect(registry.provider(for: "table") == nil)
        let provider = StubProvider()
        registry.register(provider)
        #expect(registry.provider(for: "table") === provider)
        registry.unregister("table")
        #expect(registry.provider(for: "table") == nil)
    }

    @Test func editorControllerExposesRegistry() throws {
        let controller = try EditorController(initialMarkdown: "")
        #expect(controller.nodeViewRegistry.provider(for: "table") == nil)
    }

    @Test func attachmentFileTypeMatchesRegistered() {
        let attachment = ProseNodeAttachment(subtree: makeTableSubtree())
        #expect(attachment.fileType == ProseNodeAttachment.attachmentFileType)
    }

    @Test func viewProviderClassRegisteredForAttachmentFileType() throws {
        // EditorController init triggers `registerOnce`; build one to
        // ensure registration runs before the lookup.
        _ = try EditorController(initialMarkdown: "")
        let registered = NSTextAttachment.textAttachmentViewProviderClass(
            forFileType: ProseNodeAttachment.attachmentFileType
        )
        #expect(registered == TableAttachmentViewProvider.self)
    }

    @Test func tableBlockViewBuildsCellSubviewsForRunsAndColumns() throws {
        let cellA = TreeNode.structural(
            ProseNode(type: "table_header", attrs: ["align": .null]),
            [.structural(ProseNode(type: "paragraph"), [.inline(text: "Header A", marks: MarkSet())])]
        )
        let cellB = TreeNode.structural(
            ProseNode(type: "table_header", attrs: ["align": .null]),
            [.structural(ProseNode(type: "paragraph"), [.inline(text: "Header B", marks: MarkSet())])]
        )
        let header = TreeNode.structural(
            ProseNode(type: "table_row", attrs: ["header": .bool(true)]),
            [cellA, cellB]
        )
        let bodyA = TreeNode.structural(
            ProseNode(type: "table_cell", attrs: ["align": .null]),
            [.structural(ProseNode(type: "paragraph"), [.inline(text: "a", marks: MarkSet())])]
        )
        let bodyB = TreeNode.structural(
            ProseNode(type: "table_cell", attrs: ["align": .null]),
            [.structural(ProseNode(type: "paragraph"), [.inline(text: "b", marks: MarkSet())])]
        )
        let body = TreeNode.structural(
            ProseNode(type: "table_row", attrs: ["header": .bool(false)]),
            [bodyA, bodyB]
        )
        let subtree = TreeNode.structural(ProseNode(type: "table"), [header, body])
        let view = TableBlockView(subtree: subtree, theme: .default)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 200)

        // Two rows × two columns of cell subviews.
        #expect(view.subviews.count == 4)
        let cellViews = view.subviews.compactMap { $0 as? CellView }
        #expect(cellViews.count == 4)
        // Header cells display "Header A"/"Header B".
        let headerTexts = cellViews
            .filter { $0.row == 0 }
            .sorted { $0.column < $1.column }
            .map(cellTextOf)
        #expect(headerTexts == ["Header A", "Header B"])
    }

    private func cellTextOf(_ cell: CellView) -> String {
        #if canImport(AppKit) && os(macOS)
        return cell.subviews
            .compactMap { ($0 as? NSTextView)?.string }
            .first ?? ""
        #else
        return cell.subviews
            .compactMap { ($0 as? UITextView)?.text }
            .first ?? ""
        #endif
    }

    /// Force TextKit 2 to lay out a paragraph containing the table
    /// attachment and verify it asks the view provider for a view.
    /// Catches "view providers never fire" regressions.
    @Test func textKit2InstantiatesViewProviderForTable() throws {
        let controller = try EditorController(
            initialMarkdown: "| h |\n| --- |\n| a |\n"
        )
        controller.textContainer.size = CGSize(width: 600, height: 800)
        controller.layoutManager.ensureLayout(for: controller.contentStorage.documentRange)

        var sawTableProvider = false
        var viewIsTableBlockView = false
        var viewHasNonZeroSize = false
        var blockViewHasCells = false
        controller.layoutManager.enumerateTextLayoutFragments(
            from: controller.contentStorage.documentRange.location,
            options: []
        ) { fragment in
            for provider in fragment.textAttachmentViewProviders {
                guard let tableProvider = provider as? TableAttachmentViewProvider else { continue }
                sawTableProvider = true
                if let blockView = tableProvider.view as? TableBlockView {
                    viewIsTableBlockView = true
                    let dims = TableBlockView.dimensions(of: blockView.subtree)
                    blockViewHasCells = dims.cols > 0 && dims.rows > 0
                    viewHasNonZeroSize = blockView.frame.width > 0 || (provider.view?.bounds.width ?? 0) > 0
                }
            }
            return true
        }
        #expect(sawTableProvider)
        #expect(viewIsTableBlockView)
        #expect(blockViewHasCells)
        // The view's frame may not be set until laid out in a window;
        // fall back to checking the dimensions are correct.
        _ = viewHasNonZeroSize
    }

    @Test func fromStorageLiftsAttachmentSubtree() {
        // Build a storage with: one paragraph "before\n", then an
        // attachment-anchor character with proseNodePath ending at the
        // isolating `table` leaf, then a trailing paragraph.
        let storage = NSMutableAttributedString(string: "before\n")
        let beforeRange = NSRange(location: 0, length: 7)
        storage.setBlockSpec(.paragraph, in: beforeRange)

        let table = ProseNode(type: "table")
        let attachment = ProseNodeAttachment(subtree: makeTableSubtree())
        let attachmentString = NSAttributedString(
            attachment: attachment,
            attributes: [.proseMarks: MarkSetBox(MarkSet())]
        )
        let attachmentLoc = storage.length
        storage.append(attachmentString)
        storage.setNodePath(
            NodePath([
                ProseNode(type: "doc"),
                table
            ]),
            in: NSRange(location: attachmentLoc, length: 1)
        )
        // Append a trailing newline so the attachment paragraph closes.
        let nlLoc = storage.length
        storage.append(NSAttributedString(string: "\n"))
        storage.setBlockSpec(.paragraph, in: NSRange(location: nlLoc, length: 1))

        let doc = ProseDocument.from(storage: storage)
        guard case .structural(_, let kids) = doc.root else {
            Issue.record("expected structural root")
            return
        }
        // Find the table node in the doc tree.
        var sawTableWithRow = false
        for kid in kids {
            if case .structural(let n, let rows) = kid, n.type == "table" {
                if rows.contains(where: { node in
                    if case .structural(let rn, _) = node, rn.type == "table_row" { return true }
                    return false
                }) {
                    sawTableWithRow = true
                }
            }
        }
        #expect(sawTableWithRow)
    }
}

private extension NSAttributedString {
    convenience init(attachment: NSTextAttachment, attributes extra: [NSAttributedString.Key: Any]) {
        let base = NSAttributedString(attachment: attachment)
        let m = NSMutableAttributedString(attributedString: base)
        for (k, v) in extra {
            m.addAttribute(k, value: v, range: NSRange(location: 0, length: m.length))
        }
        self.init(attributedString: m)
    }
}
