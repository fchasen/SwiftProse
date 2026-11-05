import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

extension CorpusSample: CustomTestStringConvertible {}
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

@Suite("Round-trip controller", .serialized)
@MainActor
struct RoundTripControllerTests {
    @Test(arguments: CorpusFixtures.canonical + CorpusFixtures.canonicalizing)
    func unchangedDocumentReturnsOriginalBytes(_ sample: CorpusSample) {
        let controller = EditorController(markdown: sample.source)
        #expect(controller.markdown() == sample.source)
    }

    @Test(arguments: CorpusFixtures.remarkupDrafts)
    func unchangedDraftWithLabelsReturnsOriginalBytes(_ sample: CorpusSample) {
        let controller = EditorController(
            markdown: sample.source,
            inlineContentRules: Corpus.labelRules,
            inlineContentProvider: Corpus.labelProvider
        )
        #expect(controller.markdown() == sample.source)
    }

    @Test func setMarkdownResetsTheOriginal() {
        let controller = EditorController(markdown: "* a")
        controller.setMarkdown("+ b\n+ c")
        #expect(controller.markdown() == "+ b\n+ c")
    }

    @Test(arguments: [
        ("- a\n-", NSRange(location: 2, length: 1), "- a"),
        ("a\n\n#\n\nb", NSRange(location: 2, length: 1), "a\n\nb")
    ])
    func deletingContentTheWriterDropsDoesNotRestoreIt(source: String, deletion: NSRange, expected: String) {
        let controller = EditorController(markdown: source)
        #expect(controller.markdown() == source)
        controller.textStorage.replaceCharacters(in: deletion, with: "")
        #expect(controller.markdown() == expected)
    }

    #if canImport(AppKit) && os(macOS)
    @Test func bindingPushesAfterDeletingAnEmptyTrailingItem() {
        let harness = EditorHarness(markdown: "- a\n-")
        harness.select(NSRange(location: 1, length: harness.storage.length - 1))
        harness.deleteBackward()
        #expect(harness.string == "a")
        #expect(harness.pushes.last == "- a")
        #expect(harness.controller.markdown() == "- a")
        harness.undo()
        #expect(harness.controller.markdown() == "- a\n-")
    }

    @Test(arguments: CorpusFixtures.canonicalizing)
    func undoingBackToTheLoadedStateReturnsOriginalBytes(_ sample: CorpusSample) throws {
        let harness = EditorHarness(markdown: sample.source)
        #expect(harness.controller.markdown() == sample.source)
        harness.select(harness.storage.length)
        harness.type("Z")
        let edited = harness.controller.markdown()
        #expect(edited != sample.source)
        #expect(edited.contains("Z"))
        harness.undo()
        #expect(harness.string == MarkdownLoader().load(sample.source).string)
        #expect(harness.controller.markdown() == sample.source)
        let lastPush = try #require(harness.pushes.last)
        #expect(lastPush == sample.source)
    }

    @Test func redoAfterUndoReturnsTheEditedSerialization() {
        let source = "* star\n* list"
        let harness = EditorHarness(markdown: source)
        harness.select(harness.storage.length)
        harness.type("!")
        let edited = harness.controller.markdown()
        harness.undo()
        #expect(harness.controller.markdown() == source)
        harness.redo()
        #expect(harness.controller.markdown() == edited)
    }
    #endif
}
