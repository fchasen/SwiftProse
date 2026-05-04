import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct EditorControllerIntegrationTests {

    @Test func applyTransactionMutatesStorageAndUpdatesMarkdown() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let storage = controller.textStorage
        let lineRange = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let tx = Transaction(steps: [.setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 1)))])
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.apply(tx)
        #expect(controller.markdown().hasPrefix("# hello"))
    }

    @Test func performBoldThenUnboldRestoresMarkdown() throws {
        let controller = try EditorController(initialMarkdown: "alpha beta\n")
        controller.testSelection = NSRange(location: 0, length: 5)
        controller.perform(.bold)
        #expect(controller.markdown().contains("**alpha**"))
        controller.testSelection = NSRange(location: 0, length: 9)
        controller.perform(.bold)
        #expect(controller.markdown().contains("alpha"))
    }

    @Test func performBoldOnSelectionPreservesSelection() throws {
        let controller = try EditorController(initialMarkdown: "alpha beta\n")
        let selection = NSRange(location: 0, length: 5)
        controller.testSelection = selection
        let result = controller.perform(.bold)
        // The toggled range should stay selected so the user can chain
        // formatting (bold + italic, etc.) without re-selecting.
        #expect(result == selection)
    }

    @Test func performHeadingPreservesInlineMarks() throws {
        let controller = try EditorController(initialMarkdown: "**title** here\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.heading(level: 2))
        let md = controller.markdown()
        #expect(md.hasPrefix("## "))
        #expect(md.contains("**title**") || md.contains("title"))
    }

    @Test func loadProseMirrorJSONReplacesContent() throws {
        let controller = try EditorController(initialMarkdown: "old\n")
        let json = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"new"}]}
        ]}
        """
        try controller.loadProseMirrorJSON(json)
        #expect(controller.markdown().contains("new"))
        #expect(!controller.markdown().contains("old"))
    }

    @Test func exportProseMirrorJSONProducesParseableData() throws {
        let controller = try EditorController(initialMarkdown: "# Title\n\nBody.\n")
        let data = try controller.exportProseMirrorJSON()
        let decoded = try JSONDecoder().decode(PMNode.self, from: data)
        #expect(decoded.type == "doc")
        #expect(decoded.content?.first?.type == "heading")
    }
}
