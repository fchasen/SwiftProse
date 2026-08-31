import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Serializes a styled `NSAttributedString` back to markdown by walking
/// the tree projection (`proseNodePath` + `proseMarks`) and emitting via
/// `MarkdownTreeSerializer`. A marks-only refresh keeps `proseMarks` in
/// sync with rendering attributes for storage mutated outside the Step API.
public final class AttributedMarkdownSerializer {
    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    public func serialize(_ attributed: NSAttributedString) -> String {
        serializeFromTree(attributed)
    }

    public func serializeFromTree(_ attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        return MarkdownTreeSerializer(schema: schema).serialize(project(attributed))
    }

    /// Serialize a single storage line, dropping the list levels the line
    /// does not own.
    ///
    /// A fragment cut from inside a nested list projects with the enclosing
    /// levels reopened above it — `  - two` comes back as
    /// `bullet_list > list_item > bullet_list > list_item`, and the outer
    /// item, having no paragraph of its own, emits a bare `-` line that
    /// belongs to the line above the fragment. What survives is this line's
    /// own markup, which is what a caller recovering the body wants.
    public func serializeLine(_ attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        let pruned = Self.pruningReopenedLists(project(attributed).root)
        return MarkdownTreeSerializer(schema: schema)
            .serialize(ProseDocument(schema: schema, root: pruned))
    }

    /// Splice out every list whose only item leads with something other
    /// than a paragraph: that item's marker is emitted on a line of its
    /// own, which in a one-line fragment is never this line.
    private static func pruningReopenedLists(_ node: TreeNode) -> TreeNode {
        guard case .structural(let n, let kids) = node else { return node }
        if n.type == "bullet_list" || n.type == "ordered_list",
           kids.count == 1,
           case .structural(let item, let itemKids) = kids[0],
           item.type == "list_item",
           let first = itemKids.first,
           !isParagraph(first) {
            return pruningReopenedLists(first)
        }
        return .structural(n, kids.map(pruningReopenedLists))
    }

    private static func isParagraph(_ node: TreeNode) -> Bool {
        if case .structural(let n, _) = node { return n.type == "paragraph" }
        return false
    }

    private func project(_ attributed: NSAttributedString) -> ProseDocument {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        NodePathSynthesizer(schema: schema).stampMarks(
            in: mutable,
            range: NSRange(location: 0, length: mutable.length)
        )
        return ProseDocument.from(storage: mutable, schema: schema)
    }
}
