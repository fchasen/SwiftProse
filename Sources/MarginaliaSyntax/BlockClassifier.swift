import Foundation
import SwiftTreeSitter

/// What kind of block lives at a given range — used by the layout manager to
/// pick an `NSTextLayoutFragment` subclass per paragraph.
public enum BlockKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
    case setextHeading(level: Int)
    case fencedCode(language: String?)
    case indentedCode
    case blockquote(depth: Int)
    case orderedList
    case unorderedList
    case taskList
    case horizontalRule
    case htmlBlock
    case linkReferenceDefinition
    case pipeTable
}

public struct BlockRegion: Equatable, Sendable {
    /// UTF-16 (NSRange) offsets — ready to use against `NSTextStorage`.
    public let range: NSRange
    public let kind: BlockKind

    public init(range: NSRange, kind: BlockKind) {
        self.range = range
        self.kind = kind
    }
}

/// Walks a tree-sitter-markdown block tree and emits one `BlockRegion` per
/// recognized top-level block, with byte ranges translated to UTF-16.
public enum BlockClassifier {
    public static func classify(rootNode: Node, mapping: TreeSitterMapping) -> [BlockRegion] {
        var out: [BlockRegion] = []
        walk(rootNode, depth: 0, mapping: mapping, into: &out)
        return out
    }

    private static func walk(
        _ node: Node,
        depth: Int,
        mapping: TreeSitterMapping,
        into out: inout [BlockRegion]
    ) {
        let type = node.nodeType ?? ""

        if let kind = blockKind(for: node, type: type, mapping: mapping, blockquoteDepth: depth) {
            let byte = node.byteRange
            let range = NSRange(
                location: mapping.utf16Offset(forByte: byte.lowerBound),
                length: mapping.utf16Offset(forByte: byte.upperBound)
                    - mapping.utf16Offset(forByte: byte.lowerBound)
            )
            out.append(BlockRegion(range: range, kind: kind))

            // Recurse into block_quote so nested children (deeper quotes,
            // headings inside quotes, etc.) still get classified.
            if case .blockquote = kind {
                for i in 0..<node.childCount {
                    if let child = node.child(at: i) {
                        walk(child, depth: depth + 1, mapping: mapping, into: &out)
                    }
                }
            }
            return
        }

        // Non-block container — recurse into children to find blocks below
        for i in 0..<node.childCount {
            if let child = node.child(at: i) {
                walk(child, depth: depth, mapping: mapping, into: &out)
            }
        }
    }

    private static func blockKind(for node: Node, type: String, mapping: TreeSitterMapping, blockquoteDepth: Int) -> BlockKind? {
        switch type {
        case "atx_heading":
            return .heading(level: atxLevel(of: node))
        case "setext_heading":
            return .setextHeading(level: setextLevel(of: node))
        case "fenced_code_block":
            return .fencedCode(language: fencedLanguage(of: node, mapping: mapping))
        case "indented_code_block":
            return .indentedCode
        case "block_quote":
            return .blockquote(depth: blockquoteDepth + 1)
        case "list":
            return listKind(of: node)
        case "thematic_break":
            return .horizontalRule
        case "paragraph":
            return .paragraph
        case "html_block":
            return .htmlBlock
        case "link_reference_definition":
            return .linkReferenceDefinition
        case "pipe_table":
            return .pipeTable
        default:
            return nil
        }
    }

    private static func atxLevel(of node: Node) -> Int {
        for i in 0..<node.childCount {
            guard let c = node.child(at: i), let t = c.nodeType else { continue }
            if t.hasPrefix("atx_h"), t.hasSuffix("_marker") {
                let mid = t.dropFirst("atx_h".count).dropLast("_marker".count)
                if let level = Int(mid) {
                    return level
                }
            }
        }
        return 1
    }

    private static func setextLevel(of node: Node) -> Int {
        for i in 0..<node.childCount {
            guard let c = node.child(at: i), let t = c.nodeType else { continue }
            if t == "setext_h1_underline" { return 1 }
            if t == "setext_h2_underline" { return 2 }
        }
        return 1
    }

    private static func fencedLanguage(of node: Node, mapping: TreeSitterMapping) -> String? {
        for i in 0..<node.childCount {
            guard let c = node.child(at: i), c.nodeType == "info_string" else { continue }
            for j in 0..<c.childCount {
                guard let lang = c.child(at: j), lang.nodeType == "language" else { continue }
                let byte = lang.byteRange
                let lo = mapping.utf16Offset(forByte: byte.lowerBound)
                let hi = mapping.utf16Offset(forByte: byte.upperBound)
                let ns = mapping.text as NSString
                let s = ns.substring(with: NSRange(location: lo, length: hi - lo))
                return s.isEmpty ? nil : s
            }
        }
        return nil
    }

    private static func listKind(of node: Node) -> BlockKind {
        var sawTaskMarker = false
        var sawOrderedMarker = false
        for i in 0..<node.childCount {
            guard let item = node.child(at: i), item.nodeType == "list_item" else { continue }
            for j in 0..<item.childCount {
                guard let inner = item.child(at: j), let it = inner.nodeType else { continue }
                if it.hasPrefix("task_list_marker_") { sawTaskMarker = true }
                if it == "list_marker_dot" || it == "list_marker_parenthesis" { sawOrderedMarker = true }
            }
        }
        if sawTaskMarker { return .taskList }
        if sawOrderedMarker { return .orderedList }
        return .unorderedList
    }
}
