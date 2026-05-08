import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct SetMarkAttrsStepTests {

    private func makeEnv() throws -> StepEnvironment {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        return StepEnvironment(compiler: compiler, serializer: serializer, theme: .default)
    }

    @Test func setMarkAttrsRewritesLinkHrefAndIsInverseRoundTrips() throws {
        let controller = try EditorController(initialMarkdown: "[docs](https://old.example.com)\n", theme: .default)
        let storage = controller.textStorage
        let env = controller.makeStepEnvironment()
        // Find the link span.
        let probe = (storage.string as NSString).range(of: "docs")
        try #require(probe.location != NSNotFound)
        let linkInfo = try #require(controller.linkMark(at: probe.location))
        #expect(linkInfo.href == "https://old.example.com")
        // Apply update.
        let step = Step.setMarkAttrs(
            range: linkInfo.range,
            markName: "link",
            attrs: ["href": .string("https://new.example.com")]
        )
        let applied = step.apply(to: storage, env: env)
        let updated = try #require(controller.linkMark(at: probe.location))
        #expect(updated.href == "https://new.example.com")
        // Inverse restores original href.
        _ = applied.inverse.apply(to: storage, env: env)
        let restored = try #require(controller.linkMark(at: probe.location))
        #expect(restored.href == "https://old.example.com")
    }

    @Test func updateLinkTransactionRoundTrips() throws {
        let controller = try EditorController(initialMarkdown: "[docs](https://old.example.com)\n", theme: .default)
        let storage = controller.textStorage
        let probe = (storage.string as NSString).range(of: "docs")
        let info = try #require(controller.linkMark(at: probe.location))
        let tx = controller.updateLink(in: info.range, href: "https://new.example.com", title: "Docs")
        controller.apply(tx)
        let updated = try #require(controller.linkMark(at: probe.location))
        #expect(updated.href == "https://new.example.com")
        #expect(updated.title == "Docs")
        #expect(controller.markdown().contains("https://new.example.com"))
    }

    @Test func linkMarkReturnsNilOnPlainText() throws {
        let controller = try EditorController(initialMarkdown: "plain text only\n", theme: .default)
        #expect(controller.linkMark(at: 3) == nil)
    }

    @Test func removeLinkStripsTheMarkButKeepsText() throws {
        let controller = try EditorController(initialMarkdown: "[docs](https://example.com)\n", theme: .default)
        let storage = controller.textStorage
        let probe = (storage.string as NSString).range(of: "docs")
        let info = try #require(controller.linkMark(at: probe.location))
        controller.apply(controller.removeLink(in: info.range))
        #expect(controller.linkMark(at: probe.location) == nil)
        #expect(storage.string.contains("docs"))
    }

    @Test func handleLongPressDispatchesToPlugins() throws {
        // Drive the plugin path the platform recognizers feed: registered
        // plugin's handleLongPress fires with (controller, charIndex).
        // The recognizer wiring itself is platform-specific and tested
        // manually in the demo app.
        final class CapturePlugin: EditorPlugin {
            let key = AnyPluginKey(name: "test.long-press")
            var captured: Int?
            var props: PluginProps {
                PluginProps(handleLongPress: { [weak self] _, idx in
                    self?.captured = idx
                    return true
                })
            }
        }
        let controller = try EditorController(initialMarkdown: "[docs](https://example.com)\n", theme: .default)
        let plugin = CapturePlugin()
        controller.register(plugin: plugin)
        let charIndex = 2
        // Walk plugins as the recognizer would.
        for p in controller.plugins {
            _ = p.props.handleLongPress?(controller, charIndex)
        }
        #expect(plugin.captured == charIndex)
    }
}
