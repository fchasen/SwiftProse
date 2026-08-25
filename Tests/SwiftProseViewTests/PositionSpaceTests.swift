import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

/// Positions in the typed tree are storage UTF-16 offsets. These pin that
/// down: markers and attachments count toward offsets, `resolve(_:)` takes
/// a raw `currentSelection.location`, and `document.contentLength` equals
/// `textStorage.length`.
@Suite(.serialized) struct PositionSpaceTests {

    // MARK: - helpers

    /// The node `resolve(p)` ultimately identifies: the child it points at
    /// when that child carries a node of its own (a leaf, or an opaque
    /// attachment-backed subtree), otherwise the deepest parent.
    static func deepestNode(_ r: ResolvedPos) -> ProseNode {
        let frame = r.frames[r.frames.count - 1]
        if frame.indexInParent < frame.children.count {
            switch frame.children[frame.indexInParent] {
            case .leaf(let n, _): return n
            case .structural(let n, _) where n.layout.isAttachmentBacked: return n
            default: break
            }
        }
        return frame.node
    }

    static func nodeIDs(in node: TreeNode, into set: inout Set<NodeID>) {
        switch node {
        case .inline: return
        case .leaf(let n, _): set.insert(n.id)
        case .structural(let n, let kids):
            set.insert(n.id)
            for k in kids { nodeIDs(in: k, into: &set) }
        }
    }

    /// Every storage offset resolves, and every offset whose owning node
    /// survived projection resolves *to that node*.
    ///
    /// Offsets whose node did not survive are the blank separator lines and
    /// the trailing paragraph after an atomic block — runs the projection
    /// drops. They belong to the block that precedes them, which is exactly
    /// what the recorded storage spans encode.
    static func checkEveryOffset(_ controller: EditorController, _ label: String) {
        let storage = controller.textStorage
        let doc = controller.document
        let total = storage.length

        #expect(doc.contentLength == total,
                "\(label): document.contentLength \(doc.contentLength) != storage.length \(total)")

        var live: Set<NodeID> = []
        nodeIDs(in: doc.root, into: &live)

        for p in 0...total {
            guard let resolved = doc.resolve(p) else {
                Issue.record("\(label): resolve(\(p)) returned nil (length \(total))")
                return
            }
            #expect(resolved.pos == p)
            guard p < total, let path = storage.nodePath(at: p), let leaf = path.leaf else { continue }
            guard live.contains(leaf.id) else { continue }
            let got = deepestNode(resolved)
            if got.id != leaf.id {
                Issue.record(
                    "\(label): resolve(\(p)) landed in \(got.type) but storage says \(leaf.type)"
                )
                return
            }
        }
    }

    // MARK: - the three brief cases

    @Test func cursorInsideThirdBulletResolvesToItsListItem() throws {
        let controller = try EditorController(initialMarkdown: "- alpha\n- beta\n- gamma\n")
        let storage = controller.textStorage
        let doc = controller.document

        // Storage offset of the "a" in "gamma".
        let target = (storage.string as NSString).range(of: "gamma").location
        #expect(target > 0)

        let resolved = try #require(doc.resolve(target))
        #expect(resolved.parent.type == "paragraph")
        #expect(resolved.textOffset == 0, "cursor sits at the start of the item body")
        #expect(resolved.node(at: resolved.depth - 1)?.type == "list_item")
        #expect(resolved.node(at: resolved.depth - 2)?.type == "bullet_list")

        // The item is the third one under the shared list.
        let listItemID = try #require(resolved.node(at: resolved.depth - 1)?.id)
        guard case .structural(_, let rootKids) = doc.root,
              case .structural(_, let items) = rootKids[0] else {
            Issue.record("expected doc → bullet_list → items")
            return
        }
        #expect(items.count == 3)
        #expect(items[2].node?.id == listItemID)
    }

    @Test func cursorInsideTwoDigitOrderedItemResolvesCorrectly() throws {
        var md = ""
        for i in 1...12 { md += "\(i). item \(i)\n" }
        let controller = try EditorController(initialMarkdown: md)
        let storage = controller.textStorage
        let doc = controller.document

        // "12. " is a four-character marker; "1. " is three. If markers
        // didn't count toward offsets every item past the ninth would skew.
        for i in [1, 9, 10, 11, 12] {
            let target = (storage.string as NSString).range(of: "item \(i)").location
            #expect(target > 0, "item \(i) not found")
            let resolved = try #require(doc.resolve(target), "resolve failed for item \(i)")
            #expect(resolved.parent.type == "paragraph")
            #expect(resolved.textOffset == 0, "item \(i) body should start at textOffset 0")
            #expect(resolved.node(at: resolved.depth - 1)?.type == "list_item")
        }

        // A position inside the marker itself clamps into the same item.
        let twelfth = (storage.string as NSString).range(of: "item 12").location
        let markerInside = try #require(doc.resolve(twelfth - 2))
        #expect(markerInside.parent.type == "paragraph")
        #expect(markerInside.textOffset == 0)
    }

    @Test func cursorInsideTaskItemResolvesToItsListItem() throws {
        let controller = try EditorController(initialMarkdown: "- [ ] write it\n- [x] ship it\n")
        let storage = controller.textStorage
        let doc = controller.document

        let target = (storage.string as NSString).range(of: "ship it").location
        let resolved = try #require(doc.resolve(target))
        #expect(resolved.parent.type == "paragraph")
        #expect(resolved.textOffset == 0)
        let item = try #require(resolved.node(at: resolved.depth - 1))
        #expect(item.type == "list_item")
        #expect(item.attrs["checked"]?.boolValue == true)
        #expect(resolved.node(at: resolved.depth - 2)?.type == "task_list")
    }

    // MARK: - offsets mid-word

    @Test func textOffsetTracksPositionWithinTheItemBody() throws {
        let controller = try EditorController(initialMarkdown: "- alpha\n- beta\n")
        let storage = controller.textStorage
        let doc = controller.document
        let betaStart = (storage.string as NSString).range(of: "beta").location
        for offset in 0..<4 {
            let resolved = try #require(doc.resolve(betaStart + offset))
            #expect(resolved.textOffset == offset,
                    "offset \(offset) into 'beta' should read back as textOffset \(offset)")
            #expect(resolved.index(at: resolved.depth) == 0)
        }
        // PM contract: at the end of the last child the index advances past
        // it and `textOffset` restarts at 0.
        let atEnd = try #require(doc.resolve(betaStart + 4))
        #expect(atEnd.parent.type == "paragraph")
        #expect(atEnd.index(at: atEnd.depth) == 1)
        #expect(atEnd.textOffset == 0)
    }

    @Test func markerOffsetsBelongToTheirParagraph() throws {
        let controller = try EditorController(initialMarkdown: "- alpha\n- beta\n")
        let storage = controller.textStorage
        let doc = controller.document
        // Everything before the "b" of "beta" on that line is marker.
        let betaStart = (storage.string as NSString).range(of: "beta").location
        let lineStart = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: betaStart, length: 0)).location
        #expect(lineStart < betaStart, "expected a presentation marker before the body")
        let paragraph = try #require(doc.resolve(betaStart)).parent
        for p in lineStart..<betaStart {
            let resolved = try #require(doc.resolve(p))
            #expect(resolved.parent.id == paragraph.id,
                    "marker offset \(p) should resolve into the item's paragraph")
            #expect(resolved.textOffset == 0)
        }
        #expect(paragraph.layout.presentationPrefix == betaStart - lineStart)
    }

    // MARK: - fixture property

    static let fixture = """
    # Heading

    Intro paragraph with **bold**, *em*, `code`, and [a link](https://example.com).

    - bullet one
    - bullet two
      - nested bullet
    - bullet three

    1. first
    2. second
    3. third

    - [ ] open task
    - [x] done task

    > quoted line
    > second quoted line

    ```swift
    let x = 1
    let y = 2
    ```

    ---

    | a | b |
    | --- | --- |
    | 1 | 2 |

    Closing paragraph.

    ```
    trailing atomic block
    ```
    """

    @Test func everyOffsetInTheFixtureResolvesToItsStorageNode() throws {
        let controller = try EditorController(initialMarkdown: Self.fixture + "\n")
        Self.checkEveryOffset(controller, "fixture")
    }

    @Test func attachmentBackedTableIsOpaque() throws {
        let controller = try EditorController(
            initialMarkdown: "before\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter\n"
        )
        let storage = controller.textStorage
        let doc = controller.document
        var tableOffset: Int?
        storage.enumerateNodePaths { range, path in
            if tableOffset == nil, path.leaf?.type == "table" { tableOffset = range.location }
        }
        let offset = try #require(tableOffset)
        let resolved = try #require(doc.resolve(offset))
        let node = Self.deepestNode(resolved)
        #expect(node.type == "table")
        #expect(node.layout.isAttachmentBacked)
        // resolve stopped at the table; it did not walk into the cells.
        #expect(resolved.parent.type != "table_cell")
        #expect(resolved.parent.type != "table_row")
    }

    // MARK: - randomized

    /// SplitMix64 — seeded so a failure reproduces exactly.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomDocument(_ rng: inout Seeded) -> String {
        var blocks: [String] = []
        let count = Int.random(in: 1...8, using: &rng)
        for i in 0..<count {
            switch Int.random(in: 0...8, using: &rng) {
            case 0:
                blocks.append("# heading \(i)")
            case 1:
                blocks.append("para \(i) with **bold** and `code` inside")
            case 2:
                var items: [String] = []
                for j in 0..<Int.random(in: 1...4, using: &rng) {
                    items.append("- item \(i).\(j)")
                }
                blocks.append(items.joined(separator: "\n"))
            case 3:
                var items: [String] = []
                for j in 1...Int.random(in: 1...12, using: &rng) {
                    items.append("\(j). ordered \(i).\(j)")
                }
                blocks.append(items.joined(separator: "\n"))
            case 4:
                var items: [String] = []
                for j in 0..<Int.random(in: 1...3, using: &rng) {
                    items.append("- [\(j % 2 == 0 ? "x" : " ")] task \(i).\(j)")
                }
                blocks.append(items.joined(separator: "\n"))
            case 5:
                blocks.append("- outer \(i)\n  - inner \(i)\n    - deepest \(i)")
            case 6:
                blocks.append("> quote \(i)\n> continued \(i)")
            case 7:
                blocks.append("```swift\nlet v\(i) = \(i)\n```")
            default:
                blocks.append("---")
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    @Test func randomizedDocumentsKeepOffsetsAligned() throws {
        var rng = Seeded(seed: 0xC0FFEE)
        for iteration in 0..<200 {
            let md = Self.randomDocument(&rng)
            let controller = try EditorController(initialMarkdown: md)
            Self.checkEveryOffset(controller, "seed 0xC0FFEE #\(iteration)")
        }
    }
}
