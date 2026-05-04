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
/// `MarkdownTreeSerializer`. The legacy `proseBlockSpec`-walking emit
/// path was retired in Phase 10 cleanup; storage that lacks tree
/// attributes goes through `NodePathSynthesizer.stamp` first to derive
/// them from `proseBlockSpec` (or sensible defaults).
public final class AttributedMarkdownSerializer {
    public let schema: Schema

    public init(schema: Schema = .defaultMarkdown) {
        self.schema = schema
    }

    public func serialize(_ attributed: NSAttributedString) -> String {
        serializeFromTree(attributed)
    }

    /// Tree-driven emit path. Re-derives `proseNodePath` from
    /// `proseBlockSpec` if missing so post-mutation storage that only
    /// carries the legacy attribute (e.g. `setAttributes(plainAttrs, …)`
    /// paths in EditorController) still serializes correctly.
    public func serializeFromTree(_ attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        NodePathSynthesizer(schema: schema).stamp(into: mutable)
        let tree = ProseDocument.from(storage: mutable, schema: schema)
        return MarkdownTreeSerializer(schema: schema).serialize(tree)
    }
}
