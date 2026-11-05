import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseView
import SwiftProse

@MainActor
@Suite struct PublicAPITests {

    @Test func embedderCanPromoteALineToAHeading() {
        let controller = EditorController(markdown: "draft text")
        controller.setSelection(NSRange(location: 0, length: 0))
        controller.perform(.heading(level: 2))
        #expect(controller.markdown() == "## draft text")
    }

    @Test func boldActionWrapsTheSelection() {
        let controller = EditorController(markdown: "hello world")
        controller.setSelection(NSRange(location: 0, length: 5))
        controller.perform(.bold)
        #expect(controller.markdown() == "**hello** world")
        #expect(controller.isActive(.bold))
        #expect(controller.activeActionIDs().contains(EditorAction.bold.stableID))
    }

    @Test func embedderCanInsertMarkdownAtTheCaret() {
        let controller = EditorController(markdown: "intro")
        controller.setSelection(NSRange(location: controller.textStorage.length, length: 0))
        #expect(controller.insertMarkdown(" **bold**"))
        #expect(controller.markdown() == "intro **bold**")

        let empty = EditorController()
        #expect(empty.insertMarkdown("- one\n- two"))
        #expect(empty.markdown() == "- one\n- two")
    }

    @Test func embedderObservesDocumentChanges() {
        let controller = EditorController(markdown: "hello")
        var changes: [DocumentChange] = []
        let token = controller.addOnDocumentChange { changes.append($0) }
        controller.setSelection(NSRange(location: 5, length: 0))
        controller.insertMarkdown(" world")
        #expect(!changes.isEmpty)
        #expect(changes.allSatisfy { $0.origin != .load })
        controller.removeObserver(token)
        let count = changes.count
        controller.insertMarkdown("!")
        #expect(changes.count == count)
    }

    @Test func loaderAndWriterRoundTripWithoutAController() {
        let markdown = "# Title\n\n- **one**\n- [link](https://example.com)\n\n> quoted"
        let storage = MarkdownLoader().load(markdown)
        #expect(storage.markdownBlock(at: 0)?.headingLevel == 1)
        #expect(MarkdownWriter().markdown(from: storage) == markdown)
    }

    @Test func defaultConfigurationExposesToolbarItems() {
        let cfg = SwiftProseEditor.Configuration()
        #expect(!cfg.toolbar.isEmpty)
        #expect(cfg.statusItems.isEmpty)
        #expect(cfg.minHeight > 0)
    }

    @Test func minimalConfigurationOmitsToolbar() {
        let cfg = SwiftProseEditor.Configuration(toolbar: [], statusItems: [.words, .characters, .cursor])
        #expect(cfg.toolbar.isEmpty)
        #expect(cfg.statusItems.count == 3)
    }

    @Test func editorViewComposesWithEachConfiguration() {
        let configs: [SwiftProseEditor.Configuration] = [
            SwiftProseEditor.Configuration(),
            SwiftProseEditor.Configuration(toolbar: []),
            SwiftProseEditor.Configuration(statusItems: [.words, .characters, .cursor]),
            SwiftProseEditor.Configuration(toolbar: [], statusItems: [.cursor], minHeight: 200)
        ]
        for cfg in configs {
            let view = SwiftProseEditor(text: .constant("hi")).configuration(cfg).editable(cfg.isEditable)
            #expect(String(describing: type(of: view)).contains("SwiftProseEditor"))
        }
    }
}
