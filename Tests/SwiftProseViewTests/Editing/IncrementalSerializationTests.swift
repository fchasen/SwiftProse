import Testing
import Foundation
@testable import SwiftProseSyntax
@_spi(Harness) @testable import SwiftProseView
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum SerializationFixtures {
    static let markdown: [(String, String)] = [
        ("bullet chain", "- a\n\n* b\n\n- c\n\n* d\n\npara"),
        ("ordered chain", "1. a\n\n1) b\n\n3. c\n\n5) d"),
        ("ordered starts", "3. a\n4. b\n\npara\n\n7. c\n8. d"),
        ("indented code after a list", "- a\n\npara\n\n    code\n    more\n\nafter\n\n- b\n\n<!-- x -->\n\n    tail"),
        ("mid table", "para\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |\n\nafter"),
        ("quotes with blanks", "> a\n>\n> b\n\n> c\n\npara\n\n> d\n>\n> - e"),
        ("empty items", "- \n- a\n- \n\npara\n\n- x\n- "),
        ("blocks", "# h\n\n---\n\n```swift\nlet a = 1\n```\n\n***\n\n- a\n\n![i](u.png)"),
        ("nested", "- a\n  - b\n    > q\n\n  c\n- d\n\n1. e\n   ```\n   f\n   ```"),
        ("empty", ""),
    ]

    static func loaded() -> [(String, NSAttributedString)] {
        markdown.map { ($0.0, MarkdownLoader().load($0.1)) }
    }

    static func marked(_ byte: Character) -> NSTextList {
        let list = MarkdownTextList(markerFormat: .disc, options: 0)
        list.sourceMarker = byte.asciiValue
        return list
    }

    static func nilMarkerMerge() -> NSAttributedString {
        let dash = marked("-")
        let unmarked = MarkdownTextList(markerFormat: .disc, options: 0)
        let star = marked("*")
        return WF.storage([
            WF.item("a", [dash]),
            WF.item("a2", [dash]),
            WF.p("between"),
            WF.item("b", [unmarked]),
            WF.item("c", [star]),
            WF.item("d", [star]),
            WF.p("after"),
        ])
    }

    static func blankEdges() -> NSAttributedString {
        WF.storage([
            WF.p(""),
            WF.p(""),
            WF.p("a"),
            WF.p(""),
            WF.item("", [WF.bullet()]),
            WF.p(""),
        ], trailingNewline: true)
    }

    static func all() -> [(String, NSAttributedString)] {
        loaded() + [("nil marker merge", nilMarkerMerge()), ("blank edges", blankEdges())]
    }
}

@Suite("Incremental serialization")
@MainActor
struct IncrementalSerializationTests {
    enum Edit {
        case replace(NSRange, String)
        case attributes(NSRange)
    }

    static func apply(_ edit: Edit, to storage: NSTextStorage, serializer: IncrementalSerializer) {
        switch edit {
        case .replace(let range, let text):
            let attributes = storage.length == 0 ? [:] : storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
            serializer.recordEdit(NSRange(location: range.location, length: (text as NSString).length), changeInLength: (text as NSString).length - range.length)
        case .attributes(let range):
            storage.addAttribute(.foregroundColor, value: PlatformColor.red, range: range)
            serializer.recordEdit(range, changeInLength: 0)
        }
    }

    static func edits(for storage: NSAttributedString) -> [Edit] {
        let paragraphs = storage.markdownParagraphRanges()
        var edits: [Edit] = [.replace(NSRange(location: 0, length: 0), "x"), .replace(NSRange(location: storage.length, length: 0), "\ntail")]
        for (index, paragraph) in paragraphs.enumerated() {
            edits.append(.replace(NSRange(location: paragraph.location, length: 0), "x"))
            edits.append(.replace(NSRange(location: paragraph.location, length: 0), "\n"))
            if paragraph.length > 0 {
                edits.append(.replace(paragraph, ""))
                edits.append(.replace(NSRange(location: NSMaxRange(paragraph) - 1, length: 1), ""))
                edits.append(.replace(NSRange(location: paragraph.location, length: paragraph.length - 1), ""))
                edits.append(.attributes(paragraph))
            }
            if index + 1 < paragraphs.count {
                edits.append(.replace(NSUnionRange(paragraph, paragraphs[index + 1]), ""))
                let middle = NSRange(location: paragraph.location + paragraph.length / 2, length: 0)
                let next = paragraphs[index + 1]
                edits.append(.replace(NSRange(location: middle.location, length: next.location + next.length / 2 - middle.location), ""))
            }
        }
        return edits
    }

    static func expectSpliced(_ serializer: IncrementalSerializer, _ storage: NSTextStorage, _ label: String) {
        let spliced = serializer.markdown(from: storage)
        let full = MarkdownWriter().markdown(from: storage)
        #expect(spliced == full, "\(label)")
    }

    @Test func everyFixtureEditSplicesToTheFullOutput() {
        var splices = 0
        var fallbacks = 0
        for (name, fixture) in SerializationFixtures.all() {
            for (index, edit) in Self.edits(for: fixture).enumerated() {
                let storage = NSTextStorage(attributedString: fixture)
                let serializer = IncrementalSerializer()
                serializer.rebuild(storage)
                Self.apply(edit, to: storage, serializer: serializer)
                Self.expectSpliced(serializer, storage, "\(name) edit \(index) \(edit)")
                splices += serializer.stats.splices
                fallbacks += serializer.stats.fallbacks
            }
        }
        #expect(splices > 500)
        #expect(fallbacks == 0)
    }

    @Test func accumulatedEditsSpliceToTheFullOutput() {
        var generator = SeededGenerator(seed: 7)
        var reasons: [String] = []
        var splices = 0
        var fallbacks = 0
        for (name, fixture) in SerializationFixtures.all() {
            let storage = NSTextStorage(attributedString: fixture)
            let serializer = IncrementalSerializer()
            serializer.rebuild(storage)
            for step in 0..<120 {
                let candidates = Self.edits(for: storage)
                Self.apply(candidates.randomElement(using: &generator)!, to: storage, serializer: serializer)
                if Int.random(in: 0..<3, using: &generator) == 0 {
                    Self.expectSpliced(serializer, storage, "\(name) step \(step)")
                }
            }
            Self.expectSpliced(serializer, storage, "\(name) final")
            splices += serializer.stats.splices
            fallbacks += serializer.stats.fallbacks
            if let reason = serializer.lastFallback { reasons.append("\(name): \(reason)") }
        }
        #expect(splices > 200)
        #expect(fallbacks == 0, "\(reasons)")
    }

    @Test func nilMarkerMergeMovesABoundaryInsideTheNextUnit() {
        let storage = NSTextStorage(attributedString: SerializationFixtures.nilMarkerMerge())
        let serializer = IncrementalSerializer()
        #expect(serializer.rebuild(storage) == "- a\n- a2\n\nbetween\n\n- b\n- c\n- d\n\nafter")
        let between = storage.markdownParagraphRanges()[2]
        storage.replaceCharacters(in: between, with: "")
        serializer.recordEdit(NSRange(location: between.location, length: 0), changeInLength: -between.length)
        #expect(serializer.markdown(from: storage) == MarkdownWriter().markdown(from: storage))
        #expect(serializer.markdown(from: storage) == "- a\n- a2\n- b\n\n* c\n* d\n\nafter")
        #expect(serializer.stats.splices == 1)
    }

    @Test func alternateMarkersPropagateAlongTheChain() {
        let storage = NSTextStorage(attributedString: MarkdownLoader().load("para\n\n- a\n\n* b\n\n- c\n\n* d\n\n- e"))
        let serializer = IncrementalSerializer()
        serializer.rebuild(storage)
        let first = storage.markdownParagraphRanges()[0]
        storage.replaceCharacters(in: first, with: NSAttributedString(string: "- z\n", attributes: storage.attributes(at: first.location + 2, effectiveRange: nil).merging([.paragraphStyle: { () -> NSParagraphStyle in
            let style = NSMutableParagraphStyle()
            style.textLists = [SerializationFixtures.marked("*")]
            return style
        }()]) { $1 }))
        serializer.recordEdit(NSRange(location: 0, length: 4), changeInLength: 4 - first.length)
        #expect(serializer.markdown(from: storage) == MarkdownWriter().markdown(from: storage))
        #expect(serializer.stats.unitsWritten > serializer.stats.unitsRead - 5)
    }

    @Test func mixedFixtureRandomEditsStayLocal() {
        let fixture = MarkdownLoader().load(BenchmarkFixtures.mixedDocument())
        let storage = NSTextStorage(attributedString: fixture)
        let serializer = IncrementalSerializer()
        serializer.rebuild(storage)
        var generator = SeededGenerator(seed: 42)
        let readBefore = serializer.stats.unitsRead
        for step in 0..<200 {
            let paragraphs = storage.markdownParagraphRanges()
            let paragraph = paragraphs.randomElement(using: &generator)!
            let edit: Edit
            switch Int.random(in: 0..<4, using: &generator) {
            case 0: edit = .replace(NSRange(location: paragraph.location, length: 0), "x")
            case 1 where paragraph.length > 1: edit = .replace(NSRange(location: paragraph.location, length: 1), "")
            case 2 where paragraph.length > 0: edit = .replace(NSRange(location: NSMaxRange(paragraph) - 1, length: 1), "")
            default: edit = .replace(NSRange(location: paragraph.location, length: 0), "\n")
            }
            Self.apply(edit, to: storage, serializer: serializer)
            Self.expectSpliced(serializer, storage, "step \(step)")
        }
        #expect(serializer.stats.splices == 200)
        #expect(serializer.stats.fallbacks == 0, "\(serializer.lastFallback ?? "")")
        #expect(serializer.stats.unitsRead - readBefore < 200 * 20)
    }

    @Test func emptyDocumentTakesTypedText() {
        let editor = HeadlessEditor(markdown: "")
        editor.type("hello")
        #expect(editor.controller.serialize() == "hello")
        editor.select(0)
        editor.type("- ")
        editor.settle()
        #expect(editor.controller.serialize() == MarkdownWriter().markdown(from: editor.controller.textStorage))
    }

    @Test func withoutBindingPassesAreRecorded() {
        let editor = HeadlessEditor(markdown: "- a\n\n* b\n\npara")
        let controller = editor.controller
        _ = controller.serialize()
        controller.withoutBinding {
            controller.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(string: "z", attributes: controller.textStorage.attributes(at: 0, effectiveRange: nil)))
        }
        #expect(controller.serialize() == MarkdownWriter().markdown(from: controller.textStorage))
        controller.writingToolsWillBegin()
        controller.writingToolsDidEnd()
        #expect(controller.serialize() == MarkdownWriter().markdown(from: controller.textStorage))
        #expect(controller.harnessSerializationDrift() == nil)
        #expect(controller.serializationStats.fallbacks == 0)
    }

    @Test func uneditedDocumentReturnsTheLoadBytes() {
        let source = "*  a\n*  b\n\nSome   text\n"
        let editor = HeadlessEditor(markdown: source)
        let controller = editor.controller
        let rebuilds = controller.serializationStats.rebuilds
        #expect(controller.markdown() == source)
        #expect(controller.serializationStats.rebuilds == rebuilds)
        #expect(controller.serializationStats.splices == 0)
        controller.setMarkdown(source + "more\n")
        #expect(controller.markdown() == source + "more\n")
    }

    @Test func undoBackToTheLoadedStateReturnsTheLoadBytes() {
        let source = "*  a\n*  b\n\nSome   text\n"
        let editor = HeadlessEditor(markdown: source)
        let controller = editor.controller
        editor.select(2)
        #expect(controller.insertMarkdown("x"))
        editor.settle()
        #expect(controller.markdown() != source)
        #expect(controller.serializationStats.splices >= 1)
        controller.undoManager.undo()
        editor.settle()
        #expect(controller.markdown() == source)
        controller.undoManager.redo()
        editor.settle()
        #expect(controller.markdown() == MarkdownWriter().markdown(from: controller.textStorage))
    }

    @Test func loadRestoreRebuildsTheCache() {
        let editor = HeadlessEditor(markdown: "one\n\n- a")
        let controller = editor.controller
        controller.loadRecordingUndo("two\n\n* b", actionName: "Switch")
        #expect(controller.markdown() == "two\n\n* b")
        controller.undoManager.undo()
        #expect(controller.markdown() == "one\n\n- a")
        #expect(controller.harnessSerializationDrift() == nil)
        controller.undoManager.redo()
        #expect(controller.markdown() == "two\n\n* b")
        #expect(controller.harnessSerializationDrift() == nil)
    }
}

#if canImport(AppKit) && os(macOS)
@Suite("Incremental serialization, hosted", .serialized)
@MainActor
struct HostedIncrementalSerializationTests {
    static let document = """
    # Title

    Intro paragraph with **bold** and `code`.

    - one
    - two
      - nested
    - three

    * star
    * list

    1. first
    2. second

    > quote
    >
    > - quoted item

    | a | b |
    |---|---|
    | 1 | 2 |
    | 3 | 4 |

    ```swift
    let x = 1
    ```

        indented code

    ---

    - [ ] task
    - [x] done

    Closing paragraph.
    """

    static let pastes = ["- pasted\n- items", "> quoted\n\npara", "| p | q |\n|---|---|\n| 1 | 2 |", "plain words", "```\nfenced\n```"]

    @Test(arguments: [1, 2, 3, 4])
    func randomEditsSpliceToTheFullOutput(seed: Int) {
        let harness = EditorHarness(markdown: Self.document)
        let controller = harness.controller
        controller.verifiesSerialization = true
        var generator = SeededGenerator(seed: UInt64(seed))
        var log: [String] = []
        for step in 0..<150 {
            let length = harness.storage.length
            let location = length == 0 ? 0 : Int.random(in: 0...length, using: &generator)
            let op = Int.random(in: 0..<11, using: &generator)
            switch op {
            case 0, 1:
                harness.select(location)
                harness.type(String("abc -*#>1.".randomElement(using: &generator)!))
            case 2:
                harness.select(location)
                harness.insertNewline()
            case 3:
                harness.select(location)
                harness.deleteBackward()
            case 4:
                let span = Int.random(in: 1...40, using: &generator)
                let start = max(0, min(location, length - 1))
                harness.select(NSRange(location: start, length: min(span, length - start)))
                harness.deleteBackward()
            case 5:
                let paragraphs = harness.storage.markdownParagraphRanges().filter { $0.length > 0 }
                if let paragraph = paragraphs.randomElement(using: &generator) {
                    harness.select(paragraph)
                    harness.deleteBackward()
                }
            case 6:
                harness.select(location)
                let markdown = Self.pastes.randomElement(using: &generator)!
                harness.step { _ = controller.paste(PastePayload(markdown: markdown), replacing: harness.selection) }
            case 7:
                if harness.undoManager.canUndo { harness.undo() }
            case 8:
                if harness.undoManager.canRedo { harness.redo() } else {
                    harness.select(location)
                    harness.insertTab()
                }
            case 9:
                harness.select(location)
                if Bool.random(using: &generator) { harness.insertTab() } else { harness.insertBacktab() }
            default:
                controller.writingToolsWillBegin()
                controller.writingToolsDidEnd()
            }
            controller.flushDocumentChanges()
            controller.drainDeferredEdits()
            log.append("\(step):\(op)@\(location)")
            let spliced = controller.serialize()
            let full = MarkdownWriter().markdown(from: harness.storage)
            #expect(spliced == full, "seed \(seed) after \(log.suffix(4))")
            if spliced != full { break }
        }
        #expect(controller.serializationDrifts.isEmpty, "\(controller.serializationDrifts.prefix(3))")
        #expect(controller.serializationStats.splices > 100)
        #expect(controller.serializationStats.fallbacks == 0)
        #expect(controller.harnessSerializationDrift() == nil)
    }
}
#endif
