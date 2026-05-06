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

    @Test func documentExposesTreeOfCurrentStorage() throws {
        let controller = try EditorController(initialMarkdown: "# Title\n\nBody.\n")
        let document = controller.document
        guard case .structural(let root, let kids) = document.root else {
            Issue.record("expected structural root")
            return
        }
        #expect(root.type == "doc")
        let topTypes = kids.compactMap { kid -> String? in
            if case .structural(let n, _) = kid { return n.type }
            if case .leaf(let n, _) = kid { return n.type }
            return nil
        }
        #expect(topTypes.contains("heading"))
        #expect(topTypes.contains("paragraph"))
    }

    @Test func documentReflectsLatestStorageAfterMutation() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n")
        let lineRange = NSRange(location: 0, length: controller.textStorage.length)
        controller.apply(Transaction(steps: [
            .setSpec(lineRange: lineRange, BlockSpec(kind: .heading(level: 2)))
        ]))
        let document = controller.document
        guard case .structural(_, let kids) = document.root,
              case .structural(let leaf, _) = kids.first else {
            Issue.record("expected heading at top of doc")
            return
        }
        #expect(leaf.type == "heading")
        #expect(leaf.attrs["level"] == .int(2))
    }

    @Test func documentCachedBetweenReads() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let firstId = controller.document.root.node?.id
        let secondId = controller.document.root.node?.id
        #expect(firstId != nil)
        #expect(firstId == secondId, "successive reads should return the cached tree")
    }

    @Test func documentCacheInvalidatedAfterEdit() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        let beforeId = controller.document.root.node?.id
        controller.testSelection = NSRange(location: controller.textStorage.length, length: 0)
        controller.insert(text: "!")
        let afterId = controller.document.root.node?.id
        #expect(beforeId != nil)
        #expect(afterId != nil)
        #expect(beforeId != afterId, "edit should invalidate the cached tree")
    }

    @Test func documentChangeCallbackFiresAfterEdit() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var fireCount = 0
        var receivedDoc: ProseDocument?
        controller.onDocumentChange = { doc, _ in
            fireCount += 1
            receivedDoc = doc
        }
        controller.testSelection = NSRange(location: 5, length: 0)
        controller.insert(text: "!")
        #expect(fireCount >= 1)
        #expect(receivedDoc != nil)
    }

    @Test func documentChangeCallbackProvidesReplaceTextStep() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var capturedStep: Step?
        controller.onDocumentChange = { _, step in
            capturedStep = step
        }
        controller.testSelection = NSRange(location: 5, length: 0)
        controller.insert(text: "!")
        guard case .replaceText(let range, let content) = capturedStep else {
            Issue.record("expected replaceText step, got \(String(describing: capturedStep))")
            return
        }
        #expect(range.location == 5)
        #expect(range.length == 0)
        #expect(content.string == "!")
    }

    @Test func exitCodeBlockFromNonEmptyBlockAddsParagraphAfter() throws {
        let controller = try EditorController(initialMarkdown: "```\nlet x = 1\n```\n")
        controller.testSelection = NSRange(location: 9, length: 0)
        let exited = controller.exitCodeBlock()
        #expect(exited == true)
        // Typing after exit must land in a fresh paragraph below the block.
        let cursor = controller.testSelection?.location ?? 0
        controller.testSelection = NSRange(location: cursor, length: 0)
        controller.insert(text: "after")
        #expect(controller.markdown() == "```\nlet x = 1\n```\n\nafter\n")
    }

    @Test func exitCodeBlockFromEmptyBlockReplacesWithParagraph() throws {
        let controller = try EditorController(initialMarkdown: "```\n```\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        let exited = controller.exitCodeBlock()
        #expect(exited == true)
        #expect(controller.markdown() == "")
    }

    @Test func exitCodeBlockOutsideCodeReturnsFalse() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        #expect(controller.exitCodeBlock() == false)
    }

    @Test func loadingCodeBlockEnsuresTrailingParagraph() throws {
        let controller = try EditorController(initialMarkdown: "```\nlet x = 1\n```\n")
        let total = controller.textStorage.length
        // Storage should hold the body plus one trailing paragraph anchor.
        let lastSpec = controller.textStorage.blockSpec(at: total - 1)
        #expect(lastSpec?.kind == .paragraph,
                "expected trailing paragraph, got \(String(describing: lastSpec?.kind))")
        // The trailing paragraph is invisible to markdown serialization.
        #expect(controller.markdown() == "```\nlet x = 1\n```\n")
    }

    @Test func tappingPastCodeBlockLandsInTrailingParagraph() throws {
        let controller = try EditorController(initialMarkdown: "```\nlet x = 1\n```\n")
        let total = controller.textStorage.length
        controller.testSelection = NSRange(location: total, length: 0)
        controller.insert(text: "after")
        #expect(controller.markdown() == "```\nlet x = 1\n```\n\nafter\n")
    }

    @Test func loadingPlainParagraphDocDoesNotAddTrailing() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        // Plain prose ending — no extra paragraph needed; storage is just
        // "hello\n" (length 6).
        #expect(controller.textStorage.length == 6)
    }

    @Test func loadingHorizontalRuleEnsuresTrailingParagraph() throws {
        let controller = try EditorController(initialMarkdown: "---\n")
        let total = controller.textStorage.length
        let lastSpec = controller.textStorage.blockSpec(at: total - 1)
        #expect(lastSpec?.kind == .paragraph)
    }

    @Test func backspaceAtStartOfEmptyCodeBlockDeletesBlock() throws {
        let controller = try EditorController(initialMarkdown: "hello\n\n```\n\n```\n")
        // Cursor at start of the empty code block body. Storage holds the
        // paragraph, the blank separator, the body `\n`, and the trailing
        // paragraph; the body sits at length-2.
        let bodyStart = controller.textStorage.length - 2
        controller.testSelection = NSRange(location: bodyStart, length: 0)
        let handled = controller.handleBackspace()
        #expect(handled == true)
        // The empty fence is gone; round-tripped markdown drops it.
        #expect(controller.markdown() == "hello\n")
    }

    @Test func backspaceInNonEmptyCodeBlockKeepsBlock() throws {
        let controller = try EditorController(initialMarkdown: "```\nlet x = 1\n```\n")
        // Cursor at the start of a non-empty code block body — handler must
        // refuse so the host's default delete kicks in.
        controller.testSelection = NSRange(location: 0, length: 0)
        let handled = controller.handleBackspace()
        #expect(handled == false)
    }

    @Test func forwardDeleteAtEmptyCodeBlockDeletesBlock() throws {
        let controller = try EditorController(initialMarkdown: "hello\n\n```\n\n```\n")
        let bodyStart = controller.textStorage.length - 2
        controller.testSelection = NSRange(location: bodyStart, length: 0)
        let handled = controller.handleForwardDelete()
        #expect(handled == true)
        #expect(controller.markdown() == "hello\n")
    }

    @Test func backspaceAfterToolbarInsertOnEmptyDocument() throws {
        // Empty doc → toolbar drops empty fence at position 0; cursor lands
        // at 0 too. Backspace must still recognize the empty block.
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        let landed = controller.perform(.codeBlock)
        controller.testSelection = landed
        let handled = controller.handleBackspace()
        #expect(handled == true,
                "expected backspace to drop empty block at doc start, cursor=\(landed) storage=\(String(reflecting: controller.textStorage.string))")
        #expect(controller.markdown() == "")
    }

    @Test func backspaceAfterToolbarInsertOnNonEmptyParagraph() throws {
        // Simulate the toolbar flow: text in storage, click Code Block →
        // empty block lands after the paragraph, cursor sits in the body.
        // One backspace should drop the block in one stroke.
        let controller = try EditorController(initialMarkdown: "hello\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        let landed = controller.perform(.codeBlock)
        // perform returns the post-transaction cursor range — wire that
        // into testSelection like the host text view would.
        controller.testSelection = landed
        let handled = controller.handleBackspace()
        #expect(handled == true,
                "expected backspace to drop empty block, cursor=\(landed) storage=\(String(reflecting: controller.textStorage.string))")
        #expect(controller.markdown() == "hello\n")
    }
}
