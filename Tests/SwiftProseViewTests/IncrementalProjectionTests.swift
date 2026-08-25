import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

/// The spliced tree must be indistinguishable from a full re-projection —
/// same shape, same node identities, same storage spans.
@Suite(.serialized) struct IncrementalProjectionTests {

    private func edit(_ c: EditorController, replacing range: NSRange, with text: String) {
        let storage = c.textStorage
        c.testSelection = NSRange(location: range.location, length: 0)
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        c.testSelection = NSRange(location: range.location + (text as NSString).length, length: 0)
        storage.endEditing()
        c.drainPendingEnvelopes()
    }

    /// Compare a tree against a from-scratch projection of the same storage.
    private func assertMatchesFullProjection(_ c: EditorController, _ label: String) {
        let spliced = c.document
        let full = ProseDocument.from(storage: c.textStorage, schema: c.compiler.schema)
        #expect(spliced.contentLength == c.textStorage.length,
                "\(label): span \(spliced.contentLength) != storage \(c.textStorage.length)")
        // The doc root's id is deliberately *not* compared: a full
        // projection mints a fresh root every time, while the splice keeps
        // the one it already had. Everything below the root must match.
        #expect(describeChildren(spliced.root) == describeChildren(full.root),
                "\(label):\n spliced \(describeChildren(spliced.root))\n full    \(describeChildren(full.root))")
    }

    private func describeChildren(_ root: TreeNode) -> String {
        guard case .structural(let node, let kids) = root else { return describe(root) }
        return "doc:\(node.layout.storageLength ?? -1)[\(kids.map { describe($0) }.joined(separator: ","))]"
    }

    /// Type, node ids, and storage spans — everything the tree means.
    private func describe(_ node: TreeNode) -> String {
        switch node {
        case .inline(let text, let marks):
            return "t(\(text.debugDescription),\(marks))"
        case .leaf(let n, _):
            return "l(\(n.type):\(n.id.raw.uuidString.prefix(4)):\(n.layout.storageLength ?? -1))"
        case .structural(let n, let kids):
            let inner = kids.map { describe($0) }.joined(separator: ",")
            return "\(n.type):\(n.id.raw.uuidString.prefix(4)):\(n.layout.storageLength ?? -1)[\(inner)]"
        }
    }

    private static let fixture = """
    # Heading

    Intro with **bold** and `code`.

    - bullet one
    - bullet two
      - nested

    1. first
    2. second

    > quoted line

    ```swift
    let x = 1
    let y = 2
    ```

    Closing paragraph.
    """

    @Test func singleKeystrokeSplicesToTheSameTree() throws {
        let c = try EditorController(initialMarkdown: Self.fixture + "\n")
        _ = c.document                       // prime the cache
        c.projectionRunCount = 0
        c.splicedProjectionRunCount = 0

        let at = (c.textStorage.string as NSString).range(of: "bullet two").location + 3
        edit(c, replacing: NSRange(location: at, length: 0), with: "X")

        assertMatchesFullProjection(c, "single keystroke")
        #expect(c.splicedProjectionRunCount == 1, "the read was served by a splice")
        #expect(c.projectionRunCount == 0, "and did not re-project the document")
    }

    @Test func burstOfKeystrokesSplicesOnce() throws {
        let c = try EditorController(initialMarkdown: Self.fixture + "\n")
        _ = c.document
        c.projectionRunCount = 0
        c.splicedProjectionRunCount = 0

        let start = (c.textStorage.string as NSString).range(of: "Intro").location
        for i in 0..<8 {
            edit(c, replacing: NSRange(location: start + i, length: 0), with: "z")
        }
        assertMatchesFullProjection(c, "burst")
        #expect(c.splicedProjectionRunCount == 1)
        #expect(c.projectionRunCount == 0)
    }

    @Test func editsInDifferentBlocksStillSplice() throws {
        let c = try EditorController(initialMarkdown: Self.fixture + "\n")
        _ = c.document
        let ns = c.textStorage.string as NSString
        let a = ns.range(of: "Heading").location
        edit(c, replacing: NSRange(location: a, length: 0), with: "A")
        let b = (c.textStorage.string as NSString).range(of: "Closing").location
        edit(c, replacing: NSRange(location: b, length: 0), with: "B")
        assertMatchesFullProjection(c, "two distant edits")
    }

    @Test func deletionSplices() throws {
        let c = try EditorController(initialMarkdown: Self.fixture + "\n")
        _ = c.document
        let target = (c.textStorage.string as NSString).range(of: "bullet one")
        edit(c, replacing: target, with: "")
        assertMatchesFullProjection(c, "deletion")
    }

    @Test func blockSplitSplices() throws {
        let c = try EditorController(initialMarkdown: "one two three\n\ntail\n")
        _ = c.document
        edit(c, replacing: NSRange(location: 3, length: 0), with: "\n")
        assertMatchesFullProjection(c, "split")
    }

    @Test func blockJoinSplices() throws {
        let c = try EditorController(initialMarkdown: "one\n\ntwo\n\nthree\n")
        _ = c.document
        // Delete the newline between the first two paragraphs.
        edit(c, replacing: NSRange(location: 3, length: 1), with: "")
        assertMatchesFullProjection(c, "join")
    }

    @Test func editInsideACodeFenceSplices() throws {
        let c = try EditorController(initialMarkdown: Self.fixture + "\n")
        _ = c.document
        let at = (c.textStorage.string as NSString).range(of: "let y").location
        edit(c, replacing: NSRange(location: at, length: 0), with: "//")
        assertMatchesFullProjection(c, "inside fence")
    }

    @Test func transactionInvalidatesCorrectly() throws {
        let c = try EditorController(initialMarkdown: Self.fixture + "\n")
        _ = c.document
        c.testSelection = NSRange(location: 0, length: 0)
        let line = (c.textStorage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        _ = c.apply(Transaction(steps: [.setSpec(lineRange: line, BlockSpec(kind: .heading(level: 3)))]))
        assertMatchesFullProjection(c, "after a transaction")
    }

    @Test func undoInvalidatesCorrectly() throws {
        let c = try EditorController(initialMarkdown: Self.fixture + "\n")
        _ = c.document
        let at = (c.textStorage.string as NSString).range(of: "Closing").location
        edit(c, replacing: NSRange(location: at, length: 0), with: "Q")
        _ = c.document
        c.undoManager.undo()
        assertMatchesFullProjection(c, "after undo")
    }

    @Test func setMarkdownFallsBackToFullProjection() throws {
        let c = try EditorController(initialMarkdown: Self.fixture + "\n")
        _ = c.document
        c.projectionRunCount = 0
        c.splicedProjectionRunCount = 0
        c.setMarkdown("completely different\n\ncontent\n", async: false)
        assertMatchesFullProjection(c, "after setMarkdown")
        #expect(c.projectionRunCount == 1, "a whole-document load re-projects")
    }

    @Test func randomizedEditsAlwaysMatchFullProjection() throws {
        var rng = PositionSpaceTests.Seeded(seed: 0x5CE5EED)
        for iteration in 0..<60 {
            let c = try EditorController(initialMarkdown: Self.fixture + "\n")
            _ = c.document
            for step in 0..<Int.random(in: 1...6, using: &rng) {
                let len = c.textStorage.length
                guard len > 2 else { break }
                let at = Int.random(in: 0...(len - 2), using: &rng)
                switch Int.random(in: 0...3, using: &rng) {
                case 0:
                    edit(c, replacing: NSRange(location: at, length: 0), with: "q")
                case 1:
                    edit(c, replacing: NSRange(location: at, length: 1), with: "")
                case 2:
                    edit(c, replacing: NSRange(location: at, length: 0), with: "\n")
                default:
                    edit(c, replacing: NSRange(location: at, length: 0), with: "word ")
                }
                assertMatchesFullProjection(c, "seed iteration \(iteration) step \(step)")
            }
        }
    }
}
