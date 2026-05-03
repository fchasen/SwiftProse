import Foundation

public extension NSAttributedString.Key {
    static let marginaliaBlockSpec = NSAttributedString.Key("marginalia.blockSpec")
}

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
        case pipeTable
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
            self.init(kind: .pipeTable, blockquoteDepth: depth)
        }
    }
}

/// Reference-typed wrapper for storing `BlockSpec` in `NSAttributedString`.
///
/// Why: `enumerateAttribute(.marginaliaBlockSpec, in:)` walks runs by
/// `isEqual:`. We deliberately keep NSObject's default reference equality
/// here so each compiler emit produces a distinct run — two consecutive
/// list items with value-equal specs stay separate and the serializer can
/// emit a marker for each. Use `BlockSpec` value equality for diagnostics
/// and tests; never compare boxes directly.
public final class BlockSpecBox: NSObject, @unchecked Sendable {
    public let spec: BlockSpec

    public init(_ spec: BlockSpec) {
        self.spec = spec
        super.init()
    }
}

public extension NSAttributedString {
    func blockSpec(at index: Int) -> BlockSpec? {
        guard index >= 0, index < length else { return nil }
        let raw = attribute(.marginaliaBlockSpec, at: index, effectiveRange: nil)
        return (raw as? BlockSpecBox)?.spec
    }

    func enumerateBlockSpecs(
        in range: NSRange? = nil,
        _ body: (NSRange, BlockSpec) -> Void
    ) {
        let scan = range ?? NSRange(location: 0, length: length)
        guard scan.length > 0 else { return }
        enumerateAttribute(.marginaliaBlockSpec, in: scan) { value, subRange, _ in
            if let box = value as? BlockSpecBox {
                body(subRange, box.spec)
            }
        }
    }
}

public extension NSMutableAttributedString {
    func setBlockSpec(_ spec: BlockSpec, in range: NSRange) {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= length else { return }
        addAttribute(.marginaliaBlockSpec, value: BlockSpecBox(spec), range: range)
    }
}

public extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    var marginaliaBlockSpec: BlockSpec? {
        get { (self[.marginaliaBlockSpec] as? BlockSpecBox)?.spec }
        set {
            if let v = newValue {
                self[.marginaliaBlockSpec] = BlockSpecBox(v)
            } else {
                self[.marginaliaBlockSpec] = nil
            }
        }
    }
}
