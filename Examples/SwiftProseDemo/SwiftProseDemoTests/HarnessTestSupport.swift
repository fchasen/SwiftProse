import XCTest
import AppKit
import ObjectiveC
@testable import SwiftProseDemo
@_spi(Harness) import SwiftProse

/// Base class for the hosted suites. Everything runs in the app's own
/// process against the app's own window — no UI-automation permission
/// involved.
///
/// Synchronous `XCTestCase` methods on the main thread, deliberately: the
/// editor is driven through AppKit, and `settle()` is causally complete
/// (two main-queue fences plus an explicit drain), so there is nothing an
/// `async` test would buy beyond flakiness.
@MainActor
class HarnessTestCase: XCTestCase {

    private(set) var controller: EditorController!
    private(set) var textView: NSTextView!
    private(set) var driver: EditDriver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        let editor = try Self.waitForEditor()
        controller = editor.controller
        textView = editor.textView
        driver = EditDriver(controller: controller, textView: textView)
        driver.synthesizedKeyEventsWork = Self.keyEventCanary(driver: driver, textView: textView)
        try Self.hostClassCanary(textView: textView)
        reset(doc: "")
    }

    override func tearDown() {
        // Leave the editor as the next test expects to find it, and stop
        // the run's diagnostics from leaking into the next one.
        controller?.harnessAssertsOnDiagnostics = true
        controller?.historyConfig = .default
        controller?.useStructuredBulkInsert = true
        HarnessRegistry.shared.clearCollected()
        super.tearDown()
    }

    // MARK: - Editor rendezvous

    struct Editor {
        var controller: EditorController
        var textView: NSTextView
    }

    /// Polls the run loop for the three things that arrive on different
    /// render passes, in order: the controller (published from
    /// `onAppear`), the host text view (set in `makeNSView`, a pass
    /// later), and its window.
    static func waitForEditor(timeout: TimeInterval = 10) throws -> Editor {
        let deadline = Date().addingTimeInterval(timeout)
        var stage = "controller"
        while Date() < deadline {
            if let controller = HarnessRegistry.shared.controller {
                stage = "hostTextView"
                if let textView = controller.hostTextView as? NSTextView {
                    stage = "window"
                    if let window = textView.window {
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(textView)
                        return Editor(controller: controller, textView: textView)
                    }
                }
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        throw XCTSkip("the harness editor never reached \(stage) within \(Int(timeout))s")
    }

    // MARK: - Canaries

    /// A synthesized ArrowLeft must move the caret. If it doesn't, key
    /// events aren't reaching the view and every `keyDown`-routed op would
    /// silently do nothing — the driver downgrades arrows to
    /// `doCommand(by:)` rather than reporting green on no-ops.
    static func keyEventCanary(driver: EditDriver, textView: NSTextView) -> Bool {
        let saved = textView.string
        driver.controller.setMarkdown("canary", async: false)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let event = EditDriver.KeySpec(
            keyCode: 123, characters: "\u{F702}"
        ).makeEvent()
        textView.keyDown(with: event)
        driver.settle()
        let moved = textView.selectedRange().location == 2
        driver.controller.setMarkdown(saved, async: false)
        driver.controller.undoManager.removeAllActions()
        return moved
    }

    /// A build misconfiguration, not an environment the run can skip:
    /// fail loudly rather than reporting green on a harness that isn't
    /// driving the real editor.
    struct SetupFailure: Error, CustomStringConvertible {
        var description: String
    }

    /// The host text view has to be the package's own subclass. A second
    /// copy of SwiftProseView linked into the test bundle would produce a
    /// different class here and every `as?` cast across the boundary would
    /// fail in ways that look like logic bugs.
    ///
    /// `NSStringFromClass` returns the module-qualified name for a Swift
    /// class, so the check is on the suffix.
    static func hostClassCanary(textView: NSTextView) throws {
        let name = object_getClass(textView).map(NSStringFromClass) ?? "‹none›"
        guard name.hasSuffix("ProseNSTextView") else {
            throw SetupFailure(description:
                "host text view is \(name), not ProseNSTextView — the test bundle is "
                + "probably linking its own copy of SwiftProseView instead of resolving "
                + "through BUNDLE_LOADER")
        }
        guard textView.responds(to: NSSelectorFromString("undo:")) else {
            throw SetupFailure(description:
                "host text view does not respond to undo: — the menu undo route is missing")
        }
    }

    // MARK: - Per-test state

    /// Between scenarios. `replaceStorage` clears neither the undo stack
    /// nor the open typing burst; without `closeHistoryGroup` the next
    /// keystroke coalesces into a record that was just thrown away, and
    /// nothing new registers.
    func reset(doc: String) {
        Self.clearInputState(textView)
        controller.setMarkdown(doc, async: false)
        controller.undoManager.removeAllActions()
        controller.closeHistoryGroup()
        controller.historyConfig = HistoryConfig(newGroupDelay: 1e9)
        controller.harnessAssertsOnDiagnostics = true
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        HarnessRegistry.shared.clearCollected()
        driver.settle()
    }

    /// Leave the text view's input state as a fresh editor's.
    ///
    /// Marked text is the one that matters: a scenario that ends mid-IME
    /// leaves `hasMarkedText()` true, every later edit classifies as
    /// `.compositionInterim`, and the envelope closes with no
    /// normalization, no publish, no input rules and no undo entry — so
    /// unrelated scenarios quietly stop working. `unmarkText()` alone
    /// *accepts* the marked text; cancelling is an empty marked range first.
    static func clearInputState(_ textView: NSTextView) {
        guard textView.hasMarkedText() else { return }
        textView.setMarkedText(
            "",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: textView.markedRange()
        )
        textView.unmarkText()
    }

    // MARK: - Reporting

    func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Fails with the op log, the storage dump and a one-line repro, so a
    /// CI failure is debuggable without re-running anything.
    func report(_ message: String,
                ops: [EditOp],
                repro: String? = nil,
                file: StaticString = #filePath,
                line: UInt = #line) {
        attach(StorageDump.dump(controller.textStorage), name: "storage.txt")
        if let log = try? OpLog.encode(ops) { attach(log, name: "ops.jsonl") }
        attach(controller.markdown(), name: "after.md")
        var body = message
        if let repro { body += "\n\nrepro: \(repro)" }
        XCTFail(body, file: file, line: line)
    }
}
