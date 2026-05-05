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
