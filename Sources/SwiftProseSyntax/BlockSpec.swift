import Foundation

/// A flat, value-typed view over a single block line's structural
/// classification. `BlockSpec` no longer has its own attribute key on the
/// storage — it's derived from `proseNodePath` at read time and converted
/// to a `NodePath` at write time. The struct survives as a convenient
/// switch-case shape used by commands, input rules, and the compiler;
/// callers that need the full hierarchy work with `NodePath` directly.
public struct BlockSpec: Equatable, Hashable, Sendable {
    public let kind: Kind
    public let blockquoteDepth: Int
    public let listLevel: Int

    public enum Kind: Equatable, Hashable, Sendable {
        case paragraph
        case heading(level: Int)
        case unorderedListItem
        case orderedListItem(index: Int)
        case taskListItem(checked: Bool)
        case fencedCode(language: String?)
        case indentedCode
        case horizontalRule
        case htmlBlock
        case linkReferenceDefinition
    }

    public init(kind: Kind, blockquoteDepth: Int = 0, listLevel: Int = 0) {
        self.kind = kind
        self.blockquoteDepth = max(0, blockquoteDepth)
        self.listLevel = max(0, listLevel)
    }

    public static let paragraph = BlockSpec(kind: .paragraph)

    public var isListItem: Bool {
        switch kind {
        case .unorderedListItem, .orderedListItem, .taskListItem: return true
        default: return false
        }
    }

    public var isCodeBlock: Bool {
        switch kind {
        case .fencedCode, .indentedCode: return true
        default: return false
        }
    }
}

public extension BlockSpec {
    init(blockSegment: BlockSegment) {
        let depth = blockSegment.blockquoteDepth
        switch blockSegment.tag {
        case .paragraph:
            self.init(kind: .paragraph, blockquoteDepth: depth)
        case .heading:
            self.init(kind: .heading(level: blockSegment.level), blockquoteDepth: depth)
        case .unorderedListItem:
            self.init(kind: .unorderedListItem, blockquoteDepth: depth, listLevel: blockSegment.listLevel)
        case .orderedListItem:
            self.init(
                kind: .orderedListItem(index: blockSegment.orderedIndex ?? 1),
                blockquoteDepth: depth,
                listLevel: blockSegment.listLevel
            )
        case .taskListItem:
            self.init(
                kind: .taskListItem(checked: blockSegment.isChecked ?? false),
                blockquoteDepth: depth,
                listLevel: blockSegment.listLevel
            )
        case .fencedCode:
            self.init(kind: .fencedCode(language: blockSegment.language), blockquoteDepth: depth)
        case .indentedCode:
            self.init(kind: .indentedCode, blockquoteDepth: depth)
        case .horizontalRule:
            self.init(kind: .horizontalRule)
        case .htmlBlock:
            self.init(kind: .htmlBlock, blockquoteDepth: depth)
        case .linkReferenceDefinition:
            self.init(kind: .linkReferenceDefinition, blockquoteDepth: depth)
        case .pipeTable:
            // Pipe tables are emitted as plain paragraphs by the compiler
            // (no more rendered cell chrome); the legacy BlockTag is kept
            // for compiler dispatch but the BlockSpec carries paragraph.
            self.init(kind: .paragraph, blockquoteDepth: depth)
        }
    }
}

public extension NSAttributedString {
    /// Derive a `BlockSpec` view from the `proseNodePath` attribute at the
    /// given index. Returns nil when the location lacks a node path or when
    /// the leaf type isn't a known block kind.
    func blockSpec(at index: Int) -> BlockSpec? {
        guard let path = nodePath(at: index) else { return nil }
        return BlockSpec.fromNodePath(path)
    }

    /// Walk every `proseNodePath` run, deriving a `BlockSpec` per run and
    /// invoking `body`. Runs whose path can't be mapped to a known block
    /// kind are skipped silently.
    func enumerateBlockSpecs(
        in range: NSRange? = nil,
        _ body: (NSRange, BlockSpec) -> Void
    ) {
        enumerateNodePaths(in: range) { runRange, path in
            guard let spec = BlockSpec.fromNodePath(path) else { return }
            body(runRange, spec)
        }
    }
}

public extension NSMutableAttributedString {
    /// Stamp the `proseNodePath` attribute over `range` with a freshly-
    /// derived path for `spec`. When the immediately-preceding character
    /// already carries a node path, list and blockquote ancestors at
    /// matching depths/kinds are reused so consecutive list-item lines
    /// share the same wrapping list node — preserving tree grouping for
    /// markdown / ProseMirror round-trips.
    func setBlockSpec(_ spec: BlockSpec, in range: NSRange) {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= length else { return }
        let predecessor: NodePath? = range.location > 0
            ? nodePath(at: range.location - 1)
            : nil
        let path = NodePath.fromBlockSpec(spec, predecessor: predecessor)
        setNodePath(path, in: range)
    }
}
