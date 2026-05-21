import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct AutoLinkURLTests {

    private func setup() throws -> (EditorController, AutoLinkPlugin) {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        let plugin = AutoLinkPlugin(rules: [.url])
        controller.register(plugin: plugin)
        return (controller, plugin)
    }

    @Test func pasteOfPlainURLBecomesLink() throws {
        let (controller, _) = try setup()
        controller.testSelection = NSRange(location: 0, length: 0)
        let event = PasteEvent(
            text: "https://example.com",
            selection: NSRange(location: 0, length: 0)
        )
        _ = controller.dispatchPaste(event)
        let link = try #require(controller.linkMark(at: 0))
        #expect(link.href == "https://example.com")
        // The whole URL is the link span.
        #expect(link.range.location == 0)
        #expect(link.range.length == 19)
    }

    @Test func pasteOfTextWithURLLinksOnlyTheURL() throws {
        let (controller, _) = try setup()
        controller.testSelection = NSRange(location: 0, length: 0)
        let event = PasteEvent(
            text: "see https://example.com for details",
            selection: NSRange(location: 0, length: 0)
        )
        _ = controller.dispatchPaste(event)
        // "see " is 4 chars; the URL starts at 4 and runs 19 chars.
        let link = try #require(controller.linkMark(at: 4))
        #expect(link.href == "https://example.com")
        #expect(link.range == NSRange(location: 4, length: 19))
        // "see " before and " for…" after carry no link.
        #expect(controller.linkMark(at: 0) == nil)
        let afterURL = link.range.location + link.range.length
        #expect(controller.linkMark(at: afterURL) == nil)
    }

    @Test func trailingPunctuationIsExcluded() throws {
        let (controller, _) = try setup()
        controller.testSelection = NSRange(location: 0, length: 0)
        let event = PasteEvent(
            text: "visit https://example.com.",
            selection: NSRange(location: 0, length: 0)
        )
        _ = controller.dispatchPaste(event)
        let link = try #require(controller.linkMark(at: 6))
        #expect(link.href == "https://example.com")
        // The terminating "." is not part of the link span.
        let ns = controller.textStorage.string as NSString
        let linkText = ns.substring(with: link.range)
        #expect(linkText == "https://example.com")
    }

    @Test func urlInCodeBlockIsLeftAlone() throws {
        let (controller, _) = try setup()
        // Build a code block with a URL inside.
        controller.setMarkdown("```\nhttps://example.com\n```", async: false)
        // Locate a position inside the URL.
        let storage = controller.textStorage
        var probe: Int?
        for i in 0..<storage.length {
            if storage.blockSpec(at: i)?.isCodeBlock == true,
               (storage.string as NSString).substring(with: NSRange(location: i, length: 1)) == "h" {
                probe = i
                break
            }
        }
        if let p = probe {
            #expect(controller.linkMark(at: p) == nil)
        }
    }

    @Test func alreadyLinkedTextIsntDoubleLinked() throws {
        // setMarkdown parses `[click](url)` into a link mark; the URL
        // rule's link-mark exclusion should leave that span alone instead
        // of re-running over the visible URL text.
        let (controller, _) = try setup()
        controller.setMarkdown("[https://example.com](https://other.example) trailing", async: false)
        // Verify there's a link mark over the visible URL text already.
        let link0 = try #require(controller.linkMark(at: 0))
        #expect(link0.href == "https://other.example")
        // Issuing a paste at the end shouldn't re-link the existing span.
        controller.testSelection = NSRange(location: controller.textStorage.length, length: 0)
        let event = PasteEvent(
            text: " visit https://added.example",
            selection: controller.testSelection!
        )
        _ = controller.dispatchPaste(event)
        // The pre-existing link's href is preserved.
        let stillExisting = try #require(controller.linkMark(at: 0))
        #expect(stillExisting.href == "https://other.example")
    }

    @Test func multipleURLsInOnePasteAllGetLinked() throws {
        let (controller, _) = try setup()
        controller.testSelection = NSRange(location: 0, length: 0)
        let event = PasteEvent(
            text: "https://a.com and https://b.com",
            selection: NSRange(location: 0, length: 0)
        )
        _ = controller.dispatchPaste(event)
        let first = try #require(controller.linkMark(at: 0))
        #expect(first.href == "https://a.com")
        let secondStart = (controller.textStorage.string as NSString).range(of: "https://b.com").location
        let second = try #require(controller.linkMark(at: secondStart))
        #expect(second.href == "https://b.com")
    }

    @Test func emailRuleProducesMailtoLink() throws {
        let controller = try EditorController(initialMarkdown: "", theme: .default)
        let plugin = AutoLinkPlugin(rules: [.email])
        controller.register(plugin: plugin)
        controller.testSelection = NSRange(location: 0, length: 0)
        let event = PasteEvent(
            text: "reach me at user@example.com please",
            selection: NSRange(location: 0, length: 0)
        )
        _ = controller.dispatchPaste(event)
        let ns = controller.textStorage.string as NSString
        let start = ns.range(of: "user@example.com").location
        let link = try #require(controller.linkMark(at: start))
        #expect(link.href == "mailto:user@example.com")
    }

    @Test func bulkInsertWithURLLinksIt() throws {
        // Mimics dictation / autocomplete: one large insert lands all at
        // once, the rule sees the URL with its right-boundary intact.
        let (controller, _) = try setup()
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.insert(text: "go to https://example.com now")
        let ns = controller.textStorage.string as NSString
        let start = ns.range(of: "https://example.com").location
        let link = try #require(controller.linkMark(at: start))
        #expect(link.href == "https://example.com")
        #expect(link.range.length == 19)
    }
}
