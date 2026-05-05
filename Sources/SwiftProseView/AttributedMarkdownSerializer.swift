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
/// `MarkdownTreeSerializer`. With Phase 10 retiring `BlockSpec` storage,
/// `proseNodePath` is the canonical structural attribute — the compiler
/// stamps it during emit and writers go through `setBlockSpec` (which now
/// stamps `NodePath` under the hood). A marks-only refresh keeps the
/// canonical mark store in sync with rendering attributes for
/// post-mutation storage that didn't push marks through the Step API.
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
        let mutable = NSMutableAttributedString(attributedString: attributed)
        NodePathSynthesizer(schema: schema).stampMarks(
            in: mutable,
            range: NSRange(location: 0, length: mutable.length)
        )
        let tree = ProseDocument.from(storage: mutable, schema: schema)
        return MarkdownTreeSerializer(schema: schema).serialize(tree)
    }
}
