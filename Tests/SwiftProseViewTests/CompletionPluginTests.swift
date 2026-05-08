import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct CompletionPluginTests {

    private func setup(_ markdown: String = "") throws -> (EditorController, CompletionPlugin) {
        let controller = try EditorController(initialMarkdown: markdown, theme: .default)
        let plugin = CompletionPlugin(triggers: [
            .init(id: "mention", prefix: "@"),
            .init(id: "tag", prefix: "#")
        ])
        controller.register(plugin: plugin)
        plugin.attach(to: controller)
        return (controller, plugin)
    }

    /// Simulate the host text view inserting `text` at the cursor and
    /// running the controller's transaction pipeline. The plugin's
    /// `handleTextInput` runs first; on return-false we apply the text.
    private func type(_ text: String, on controller: EditorController) {
        let cursor = controller.currentSelection.location
        let plugins = controller.plugins
        for plugin in plugins {
            if plugin.props.handleTextInput?(controller, NSRange(location: cursor, length: 0), text) == true {
                return
            }
        }
        // No plugin consumed — actually insert.
        let inserted = controller.insert(text: text)
        controller.testSelection = NSRange(location: inserted.location + inserted.length, length: 0)
    }

    @Test func atOpensSession() throws {
        let (controller, plugin) = try setup()
        type("@", on: controller)
        let session = try #require(plugin.session(controller: controller))
        #expect(session.context.triggerID == "mention")
        #expect(session.context.query == "")
    }

    @Test func typingExtendsTheQuery() throws {
        let (controller, plugin) = try setup()
        type("@", on: controller)
        type("f", on: controller)
        type("c", on: controller)
        let session = try #require(plugin.session(controller: controller))
        #expect(session.context.query == "fc")
    }

    @Test func spaceClosesSession() throws {
        let (controller, plugin) = try setup()
        type("@", on: controller)
        type("a", on: controller)
        type(" ", on: controller)
        #expect(plugin.session(controller: controller) == nil)
    }

    @Test func deletingPrefixCharacterClosesSession() throws {
        let (controller, plugin) = try setup()
        type("@", on: controller)
        type("a", on: controller)
        // Delete the trigger character via direct storage edit (mirrors
        // what backspace does at the host-view level — the plugin doesn't
        // see backspaces directly, only the resulting storage change).
        controller.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: 1),
            with: ""
        )
        controller.testSelection = NSRange(location: 0, length: 0)
        // Refresh fires from onDocumentChange in real usage; the test
        // calls it explicitly to avoid runloop timing dependence.
        plugin.refresh(controller: controller)
        #expect(plugin.session(controller: controller) == nil)
    }

    @Test func escapeCancelsSession() throws {
        let (controller, plugin) = try setup()
        type("@", on: controller)
        // Simulate ArrowDown / Escape via plugin.handleKey directly.
        for p in controller.plugins {
            _ = p.props.handleKeyDown?(controller, "Escape")
        }
        #expect(plugin.session(controller: controller) == nil)
    }

    @Test func arrowKeysMoveHighlight() throws {
        let (controller, plugin) = try setup()
        type("@", on: controller)
        plugin.updateItemCount(3, controller: controller)
        for p in controller.plugins {
            _ = p.props.handleKeyDown?(controller, "ArrowDown")
        }
        var session = try #require(plugin.session(controller: controller))
        #expect(session.highlightedIndex == 1)
        for p in controller.plugins {
            _ = p.props.handleKeyDown?(controller, "ArrowDown")
        }
        session = try #require(plugin.session(controller: controller))
        #expect(session.highlightedIndex == 2)
        // Clamp at the top.
        for p in controller.plugins {
            _ = p.props.handleKeyDown?(controller, "ArrowDown")
        }
        session = try #require(plugin.session(controller: controller))
        #expect(session.highlightedIndex == 2)
    }

    @Test func enterCommitsAndCallsOnCommit() throws {
        let (controller, plugin) = try setup()
        var committedQuery: String?
        plugin.onCommit = { _, session in
            committedQuery = session.context.query
        }
        type("@", on: controller)
        type("f", on: controller)
        type("c", on: controller)
        plugin.updateItemCount(2, controller: controller)
        for p in controller.plugins {
            _ = p.props.handleKeyDown?(controller, "Enter")
        }
        #expect(committedQuery == "fc")
        #expect(plugin.session(controller: controller) == nil)
    }

    @Test func multipleTriggersCoexist() throws {
        let (controller, plugin) = try setup()
        type("#", on: controller)
        let session = try #require(plugin.session(controller: controller))
        #expect(session.context.triggerID == "tag")
        // Cancel and switch.
        plugin.cancel(controller: controller)
        type(" ", on: controller)
        type("@", on: controller)
        let mention = try #require(plugin.session(controller: controller))
        #expect(mention.context.triggerID == "mention")
    }

    @Test func sessionContextRangeCoversPrefixAndQuery() throws {
        let (controller, plugin) = try setup()
        type("@", on: controller)
        type("f", on: controller)
        type("c", on: controller)
        let session = try #require(plugin.session(controller: controller))
        // Range starts at the prefix and length covers @fc → 3 chars.
        #expect(session.context.range.length == 3)
        let storage = controller.textStorage
        let captured = (storage.string as NSString).substring(with: session.context.range)
        #expect(captured == "@fc")
    }
}
