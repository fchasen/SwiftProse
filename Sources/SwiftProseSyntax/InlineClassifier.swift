import Foundation
import SwiftTreeSitter

public enum InlineKind: Equatable, Sendable {
    case inlineLink(destination: String, label: String)
    case image(destination: String, alt: String)
}

public struct InlineRegion: Equatable, Sendable {
    public let range: NSRange
    public let kind: InlineKind

    public init(range: NSRange, kind: InlineKind) {
        self.range = range
        self.kind = kind
    }
}

/// Walks a tree-sitter-markdown-inline tree and emits one `InlineRegion` per
/// inline link / image node, with byte ranges translated to UTF-16.
public enum InlineClassifier {
    public static func classify(rootNode: Node, mapping: TreeSitterMapping) -> [InlineRegion] {
        var out: [InlineRegion] = []
        walk(rootNode, mapping: mapping, into: &out)
        return out
    }

    private static func walk(_ node: Node, mapping: TreeSitterMapping, into out: inout [InlineRegion]) {
        let type = node.nodeType ?? ""
        switch type {
        case "inline_link":
            if let region = inlineLinkRegion(of: node, mapping: mapping) {
                out.append(region)
            }
        case "image":
            if let region = imageRegion(of: node, mapping: mapping) {
                out.append(region)
            }
        default:
            for i in 0..<node.childCount {
                if let child = node.child(at: i) {
                    walk(child, mapping: mapping, into: &out)
                }
            }
        }
    }

    private static func inlineLinkRegion(of node: Node, mapping: TreeSitterMapping) -> InlineRegion? {
        let range = nsRange(of: node, mapping: mapping)
        let label = childText(in: node, types: ["link_text"], mapping: mapping) ?? ""
        let destination = childText(in: node, types: ["link_destination"], mapping: mapping) ?? ""
        return InlineRegion(range: range, kind: .inlineLink(destination: destination, label: label))
    }

    private static func imageRegion(of node: Node, mapping: TreeSitterMapping) -> InlineRegion? {
        let range = nsRange(of: node, mapping: mapping)
        let alt = childText(in: node, types: ["image_description"], mapping: mapping) ?? ""
        let destination = childText(in: node, types: ["link_destination"], mapping: mapping) ?? ""
        return InlineRegion(range: range, kind: .image(destination: destination, alt: alt))
    }

    private static func nsRange(of node: Node, mapping: TreeSitterMapping) -> NSRange {
        let byte = node.byteRange
        let lo = mapping.utf16Offset(forByte: byte.lowerBound)
        let hi = mapping.utf16Offset(forByte: byte.upperBound)
        return NSRange(location: lo, length: hi - lo)
    }

    private static func childText(in node: Node, types: Set<String>, mapping: TreeSitterMapping) -> String? {
        for i in 0..<node.childCount {
            guard let child = node.child(at: i), let t = child.nodeType else { continue }
            if types.contains(t) {
                let byte = child.byteRange
                let lo = mapping.utf16Offset(forByte: byte.lowerBound)
                let hi = mapping.utf16Offset(forByte: byte.upperBound)
                let ns = mapping.text as NSString
                return ns.substring(with: NSRange(location: lo, length: hi - lo))
            }
        }
        return nil
    }
}
