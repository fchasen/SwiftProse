import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct AppendTransactionTests {
    @Test func rawCharacterEditRunsAppendTransaction() throws {
        let controller = try EditorController(initialMarkdown: "")
        let plugin = AppendingPlugin { transactions, controller in
            guard transactions.contains(where: { $0.steps.containsReplaceText }) else { return nil }
            guard controller.textStorage.length > 0 else { return nil }
            return Transaction(steps: [
                .addMark(range: NSRange(location: 0, length: 1), mark: ProseMark(type: "strong"))
            ])
        }
        controller.register(plugin: plugin)

        type("x", in: controller)

        let marks = controller.textStorage.markSet(at: 0)
        #expect(marks?.contains(type: "strong") == true)
        #expect(plugin.calls == [1])
    }

    @Test func laterPluginsSeeEarlierAppendedTransactions() throws {
        let controller = try EditorController(initialMarkdown: "")
        let first = AppendingPlugin { transactions, controller in
            guard transactions.contains(where: { $0.steps.containsReplaceText }) else { return nil }
            guard controller.textStorage.length > 0 else { return nil }
            return Transaction(steps: [
                .addMark(range: NSRange(location: 0, length: 1), mark: ProseMark(type: "strong"))
            ])
        }
        let second = RecordingPlugin()
        controller.register(plugin: first)
        controller.register(plugin: second)

        type("x", in: controller)

        #expect(second.calls == [2])
    }

    @Test func autoLinkPluginLinksGenericPattern() throws {
        let controller = try EditorController(initialMarkdown: "")
        let plugin = AutoLinkPlugin(rules: [
            AutoLinkRule(
                id: "issue",
                pattern: "(?i)(?:^|\\s)(Issue\\s+(\\d+))(\\s)$",
                href: { match in
                    guard let id = match.capture(2) else { return nil }
                    return "https://issues.example/\(id)"
                }
            )
        ])
        controller.register(plugin: plugin)

        type("Issue 12434 ", in: controller)

        let linked = try #require(controller.linkMark(at: 0))
        #expect(linked.href == "https://issues.example/12434")
        #expect(linked.range == NSRange(location: 0, length: 11))
        #expect(controller.linkMark(at: 11) == nil)
    }

    @Test func autoLinkPluginRunsForMultiCharacterEdits() throws {
        let controller = try EditorController(initialMarkdown: "")
        let plugin = AutoLinkPlugin(rules: [
            AutoLinkRule(
                id: "ticket",
                pattern: "(?i)(?:^|\\s)(Ticket\\s+(\\d+))(\\s)$",
                href: { match in
                    guard let id = match.capture(2) else { return nil }
                    return "ticket://\(id)"
                }
            )
        ])
        controller.register(plugin: plugin)

        insert("Ticket 77 ", in: controller)

        let linked = try #require(controller.linkMark(at: 0))
        #expect(linked.href == "ticket://77")
        #expect(linked.range == NSRange(location: 0, length: 9))
    }

    private final class AppendingPlugin: EditorPlugin {
        let key = AnyPluginKey(name: "appending")
        var calls: [Int] = []
        let build: ([Transaction], EditorController) -> Transaction?

        init(build: @escaping ([Transaction], EditorController) -> Transaction?) {
            self.build = build
        }

        func appendTransaction(after transactions: [Transaction], controller: EditorController) -> Transaction? {
            calls.append(transactions.count)
            return build(transactions, controller)
        }
    }

    private final class RecordingPlugin: EditorPlugin {
        let key = AnyPluginKey(name: "recording")
        var calls: [Int] = []

        func appendTransaction(after transactions: [Transaction], controller: EditorController) -> Transaction? {
            calls.append(transactions.count)
            return nil
        }
    }

    private func type(_ chars: String, in controller: EditorController) {
        for char in chars {
            insert(String(char), in: controller)
        }
    }

    private func insert(_ text: String, in controller: EditorController) {
        let selection = controller.testSelection ?? NSRange(location: 0, length: 0)
        let storage = controller.textStorage
        let typedLength = (text as NSString).length
        storage.beginEditing()
        storage.replaceCharacters(in: selection, with: text)
        controller.testSelection = NSRange(
            location: selection.location + typedLength,
            length: 0
        )
        storage.endEditing()
    }
}

private extension Array where Element == Step {
    var containsReplaceText: Bool {
        contains {
            if case .replaceText = $0 { return true }
            return false
        }
    }
}
