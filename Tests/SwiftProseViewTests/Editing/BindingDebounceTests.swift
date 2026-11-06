#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@_spi(Harness) @testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Binding debounce (macOS, .serialized)", .serialized)
@MainActor
struct BindingDebounceTests {
    @Test func burstOfKeystrokesPushesOnceOnFlush() {
        let harness = EditorHarness(markdown: "")
        for character in "hello" {
            harness.type(String(character))
            #expect(harness.unflushedPushes.isEmpty)
            #expect(harness.controller.lastPushed == "")
            #expect(harness.controller.hasPendingBindingPush)
        }
        harness.controller.flushPendingBinding()
        #expect(harness.unflushedPushes == ["hello"])
        #expect(!harness.controller.hasPendingBindingPush)
        harness.controller.flushPendingBinding()
        #expect(harness.unflushedPushes == ["hello"])
    }

    @Test func timerPushesOnceAfterTheBurst() async throws {
        let harness = EditorHarness(markdown: "")
        for character in "abc" { harness.type(String(character)) }
        #expect(harness.unflushedPushes.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.unflushedPushes == ["abc"])
        #expect(!harness.controller.hasPendingBindingPush)
    }

    @Test func noSinkSkipsThePushUntilOneIsAttached() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let controller = EditorController(markdown: "x", undoManager: manager)
        controller.setSelection(NSRange(location: 1, length: 0))
        controller.insertMarkdown("y")
        #expect(!controller.hasPendingBindingPush)
        controller.flushPendingBinding()
        #expect(controller.bindingDirty)
        #expect(controller.lastPushed == "x")
        #expect(controller.markdown() == "xy")
        var pushes: [String] = []
        controller.textSink = { pushes.append($0) }
        #expect(controller.hasPendingBindingPush)
        controller.flushPendingBinding()
        #expect(pushes == ["xy"])
    }

    @Test func externalTextWithoutASinkComparesAgainstTheDocument() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let controller = EditorController(markdown: "x", undoManager: manager)
        controller.setSelection(NSRange(location: 1, length: 0))
        controller.insertMarkdown("y")
        controller.applyExternalText("x")
        #expect(controller.markdown() == "x")
    }

    @Test func externalTextCancelsThePendingPush() async throws {
        let harness = EditorHarness(markdown: "")
        harness.type("user text")
        #expect(harness.controller.hasPendingBindingPush)
        harness.controller.applyExternalText("external")
        #expect(!harness.controller.hasPendingBindingPush)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.unflushedPushes.isEmpty)
        #expect(harness.controller.markdown() == "external")
        #expect(harness.pushes.isEmpty)
    }

    @Test func markedTextHoldsThePushThroughAFlush() {
        let harness = EditorHarness(markdown: "a")
        harness.select(1)
        harness.setMarkedText("か")
        harness.controller.flushPendingBinding()
        #expect(harness.unflushedPushes.isEmpty)
        harness.unmarkText()
        #expect(harness.unflushedPushes.isEmpty)
        harness.controller.flushPendingBinding()
        #expect(harness.unflushedPushes == ["aか"])
    }

    @Test func switchingToSourceFlushesTheRichBinding() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let rich = EditorController(markdown: "one", undoManager: manager)
        var pushes: [String] = []
        rich.textSink = { pushes.append($0) }
        rich.setSelection(NSRange(location: 3, length: 0))
        rich.insertMarkdown(" two")
        #expect(pushes.isEmpty)
        let handle = EditorHandle(richController: rich, sourceController: SourceEditorController(text: ""))
        handle.synchronize(for: .source)
        #expect(pushes == ["one two"])
        #expect(!rich.hasPendingBindingPush)
    }

    @Test func settlingForTheHarnessFlushesTheBinding() {
        let harness = EditorHarness(markdown: "")
        harness.type("z")
        #expect(harness.controller.hasPendingWorkForHarness)
        harness.controller.settleForHarness()
        #expect(harness.unflushedPushes == ["z"])
        #expect(!harness.controller.hasPendingWorkForHarness)
    }

    @Test func applicationTerminationFlushesTheBinding() {
        let harness = EditorHarness(markdown: "")
        harness.type("q")
        #expect(harness.unflushedPushes.isEmpty)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(harness.unflushedPushes == ["q"])
        #expect(!harness.controller.hasPendingBindingPush)
    }
}
#endif
