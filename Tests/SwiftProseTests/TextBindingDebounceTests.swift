#if canImport(AppKit) && os(macOS)
import Testing
import Foundation
import SwiftUI
import SwiftProseSyntax
@testable import SwiftProseView
import SwiftProse
import AppKit

/// Boxed observer so the test's `Binding` set closure can record writes
/// without dancing around closure-capture rules.
private final class BindingObserver {
    var current: String = ""
    var pushCount: Int = 0
}

@MainActor
@Suite(.serialized) struct TextBindingDebounceTests {

    @Test func multipleTextDidChangeCallsCoalesceIntoOnePush() async throws {
        let saved = ProseTextViewMac.Coordinator.debounceInterval
        ProseTextViewMac.Coordinator.debounceInterval = .milliseconds(5)
        defer { ProseTextViewMac.Coordinator.debounceInterval = saved }

        let observer = BindingObserver()
        let controller = try EditorController(initialMarkdown: "")
        let binding = Binding<String>(
            get: { observer.current },
            set: { observer.current = $0; observer.pushCount += 1 }
        )
        let view = ProseTextViewMac(controller: controller, text: binding)
        let coordinator = view.makeCoordinator()

        // Mutate storage twice and fire textDidChange after each mutation.
        // Each call should cancel the previously-scheduled work item.
        controller.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "h")
        )
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        controller.textStorage.replaceCharacters(
            in: NSRange(location: 1, length: 0),
            with: NSAttributedString(string: "i")
        )
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))

        // Nothing should have been pushed synchronously.
        #expect(observer.pushCount == 0)

        // Yield long enough for the 5 ms debounce to elapse and the main
        // queue to drain.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(observer.pushCount == 1, "expected one push, got \(observer.pushCount)")
        // Storage was mutated to "hi" (with whatever block-spec scaffolding
        // the controller adds); the push should reflect controller.markdown().
        #expect(observer.current == controller.markdown())
    }

    @Test func iOSStyleNewlineHandlerFlushesImmediately() async throws {
        // Mac path doesn't have a synchronous newline handler in
        // shouldChangeTextIn, but the public `pushTextNow()` exists on the
        // iOS coordinator. Verify the Mac equivalent (cancel + push on
        // applyExternalText override) by simulating an external set
        // mid-debounce.
        let saved = ProseTextViewMac.Coordinator.debounceInterval
        ProseTextViewMac.Coordinator.debounceInterval = .milliseconds(50)
        defer { ProseTextViewMac.Coordinator.debounceInterval = saved }

        let observer = BindingObserver()
        observer.current = "" // initial binding value
        let controller = try EditorController(initialMarkdown: "")
        let binding = Binding<String>(
            get: { observer.current },
            set: { observer.current = $0; observer.pushCount += 1 }
        )
        let view = ProseTextViewMac(controller: controller, text: binding)
        let coordinator = view.makeCoordinator()

        // User types into the controller — schedules a push.
        controller.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "user text")
        )
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(observer.pushCount == 0)

        // External set arrives before the debounce fires. The pending push
        // should be cancelled (external set wins) and storage should
        // reflect the external value.
        if let textView = NSTextView() as NSTextView? {
            coordinator.applyExternalText("external\n", to: textView)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        // No debounced push for "user text" should have leaked through —
        // the coordinator cancelled it when applyExternalText took the
        // external path.
        #expect(controller.markdown() == "external\n")
        #expect(observer.pushCount == 0,
                "external set must not be overwritten by a debounced user-typing push; got \(observer.pushCount) pushes")
    }
}
#endif
